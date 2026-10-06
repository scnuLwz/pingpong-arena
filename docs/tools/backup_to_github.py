#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把本地 git 索引里的文件推到 GitHub。

为什么不能 `git push`：这台机器的沙箱代理做 TLS 拦截，会打断 git 的
smart-HTTP 传输（表现为 "expected flush after ref listing" 或直接挂起）。
**这不代表远端坏了**，只代表要绕开 git 协议。走 REST Git Data API。

两种起点（脚本自动判断，不用人管）：
  · 分支不存在（空仓库）：Git Data API 对空仓库一律 409
    "Git Repository is empty"，所以先用 Contents API PUT 一个文件把分支建出来。
  · 分支已存在：直接 Git Data API。★ 这时**不能**再用 Contents API PUT
    同一个路径 —— 覆盖已有文件必须带 `sha`，不带就 422
    "\\"sha\\" wasn't supplied"（2026-10-06 踩到）。

推送方式：一次构造**整棵树**（不是增量 diff）。GitHub 的 tree 是整体替换语义，
所以本地删掉的文件自然也会从远端消失 —— 这正是「同步」该有的行为。
★ 代价：每个文件都要重新 POST blob（208 个文件约 30 s），但换来实现简单、
  绝不出现「本地删了远端还在」。

环境变量：GH_TOKEN（fine-grained PAT 或 classic PAT，需 repo 写权限）。
★ 不要把 token 写进任何文件。
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

OWNER = "scnuLwz"
REPO = "pingpong-arena"
BRANCH = "main"
API = f"https://api.github.com/repos/{OWNER}/{REPO}"
TOKEN = os.environ["GH_TOKEN"]
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# 单个 blob 的请求体上限约 100MB，base64 膨胀 33% → 原始文件留到 70MB
MAX_RAW = 70 * 1024 * 1024


def call(method, url, payload=None, raw=False, allow=(200, 201)):
    """调 GitHub API。返回解析后的 JSON；raw=True 时返回原始 bytes。

    非 allow 里的状态码抛 GitHubError（带上错误体，方便定位）。
    """
    data = None
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "cs1-backup",
    }
    if payload is not None:
        if raw:
            data = payload
            headers["Content-Type"] = "application/octet-stream"
        else:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            body = r.read()
            code = r.status
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise GitHubError(e.code, f"[{method} {url}] HTTP {e.code}\n{detail}")
    if code not in allow:
        raise GitHubError(code, f"[{method} {url}] HTTP {code}")
    return body if raw else json.loads(body.decode("utf-8"))


class GitHubError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


def local_files():
    """按 git 索引取文件清单 —— 天然遵守 .gitignore，比手写 glob 靠谱。"""
    out = subprocess.run(
        ["git", "ls-files", "-z", "--cached"],
        cwd=REPO_ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8")
    return [p for p in out.split("\0") if p]


def read_blob(rel):
    with open(os.path.join(REPO_ROOT, rel), "rb") as f:
        return f.read()


def head_sha():
    """分支当前的 commit sha；分支不存在（空仓库）返回 None。"""
    try:
        return call("GET", f"{API}/git/ref/heads/{BRANCH}")["object"]["sha"]
    except GitHubError as e:
        if e.code == 404 or e.code == 409:
            return None
        raise


def main():
    files = local_files()
    total = sum(os.path.getsize(os.path.join(REPO_ROOT, p)) for p in files)
    msg = subprocess.run(
        ["git", "log", "-1", "--pretty=%B"],
        cwd=REPO_ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8").strip()
    print(f"待推送 {len(files)} 个文件 / {total/1048576:.1f} MB")
    print(f"提交信息首行：{msg.splitlines()[0] if msg else '(空)'}\n")

    entries = []

    # ── 只在空仓库才需要：Contents API 建分支 ──
    if head_sha() is None:
        first = files[0]
        print(f"[1/3] 空仓库 → Contents API 建分支（首个文件 {first}）")
        r1 = call("PUT", f"{API}/contents/{urllib.parse.quote(first)}", {
            "message": msg,
            "content": base64.b64encode(read_blob(first)).decode(),
            "branch": BRANCH,
        })
        # ★ 必须留住首个文件的 blob sha：下面的 tree 是**整体替换**分支现有的树，
        #   漏掉它 = 刚 PUT 上去的文件凭空消失（远端看起来一切正常，只是少一个文件）。
        entries.append({"path": first, "mode": "100644",
                        "type": "blob", "sha": r1["content"]["sha"]})
        rest = files[1:]
    else:
        print("[1/3] 分支已存在 → 跳过 Contents API")
        rest = files

    # ── 上传 blob ──
    print(f"[2/3] 上传 {len(rest)} 个 blob")
    for i, rel in enumerate(rest, len(entries) + 1):
        raw = read_blob(rel)
        if len(raw) > MAX_RAW:
            raise SystemExit(f"{rel} 超过 {MAX_RAW} 字节，走 Release 附件"
                             f"（scripts/upload_release_asset.py）")
        blob = call("POST", f"{API}/git/blobs", {
            "content": base64.b64encode(raw).decode(),
            "encoding": "base64",
        })
        entries.append({"path": rel, "mode": "100644",
                        "type": "blob", "sha": blob["sha"]})
        if i % 20 == 0 or i == len(files):
            print(f"      {i}/{len(files)}")
        time.sleep(0.05)   # 次级速率限制

    print("      构造整棵树")
    tree = call("POST", f"{API}/git/trees", {"tree": entries})
    print(f"      tree={tree['sha'][:8]}")

    parent = head_sha()
    print(f"[3/3] 建提交（parent={parent[:8] if parent else '(无)'}）")
    payload = {"message": msg, "tree": tree["sha"], "parents": [parent] if parent else []}
    commit = call("POST", f"{API}/git/commits", payload)
    print(f"      commit={commit['sha'][:8]}")

    if parent is None:
        call("POST", f"{API}/git/refs",
             {"ref": f"refs/heads/{BRANCH}", "sha": commit["sha"]})
    else:
        call("PATCH", f"{API}/git/refs/heads/{BRANCH}",
             {"sha": commit["sha"], "force": False})

    print(f"\n完成 → https://github.com/{OWNER}/{REPO}")
    print(f"远端提交 {commit['sha']}")
    local_head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, capture_output=True,
    ).stdout.decode().strip()
    print(f"本地 HEAD {local_head}")
    print("\n★ 提醒：用完请去 GitHub 撤销这个 token。")


if __name__ == "__main__":
    main()
