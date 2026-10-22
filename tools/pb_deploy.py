"""云桥备份 P3 部署脚本（改编自 dsh4/tools/xcc_deploy.py）。

用法：
  python tools/pb_deploy.py create     # 创建 GitHub 私有仓库
  python tools/pb_deploy.py bootstrap  # 空仓库引导：Contents API 建首个提交 + 创建 main 分支
  python tools/pb_deploy.py sync       # 用 GitHub Trees API 同步本地 git HEAD 到 main（非 push）
  python tools/pb_deploy.py finish   # 同步兜底（重试 commit/branch 更新）
  python tools/pb_deploy.py batch    # 逐文件 Contents API 兜底同步
  python tools/pb_deploy.py          # (poll) 轮询 CI 并下载 APK 到 OUT
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
import zipfile
import io
from urllib.parse import quote

PROJECT = r"g:\dsh\dsh6\phone-bridge-p3"
TOKEN = "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"
API = "https://api.github.com"
REPO = "pang724/cloudbridge-phone"
ARTIFACT = "cloudbridge-phone-release-apks"
OUT = r"g:\dsh\dsh6\phone-bridge-p3\apk"
SYNC_MSG = "sync: 同步本地完整状态（release签名+key.properties+CI workflow+云桥备份手机端）"


def _headers(method):
    h = {
        "Authorization": f"Bearer {TOKEN}",
        "User-Agent": "pb-deploy",
    }
    if method in ("POST", "PATCH", "PUT"):
        h["Content-Type"] = "application/json"
    if method == "GET":
        h["Accept"] = "application/vnd.github+json"
    return h


def _request(url, method, body=None, timeout=60, retry=True):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    last = None
    attempts = 6 if retry else 1
    for attempt in range(attempts):
        if method in ("POST", "PATCH"):
            time.sleep(0.8 if attempt == 0 else 3)
        req = urllib.request.Request(url, data=data, headers=_headers(method), method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            if e.code in (404, 408, 429, 500, 502, 503, 504) and attempt < attempts - 1:
                last = f"{e.code}: {detail}"
                continue
            print(f"{method} {url} -> {e.code}: {detail}", flush=True)
            raise
    print(f"{method} {url} -> retries exhausted: {last}", flush=True)
    raise SystemExit(1)


def get_exists(url):
    try:
        _request(url, "GET", timeout=30, retry=False)
        return True
    except urllib.error.HTTPError as e:
        # 404=不存在；409=空仓库（"Git Repository is empty"），同样视为不存在
        if e.code in (404, 409):
            return False
        raise


def compute_tree_sha(items):
    def sort_key(e):
        name = e["path"].encode("utf-8")
        return name + b"/" if e["type"] == "tree" else name
    buf = b""
    for e in sorted(items, key=sort_key):
        buf += e["mode"].encode("ascii") + b" " + e["path"].encode("utf-8") + b"\0" + bytes.fromhex(e["sha"])
    return hashlib.sha1(f"tree {len(buf)}\0".encode("ascii") + buf).hexdigest()


def api_get(url):
    return _request(url, "GET", timeout=30)


def api_post(url, body):
    return _request(url, "POST", body)


def api_patch(url, body):
    return _request(url, "PATCH", body)


def create_repo():
    try:
        d = api_post(f"{API}/user/repos", {
            "name": "cloudbridge-phone", "private": True,
            "description": "云桥备份 PhoneBridge 手机端 Flutter 应用（Android APK，与 PC 端 P2 服务配对）",
        })
        print("created:", d["full_name"], "private=", d["private"], flush=True)
    except urllib.error.HTTPError as e:
        if e.code in (422, 409):
            d = api_get(f"{API}/repos/{REPO}")
            print("already exists:", d["full_name"], "private=", d["private"], flush=True)
        else:
            print("create failed:", e.code, e.read().decode("utf-8", "replace"), flush=True)
            sys.exit(1)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_302(self, req, fp, code, msg, headers):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)

    http_error_301 = http_error_302
    http_error_303 = http_error_302
    http_error_307 = http_error_302


def download_artifacts(run_id):
    arts = api_get(f"{API}/repos/{REPO}/actions/runs/{run_id}/artifacts")
    artifact = next((a for a in arts["artifacts"] if a["name"] == ARTIFACT), None)
    if not artifact:
        print("artifact not found:", [a["name"] for a in arts["artifacts"]], flush=True)
        sys.exit(1)
    print("artifact id:", artifact["id"], "size:", artifact["size_in_bytes"], flush=True)
    req = urllib.request.Request(
        f"{API}/repos/{REPO}/actions/artifacts/{artifact['id']}/zip",
        headers={"Authorization": f"Bearer {TOKEN}", "User-Agent": "pb-deploy"})
    op_nr = urllib.request.build_opener(NoRedirect)
    try:
        op_nr.open(req, timeout=60)
        raise SystemExit("no redirect?!")
    except urllib.error.HTTPError as e:
        loc = e.headers["Location"]
    with urllib.request.urlopen(loc, timeout=300) as r:
        blob = r.read()
    print("zip bytes:", len(blob), flush=True)
    os.makedirs(OUT, exist_ok=True)
    zf = zipfile.ZipFile(io.BytesIO(blob))
    saved = []
    for name in zf.namelist():
        if name.endswith(".apk"):
            data = zf.read(name)
            path = os.path.join(OUT, os.path.basename(name))
            with open(path, "wb") as f:
                f.write(data)
            saved.append((path, len(data)))
            print("saved:", path, len(data), flush=True)
    if not saved:
        print("no apk in zip:", zf.namelist(), flush=True)
        sys.exit(1)
    print("DONE", flush=True)


def poll_and_download():
    for i in range(30):
        try:
            runs = api_get(f"{API}/repos/{REPO}/actions/runs?per_page=1")["workflow_runs"]
            if not runs:
                print(f"[{i}] no runs yet", flush=True)
                time.sleep(30)
                continue
            run = runs[0]
            print(f"[{i}] run={run['id']} status={run['status']} conclusion={run.get('conclusion')} url={run['html_url']}", flush=True)
            if run["status"] == "completed":
                print("FINAL:", run["conclusion"], flush=True)
                if run.get("conclusion") != "success":
                    try:
                        jobs = api_get(f"{API}/repos/{REPO}/actions/runs/{run['id']}/jobs")["jobs"]
                        for job in jobs:
                            print("JOB:", job["name"], job.get("conclusion"), job.get("html_url"), flush=True)
                    except Exception as e:
                        print("jobs err:", e, flush=True)
                    sys.exit(1)
                download_artifacts(run["id"])
                return
        except SystemExit:
            raise
        except Exception as e:
            print(f"[{i}] error: {e}", flush=True)
        time.sleep(60)
    print("TIMEOUT", flush=True)
    sys.exit(1)


def sync():
    local_tree_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD^{tree}"], cwd=PROJECT, text=True).strip()

    try:
        branch = api_get(f"{API}/repos/{REPO}/branches/main")
        head_sha = branch["commit"]["sha"]
        print("remote main head:", head_sha, flush=True)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        head_sha = None
        print("branch main not found; bootstrapping empty repo", flush=True)

    existing = set()
    if head_sha:
        remote_commit = api_get(f"{API}/repos/{REPO}/git/commits/{head_sha}")
        if remote_commit["tree"]["sha"] == local_tree_sha:
            print("remote already in sync with local HEAD, skip", flush=True)
            return
        remote_tree = api_get(f"{API}/repos/{REPO}/git/trees/{head_sha}?recursive=1")
        if remote_tree.get("truncated"):
            print("remote tree truncated!", flush=True)
            sys.exit(1)
        existing = {e["sha"] for e in remote_tree["tree"] if e["type"] == "blob"}

    out = subprocess.check_output(["git", "ls-tree", "-r", "HEAD"], cwd=PROJECT, text=True)
    entries, to_upload, by_dir = [], [], {}
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        mode, otype, sha = meta.split()
        if otype != "blob":
            continue
        d = os.path.dirname(path)
        item = {"path": os.path.basename(path), "mode": mode, "type": "blob", "sha": sha}
        entries.append(item)
        by_dir.setdefault(d, []).append(item)
        if sha not in existing:
            to_upload.append(sha)
    to_upload = list(dict.fromkeys(to_upload))
    print(f"files: {len(entries)}, blobs not in head: {len(to_upload)}", flush=True)

    for sha in to_upload:
        if get_exists(f"{API}/repos/{REPO}/git/blobs/{sha}"):
            print("blob exists, skip:", sha[:12], flush=True)
            continue
        content = subprocess.check_output(["git", "cat-file", "blob", sha], cwd=PROJECT)
        time.sleep(5)
        r = api_post(f"{API}/repos/{REPO}/git/blobs", {
            "content": base64.b64encode(content).decode("ascii"),
            "encoding": "base64"})
        assert r["sha"] == sha, f"upload sha mismatch: {sha}"
        print("uploaded blob:", sha[:12], len(content), flush=True)

    all_dirs = set(by_dir.keys())
    for d in list(all_dirs):
        p = os.path.dirname(d)
        while p:
            all_dirs.add(p)
            p = os.path.dirname(p)

    dir_sha = {}
    pending = []
    for d in sorted(all_dirs, key=len, reverse=True):
        item = list(by_dir.get(d, []))
        for cd, sha in dir_sha.items():
            if os.path.dirname(cd) == d:
                item.append({"path": os.path.basename(cd), "mode": "40000", "type": "tree", "sha": sha})
        expected = compute_tree_sha(item)
        dir_sha[d] = expected
        if get_exists(f"{API}/repos/{REPO}/git/trees/{expected}"):
            print("tree exists, skip:", d or "<root>", expected, f"({len(item)} entries)", flush=True)
        else:
            pending.append((d, item, expected))
        time.sleep(0.2)

    print(f"trees to create: {len(pending)}", flush=True)
    for d, item, expected in pending:
        time.sleep(10)
        payload = [dict(it, mode="040000" if it["mode"] == "40000" else it["mode"]) for it in item]
        r = api_post(f"{API}/repos/{REPO}/git/trees", {"tree": payload})
        assert r["sha"] == expected, f"tree sha mismatch: {d or '<root>'} -> {r['sha']}, expected {expected}"
        print("tree created:", d or "<root>", r["sha"], f"({len(item)} entries)", flush=True)

    assert dir_sha[""] == local_tree_sha, f"root tree mismatch: {dir_sha['']} != {local_tree_sha}"
    print("root tree ready:", dir_sha[""], flush=True)

    body = {
        "tree": local_tree_sha,
        "message": SYNC_MSG,
        "authors": [{"name": "pang724", "email": "pang724@users.noreply.github.com"}],
    }
    if head_sha:
        body["parents"] = [head_sha]
    commit = api_post(f"{API}/repos/{REPO}/git/commits", body)
    print("commit created:", commit["sha"], flush=True)

    if head_sha:
        api_patch(f"{API}/repos/{REPO}/branches/main", {"sha": commit["sha"], "force": False})
    else:
        api_post(f"{API}/repos/{REPO}/git/refs", {"ref": "refs/heads/main", "sha": commit["sha"]})
    print("branch main updated to:", commit["sha"], flush=True)
    print("SYNC DONE", flush=True)


def bootstrap():
    """空仓库无法用 git data API 写入（409），先用 Contents API 创建首个提交。"""
    repo = api_get(f"{API}/repos/{REPO}")
    default_branch = repo["default_branch"]
    print("default branch:", default_branch, flush=True)

    try:
        api_get(f"{API}/repos/{REPO}/branches/main")
        print("branch main exists; no bootstrap needed", flush=True)
        return
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise

    with open(os.path.join(PROJECT, "README.md"), "rb") as f:
        content = base64.b64encode(f.read()).decode("ascii")
    r = _put_robust(f"{API}/repos/{REPO}/contents/README.md", {
        "message": "bootstrap: 初始提交",
        "content": content,
        "branch": default_branch,
    })
    new_sha = r["commit"]["sha"]
    print("bootstrap commit on", default_branch, ":", new_sha, flush=True)

    if default_branch != "main":
        time.sleep(5)
        api_post(f"{API}/repos/{REPO}/git/refs", {"ref": "refs/heads/main", "sha": new_sha})
        print("branch main created at:", new_sha, flush=True)
    print("BOOTSTRAP DONE", flush=True)


def compute_local_root():
    out = subprocess.check_output(["git", "ls-tree", "-r", "HEAD"], cwd=PROJECT, text=True)
    by_dir = {}
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        mode, otype, sha = meta.split()
        if otype != "blob":
            continue
        d = os.path.dirname(path)
        by_dir.setdefault(d, []).append({"path": os.path.basename(path), "mode": mode, "type": "blob", "sha": sha})
    all_dirs = set(by_dir.keys())
    for d in list(all_dirs):
        p = os.path.dirname(d)
        while p:
            all_dirs.add(p)
            p = os.path.dirname(p)
    dir_sha = {}
    for d in sorted(all_dirs, key=len, reverse=True):
        item = list(by_dir.get(d, []))
        for cd, sha in dir_sha.items():
            if os.path.dirname(cd) == d:
                item.append({"path": os.path.basename(cd), "mode": "40000", "type": "tree", "sha": sha})
        dir_sha[d] = compute_tree_sha(item)
    return dir_sha[""]


def finish():
    root_sha = compute_local_root()
    print("local root tree:", root_sha, flush=True)
    branch = api_get(f"{API}/repos/{REPO}/branches/main")
    head_sha = branch["commit"]["sha"]
    print("remote head:", head_sha, flush=True)
    rc = api_get(f"{API}/repos/{REPO}/git/commits/{head_sha}")
    if rc["tree"]["sha"] == root_sha:
        print("already synced", flush=True)
        return
    time.sleep(30)
    commit = None
    for attempt in range(10):
        try:
            commit = api_post(f"{API}/repos/{REPO}/git/commits", {
                "tree": root_sha,
                "message": SYNC_MSG,
                "authors": [{"name": "pang724", "email": "pang724@users.noreply.github.com"}],
                "parents": [head_sha]})
            break
        except urllib.error.HTTPError as e:
            print(f"commit POST attempt {attempt + 1} failed: {e.code}", flush=True)
            time.sleep(45)
    if commit is None:
        print("commit POST failed after retries", flush=True)
        sys.exit(1)
    print("commit created:", commit["sha"], flush=True)
    for attempt in range(10):
        try:
            api_patch(f"{API}/repos/{REPO}/branches/main", {"sha": commit["sha"], "force": False})
            break
        except urllib.error.HTTPError as e:
            print(f"branch PATCH attempt {attempt + 1} failed: {e.code}", flush=True)
            time.sleep(45)
    else:
        print("branch PATCH failed after retries", flush=True)
        sys.exit(1)
    print("branch main updated to:", commit["sha"], flush=True)
    print("SYNC DONE", flush=True)


def _get_robust(url, attempts=8):
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(url, headers=_headers("GET"))
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            last = f"{e.code}: {e.read().decode('utf-8', 'replace')[:200]}"
            if e.code not in (404, 408, 429, 500, 502, 503, 504):
                break
        except Exception as e:
            last = str(e)
        if attempt < attempts - 1:
            time.sleep(5 + attempt * 5)
    print(f"GET {url} -> failed after {attempts}: {last}", flush=True)
    raise SystemExit(1)


def _put_robust(url, body):
    data = json.dumps(body).encode("utf-8")
    last = None
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, data=data, headers=_headers("PUT"), method="PUT")
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            last = f"{e.code}: {e.read().decode('utf-8', 'replace')[:300]}"
            if e.code not in (404, 408, 429, 500, 502, 503, 504):
                break
        except Exception as e:
            last = str(e)
        if attempt < 4:
            time.sleep(20)
    print(f"PUT {url} -> failed: {last}", flush=True)
    raise SystemExit(1)


def get_main_files():
    b = _get_robust(f"{API}/repos/{REPO}/branches/main")
    head = b["commit"]["sha"]
    c = _get_robust(f"{API}/repos/{REPO}/git/commits/{head}")
    t = _get_robust(f"{API}/repos/{REPO}/git/trees/{c['tree']['sha']}?recursive=1")
    if t.get("truncated"):
        raise SystemExit("remote tree truncated!")
    return head, {e["path"]: e["sha"] for e in t["tree"] if e["type"] == "blob"}


def local_blobs():
    out = subprocess.check_output(["git", "ls-tree", "-r", "HEAD"], cwd=PROJECT, text=True)
    local = {}
    for line in out.splitlines():
        meta, p = line.split("\t", 1)
        if meta.split()[1] == "blob":
            local[p] = meta.split()[2]
    return local


def _upload_one(path, lsha, cur):
    content = subprocess.check_output(["git", "cat-file", "blob", lsha], cwd=PROJECT)
    body = {"message": f"sync: {path}", "content": base64.b64encode(content).decode("ascii"), "branch": "main"}
    if path in cur:
        body["sha"] = cur[path]
    r = _put_robust(f"{API}/repos/{REPO}/contents/{quote(path)}", body)
    print(f"OK ({len(content)}B): {path} -> commit {r['commit']['sha'][:12]}", flush=True)


def batch():
    head, cur = get_main_files()
    print("main head:", head, flush=True)
    local = local_blobs()
    todo = [p for p in sorted(local) if cur.get(p) != local[p]]
    wf = [p for p in todo if p.startswith(".github/")]
    todo = [p for p in todo if p not in wf] + wf
    print(f"todo ({len(todo)}):", todo, flush=True)
    failures = []
    for path in todo:
        ok = False
        for attempt in range(5):
            try:
                head, cur = get_main_files()
                if cur.get(path) == local[path]:
                    print(f"SKIP (already in sync): {path}", flush=True)
                    ok = True
                    break
                _upload_one(path, local[path], cur)
                ok = True
                break
            except SystemExit:
                raise
            except Exception as e:
                print(f"retry {attempt + 1} for {path}: {e}", flush=True)
                time.sleep(30)
        if ok:
            time.sleep(6)
        else:
            failures.append(path)
    head, cur = get_main_files()
    print("FINAL main head:", head, flush=True)
    local = local_blobs()
    diff = [p for p in sorted(local) if cur.get(p) != local[p]]
    extra = [p for p in sorted(cur) if p not in local]
    print("still differing from local:", diff, flush=True)
    print("extra on remote:", extra, flush=True)
    if failures or diff:
        print("BATCH INCOMPLETE", flush=True)
        sys.exit(1)
    print("BATCH DONE", flush=True)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "poll"
    if mode == "create":
        create_repo()
    elif mode == "bootstrap":
        bootstrap()
    elif mode == "sync":
        sync()
    elif mode == "finish":
        finish()
    elif mode == "batch":
        batch()
    else:
        poll_and_download()
