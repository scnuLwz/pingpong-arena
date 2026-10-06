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

★ 文件内容从 **git 索引**（`git cat-file --batch`）读，**不是从磁盘读**
  （2026-10-06 踩到）：磁盘上可能留着 CRLF，而索引里是 `git add` 时归一化过的
  LF。照磁盘字节上传会让远端 blob 与本地 tree 对不上 —— 症状很隐蔽：
  「推送成功、文件一个不少、GitHub 页面看着也对」，只有拿 tree sha / blob sha
  比对才暴露。改成按索引读之后，远端的整棵 tree sha 应当与本地
  `git rev-parse HEAD^{tree}` **完全相同**，那才算真的同步。

推送方式：一次构造**整棵树**（不是增量 diff）。GitHub 的 tree 是整体替换语义，
所以本地删掉的文件自然也会从远端消失 —— 这正是「同步」该有的行为。
★ 代价：每个文件都要重新 POST blob（224 个文件约 30 s），但换来实现简单、
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


def local_entries():
    """按 git 索引取 (路径, 权限位, blob sha)。

    -z 关掉路径转义（中文路径默认会被 core.quotepath 变成 \\345\\214\\226…
    形式，拿去当 API 路径就 404 了）。
    ★ 权限位照抄索引，别硬写 100644 —— 那会把可执行位丢掉。
    """
    out = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "-s"],
        cwd=REPO_ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8")
    entries = []
    for rec in out.split("\0"):
        if not rec:
            continue
        meta, path = rec.split("\t", 1)
        mode, sha, _stage = meta.split()
        entries.append((path, mode, sha))
    return entries


def read_index_blobs(shas):
    """按 blob sha 从 git 对象库批量取内容（二进制安全）。

    这是「内容 = 索引内容」的保证点：磁盘上的 CRLF 完全不参与。
    一次 --batch 喂完所有 sha，省掉 200 多次进程启动。
    """
    proc = subprocess.run(
        ["git", "cat-file", "--batch"], cwd=REPO_ROOT,
        input=("\n".join(shas) + "\n").encode("ascii"),
        capture_output=True, check=True,
    )
    out = proc.stdout
    blobs = {}
    pos = 0
    for want in shas:
        nl = out.index(b"\n", pos)
        header = out[pos:nl].decode("utf-8", "replace")
        parts = header.split()
        if len(parts) != 3 or parts[1] != "blob":
            raise SystemExit(f'cat-file 读不到 blob：{want} → "{header}"')
        size = int(parts[2])
        start = nl + 1
        blobs[want] = out[start:start + size]
        pos = start + size + 1        # blob 内容后面固定跟一个 \n
    return blobs


def head_sha():
    """分支当前的 commit sha；分支不存在（空仓库）返回 None。"""
    try:
        return call("GET", f"{API}/git/ref/heads/{BRANCH}")["object"]["sha"]
    except GitHubError as e:
        if e.code == 404 or e.code == 409:
            return None
        raise


def main():
    items = local_entries()
    blobs = read_index_blobs([sha for _, _, sha in items])
    total = sum(len(blobs[sha]) for _, _, sha in items)
    msg = subprocess.run(
        ["git", "log", "-1", "--pretty=%B"],
        cwd=REPO_ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8").strip()
    print(f"待推送 {len(items)} 个文件 / {total/1048576:.1f} MB（内容读自 git 索引）")
    print(f"提交信息首行：{msg.splitlines()[0] if msg else '(空)'}\n")

    entries = []

    # ── 只在空仓库才需要：Contents API 建分支 ──
    if head_sha() is None:
        first, first_mode, first_sha = items[0]
        print(f"[1/3] 空仓库 → Contents API 建分支（首个文件 {first}）")
        r1 = call("PUT", f"{API}/contents/{urllib.parse.quote(first)}", {
            "message": msg,
            "content": base64.b64encode(blobs[first_sha]).decode(),
            "branch": BRANCH,
        })
        # ★ 必须留住首个文件的 blob sha：下面的 tree 是**整体替换**分支现有的树，
        #   漏掉它 = 刚 PUT 上去的文件凭空消失（远端看起来一切正常，只是少一个文件）。
        entries.append({"path": first, "mode": first_mode,
                        "type": "blob", "sha": r1["content"]["sha"]})
        rest = items[1:]
    else:
        print("[1/3] 分支已存在 → 跳过 Contents API")
        rest = items

    # ── 上传 blob ──
    print(f"[2/3] 上传 {len(rest)} 个 blob")
    for i, (rel, mode, sha) in enumerate(rest, len(entries) + 1):
        raw = blobs[sha]
        if len(raw) > MAX_RAW:
            raise SystemExit(f"{rel} 超过 {MAX_RAW} 字节，走 Release 附件"
                             f"（scripts/upload_release_asset.py）")
        blob = call("POST", f"{API}/git/blobs", {
            "content": base64.b64encode(raw).decode(),
            "encoding": "base64",
        })
        entries.append({"path": rel, "mode": mode,
                        "type": "blob", "sha": blob["sha"]})
        if i % 20 == 0 or i == len(items):
            print(f"      {i}/{len(items)}")
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

    # ★ 自校验：远端 tree 必须与本地 HEAD 的 tree **完全相同**。
    #   git 是 content-addressed 的，tree sha 相同 ⇒ 每个 blob 都相同。
    #   这是唯一能发现「CRLF 推歪 / 路径转义 / 权限位丢失」的检查。
    local_tree = subprocess.run(
        ["git", "rev-parse", "HEAD^{tree}"], cwd=REPO_ROOT,
        capture_output=True, check=True,
    ).stdout.decode().strip()
    local_head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
        capture_output=True, check=True,
    ).stdout.decode().strip()
    print(f"\n完成 → https://github.com/{OWNER}/{REPO}")
    print(f"远端提交 {commit['sha']}")
    print(f"本地 HEAD {local_head}")
    if commit["tree"]["sha"] == local_tree:
        print("✓ 远端 tree 与本地 HEAD tree 一致（逐字节同步）")
    else:
        print(f"✗ tree 不一致！远端 {commit['tree']['sha'][:8]} "
              f"vs 本地 {local_tree[:8]} —— 用 verify_remote.py 逐文件定位")
    print("\n★ 提醒：用完请去 GitHub 撤销这个 token。")


if __name__ == "__main__":
    main()
