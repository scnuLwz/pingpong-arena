#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把本地 git 索引里的文件推到 GitHub。

分两步（这是 GitHub 对空仓库的硬限制，不是绕路）：
  1. Contents API PUT 第一个文件 —— 空仓库必须用它建出分支，
     Git Data API 对空仓库一律 409 "Git Repository is empty"。
  2. 分支存在后，剩下的文件走 Git Data API（blobs → trees → commits → refs），
     压成**一个** commit，而不是 207 个。
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

# Contents API 单文件上限按 base64 后的请求体算，这里留足余量
MAX_RAW = 70 * 1024 * 1024


def call(method, url, payload=None, raw=False):
    """调GitHub API。返回解析后的 JSON；raw=True 时返回原始 bytes。"""
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
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise SystemExit(f"[{method} {url.rsplit('/', 1)[-1]}] HTTP {e.code}\n{detail}")
    return body if raw else json.loads(body.decode("utf-8"))


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


def main():
    files = local_files()
    total = sum(os.path.getsize(os.path.join(REPO_ROOT, p)) for p in files)
    print(f"待推送 {len(files)} 个文件 / {total/1048576:.1f} MB\n")

    # ── 步骤 1：Contents API 建分支 ──
    first = files[0]
    msg = subprocess.run(
        ["git", "log", "-1", "--pretty=%B"],
        cwd=REPO_ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8").strip()
    print(f"[1/3] 用 Contents API 建分支（首个文件 {first}）")
    r1 = call("PUT", f"{API}/contents/{urllib.parse.quote(first)}", {
        "message": msg,
        "content": base64.b64encode(read_blob(first)).decode(),
        "branch": BRANCH,
    })
    # ★ 必须留住首个文件的 sha：下面构造的 tree 会**整体替换**分支上现有的树，
    #   漏掉它 = 第一次 PUT 传的文件会凭空消失（而且远端看起来一切正常，
    #   只是少了一个文件）。Contents API 的响应里就有 content.sha。
    first_sha = r1["content"]["sha"]
    print(f"      分支已建出，首个 blob={first_sha[:8]}")

    # ── 步骤 2：blobs → trees → commit ──
    print(f"[2/3] 上传 {len(files)-1} 个 blob")
    entries = [{"path": first, "mode": "100644",
                "type": "blob", "sha": first_sha}]
    for i, rel in enumerate(files[1:], 2):
        raw = read_blob(rel)
        if len(raw) > MAX_RAW:
            raise SystemExit(f"{rel} 超过 {MAX_RAW} 字节，走 Release 附件")
        blob = call("POST", f"{API}/git/blobs", {
            "content": base64.b64encode(raw).decode(),
            "encoding": "base64",
        })
        entries.append({"path": rel, "mode": "100644",
                        "type": "blob", "sha": blob["sha"]})
        if i % 20 == 0 or i == len(files):
            print(f"      {i}/{len(files)}")
        # 次级速率限制：Contents/Git Data API 都限，歇一下
        time.sleep(0.05)

    # 首个文件的 sha 已经在树里了，重新取一次保证路径完整
    print("      构造整棵树")
    tree = call("POST", f"{API}/git/trees", {"tree": entries})
    print(f"      tree={tree['sha'][:8]}")

    head = call("GET", f"{API}/git/ref/heads/{BRANCH}")
    parent = head["object"]["sha"]
    print(f"[3/3] 建提交（parent={parent[:8]}）")
    commit = call("POST", f"{API}/git/commits", {
        "message": msg,
        "tree": tree["sha"],
        "parents": [parent],
    })
    print(f"      commit={commit['sha'][:8]}")

    call("PATCH", f"{API}/git/refs/heads/{BRANCH}", {
        "sha": commit["sha"], "force": False,
    })
    print(f"\n完成 → https://github.com/{OWNER}/{REPO}")
    print(f"远端提交 {commit['sha']}")


if __name__ == "__main__":
    main()
