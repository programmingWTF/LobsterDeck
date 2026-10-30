#!/usr/bin/env python3
"""LobsterDeck API - read-only aggregation for Reports / Files / Agent memory.

Single-file, stdlib only. Sits beside existing services and never mutates
their data, except the documented reports token map.
"""
from __future__ import annotations

import hmac
import json
import os
import re
import secrets
import subprocess
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

HOME = Path("/vol1/1000/home/LiGuiyu")
REPORTS_DIR = Path("/vol1/1000/Docker/Reports/site/reports")
REPORTS_SITE = Path("/vol1/1000/Docker/Reports/site")
TOKENS_MAP = Path("/vol1/1000/Docker/Reports/nginx/tokens.map")
INBOX = HOME / "file-inbox"
LC_REPO = HOME / "LobsterContext"

STATE_DIR = Path(os.environ.get("LOBSTERDECK_STATE", "/vol1/1000/Docker/LobsterDeck"))
STATE_DIR.mkdir(parents=True, exist_ok=True)
PORT = int(os.environ.get("LOBSTERDECK_PORT", "3320"))
APP_VERSION = "1.0.0"


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load_token() -> str:
    env = os.environ.get("LOBSTERDECK_TOKEN", "").strip()
    if env:
        return env
    f = STATE_DIR / "token.txt"
    if f.exists():
        return f.read_text(encoding="utf-8").strip()
    tok = secrets.token_urlsafe(32)
    f.write_text(tok + "\n", encoding="utf-8")
    f.chmod(0o600)
    return tok


API_TOKEN = load_token()


def authed(handler) -> bool:
    h = handler.headers.get("Authorization", "")
    if not h.startswith("Bearer "):
        return False
    return hmac.compare_digest(h[7:].strip(), API_TOKEN)


def read_json(handler) -> dict:
    n = int(handler.headers.get("Content-Length", 0) or 0)
    if n <= 0:
        return {}
    return json.loads(handler.rfile.read(n) or b"{}")


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def human_size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{int(n)} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} GB"


# reports -------------------------------------------------------------------
def parse_tokens() -> dict:
    out = {}
    if not TOKENS_MAP.exists():
        return out
    for line in TOKENS_MAP.read_text(encoding="utf-8").splitlines():
        m = re.match(r'^"(/reports/([^"]+\.html))"\s+"([0-9a-f]+)";', line.strip())
        if m:
            out[m.group(2)] = m.group(3)
    return out


def write_tokens(mapping: dict) -> None:
    header = ('# shared report token map (URI -> token)\n'
              '# format: "/reports/xxx.html" "token";\n'
              '# remove a line to revoke; then: docker exec reports nginx -s reload\n')
    lines = [header]
    for name in sorted(mapping):
        lines.append(f'"/reports/{name}" "{mapping[name]}";\n')
    tmp = TOKENS_MAP.with_suffix(".tmp")
    tmp.write_text("".join(lines), encoding="utf-8")
    os.chmod(tmp, 0o664)
    os.replace(tmp, TOKENS_MAP)
    try:
        subprocess.run(["docker", "exec", "reports", "nginx", "-s", "reload"],
                       check=False, capture_output=True, timeout=20)
    except Exception:
        pass


def title_of(p: Path) -> str:
    try:
        head = p.read_text(encoding="utf-8", errors="ignore")[:20000]
        m = re.search(r"<title>(.*?)</title>", head, re.S | re.I)
        if m:
            t = re.sub(r"<[^>]+>", "", m.group(1)).strip()
            if t:
                return t
    except Exception:
        pass
    return p.stem


def reports_list() -> list:
    tokens = parse_tokens()
    items = []
    for f in REPORTS_DIR.glob("*.html"):
        if f.name in ("index.html", "all-index.html") or f.name.endswith(".body.html"):
            continue
        st = f.stat()
        m = re.match(r"(\d{4}-\d{2}-\d{2})", f.name)
        items.append({
            "id": f.name,
            "title": title_of(f),
            "date": m.group(1) if m else iso(st.st_mtime)[:10],
            "modified": iso(st.st_mtime),
            "size": st.st_size,
            "shared": f.name in tokens,
        })
    items.sort(key=lambda x: (x["date"], x["modified"]), reverse=True)
    return items


def report_html(name: str) -> str:
    p = REPORTS_DIR / name
    html = p.read_text(encoding="utf-8", errors="ignore")
    # keep each report's own look; only rebase root-relative assets onto our proxy
    html = re.sub(r'(src|href)="/', r'\1="../', html)
    return html


def safe_report_name(name: str):
    if re.fullmatch(r"[A-Za-z0-9._-]+\.html", name or "") and (REPORTS_DIR / name).exists():
        return name
    return None


# files ---------------------------------------------------------------------
IGNORE = {".DS_Store", ".desktop.ini", "Thumbs.db"}
STATE_FILE = STATE_DIR / "files_state.json"


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"initialized": False, "files": {}}


def save_state(state: dict) -> None:
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, STATE_FILE)


def rel_safe(rel: str) -> Path:
    p = (INBOX / unquote(rel or "")).resolve()
    if not str(p).startswith(str(INBOX.resolve())):
        raise ValueError("bad path")
    return p


def walk_files(limit: int = 4000) -> list:
    out = []
    for p in INBOX.rglob("*"):
        if len(out) >= limit:
            break
        try:
            if p.name in IGNORE or p.name.startswith("."):
                continue
            if not p.is_file():
                continue
            st = p.stat()
            out.append({"path": str(p.relative_to(INBOX)), "name": p.name,
                        "size": st.st_size, "size_h": human_size(st.st_size),
                        "mtime": st.st_mtime})
        except Exception:
            continue
    return out


def scan_state() -> dict:
    st = load_state()
    first = not st.get("initialized")
    known = st.setdefault("files", {})
    t = time.time()
    for item in walk_files():
        key = item["path"]
        rec = known.get(key)
        if rec is None:
            rec = {"first_seen": t, "mtime": item["mtime"], "size": item["size"]}
            known[key] = rec
            item["new"] = not first
        else:
            item["new"] = False
            if rec.get("mtime") != item["mtime"] or rec.get("size") != item["size"]:
                item["changed"] = True
                rec["mtime"] = item["mtime"]
                rec["size"] = item["size"]
        rec["last_seen"] = t
    st["initialized"] = True
    st["updated_at"] = now_iso()
    save_state(st)
    return {"items": walk_files(), "state": st}


def files_recent(limit: int = 20) -> list:
    scanned = scan_state()
    st = scanned["state"]
    items = []
    for item in scanned["items"]:
        rec = st["files"].get(item["path"], {})
        item["first_seen"] = rec.get("first_seen")
        items.append(item)
    items.sort(key=lambda x: x["mtime"], reverse=True)
    return items[:limit]


def files_list(rel: str) -> dict:
    target = rel_safe(rel)
    if not target.exists() or not target.is_dir():
        raise FileNotFoundError(rel)
    dirs, files = [], []
    for p in sorted(target.iterdir(), key=lambda x: x.name.lower()):
        if p.name in IGNORE or p.name.startswith("."):
            continue
        try:
            st = p.stat()
        except Exception:
            continue
        item = {"name": p.name, "path": str(p.relative_to(INBOX)), "is_dir": p.is_dir(),
                "size": 0 if p.is_dir() else st.st_size,
                "size_h": "" if p.is_dir() else human_size(st.st_size),
                "mtime": iso(st.st_mtime)}
        (dirs if p.is_dir() else files).append(item)
    return {"path": rel, "dirs": dirs, "files": files}


# agents --------------------------------------------------------------------
AGENT_LABELS = {
    "OpenClaw": "OpenClaw", "ClaudeCode": "Claude Code", "GitHubCopilot": "GitHub Copilot",
    "Qoder": "Qoder", "KimiCode": "Kimi Code", "ZCode": "Z Code",
    "DeepSeekHarness": "DeepSeek Harness", "WorkBuddy": "WorkBuddy", "Reasonix": "Reasonix",
    "Pi": "Pi", "OpenCode": "OpenCode", "Cursor": "Cursor", "Antigravity": "Antigravity",
    "Codex": "Codex", "Gemini": "Gemini",
}


def git(*args, timeout: int = 30) -> str:
    p = subprocess.run(["git", "-C", str(LC_REPO), *args], capture_output=True,
                       text=True, timeout=timeout)
    return p.stdout


_last_fetch = 0.0


def refresh_repo(min_interval: float = 60.0) -> None:
    """节流 fetch 远端 main（只更新 ref，不动工作区）。

    别的机器（Muse 等）推完记忆后，NAS 本地 clone 不会自己更新，看板会一直
    显示旧数据 —— 统计前先拉一次 refs，统计读 origin/main 而不是本地 HEAD。
    """
    global _last_fetch
    now = time.time()
    if now - _last_fetch < min_interval:
        return
    _last_fetch = now
    try:
        subprocess.run(["git", "-C", str(LC_REPO), "fetch", "--quiet", "origin",
                        "+refs/heads/main:refs/remotes/origin/main"],
                       capture_output=True, text=True, timeout=25)
    except Exception:
        pass


def stats_rev() -> str:
    p = subprocess.run(["git", "-C", str(LC_REPO), "rev-parse", "--verify", "-q", "origin/main"],
                       capture_output=True, text=True, timeout=10)
    return "origin/main" if p.returncode == 0 else "HEAD"


def known_agents() -> set:
    names = set(AGENT_LABELS)
    mem = LC_REPO / "Memory"
    try:
        names |= {p.name for p in mem.iterdir() if p.is_dir() and not p.name.startswith(".")}
    except OSError:
        pass
    return names


def agent_of(files: list, trailer: str = "", author: str = ""):
    # 2026-10-30: 归属口径与 agent.liguiyu.com 看板对齐 —— trailer -> 作者 -> 记忆目录。
    # 优先用提交里的 "Agent: <名字>" trailer；没写 trailer 的旧提交，若作者本身就是
    # 标准 Agent 名则归给作者；最后才回退到「改动最多的 Memory/<Agent>/ 目录」。
    # 这样改别人的记忆目录不会再被算成自己的提交。
    for name in re.split(r"[,;]", trailer or ""):
        name = name.strip()
        if name:
            return name
    author = (author or "").strip()
    if author and author in known_agents():
        return author
    counts = {}
    for f in files:
        m = re.match(r"Memory/([^/]+)/", f)
        if m:
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    return max(counts, key=counts.get) if counts else None


def commits(limit: int = 60, path: str = "Memory") -> list:
    refresh_repo()
    raw = git("log", stats_rev(), f"-{limit}", "--date=iso-strict",
              "--pretty=format:@@@%H%x1f%an%x1f%ad%x1f%s"
              "%x1f%(trailers:key=Agent,valueonly,separator=%x2C)",
              "--name-only", "--", path)
    out = []
    for block in raw.split("@@@"):
        block = block.strip("\n")
        if not block:
            continue
        lines = block.splitlines()
        head = lines[0].split("\x1f")
        if len(head) < 4:
            continue
        files = [l.strip() for l in lines[1:] if l.strip()]
        trailer = head[4] if len(head) > 4 else ""
        out.append({"sha": head[0], "author": head[1], "date": head[2],
                    "subject": head[3], "files": files,
                    "agent": agent_of(files, trailer, head[1])})
    return out


def _age_days(s: str) -> float:
    try:
        return max(0.0, (time.time() - datetime.fromisoformat(s).timestamp()) / 86400.0)
    except Exception:
        return 9999


def agents_overview() -> list:
    cs = commits(600)
    by = {}
    for c in cs:
        a = c["agent"]
        if not a:
            continue
        d = by.setdefault(a, {"agent": a, "label": AGENT_LABELS.get(a, a),
                              "commits": 0, "last": c["date"], "files": set(),
                              "touches": 0, "recent": []})
        d["commits"] += 1
        d["touches"] += len(c["files"])
        d["files"].update(c["files"])
        if len(d["recent"]) < 3:
            d["recent"].append({"sha": c["sha"], "subject": c["subject"], "date": c["date"]})

    # Every directory under Memory/ is an agent, even if it has no recent commits.
    mem = LC_REPO / "Memory"
    if mem.is_dir():
        for d in sorted(mem.iterdir()):
            if not d.is_dir() or d.name.startswith("."):
                continue
            entry = by.setdefault(d.name, {"agent": d.name,
                                           "label": AGENT_LABELS.get(d.name, d.name),
                                           "commits": 0, "last": None,
                                           "files": set(), "recent": []})
            entry["memory_files"] = sum(1 for p in d.rglob("*.md") if p.is_file())

    out = []
    for d in by.values():
        d["files"] = len(d["files"])
        d.setdefault("touches", 0)
        d["commits_30d"] = sum(1 for c in cs if c["agent"] == d["agent"] and _age_days(c["date"]) <= 30)
        d["color"] = agent_color(d["agent"])
        d["icon"] = agent_icon(d["agent"])
        out.append(d)
    out.sort(key=lambda x: (x["last"] or "", x["label"]), reverse=True)
    return out


def commit_detail(sha: str) -> dict:
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha or ""):
        raise ValueError("bad sha")
    meta = git("show", "-s", "--date=iso-strict",
               "--pretty=format:%H%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%b", sha)
    parts = meta.split("\x1f")
    patch = git("show", "--format=", "--no-color", sha, "--", "Memory", timeout=60)
    if len(patch) > 60000:
        patch = patch[:60000] + "\n... (truncated)"
    return {"sha": parts[0] if parts else sha,
            "author": parts[1] if len(parts) > 1 else "",
            "email": parts[2] if len(parts) > 2 else "",
            "date": parts[3] if len(parts) > 3 else "",
            "subject": parts[4] if len(parts) > 4 else "",
            "body": parts[5] if len(parts) > 5 else "",
            "patch": patch}


# repo overview / memory -----------------------------------------------------
AGENT_COLORS = {
    "OpenClaw": "#FF7A18", "ClaudeCode": "#D97757", "GitHubCopilot": "#8B949E",
    "Qoder": "#6C8CFF", "KimiCode": "#7C5CFF", "ZCode": "#2FBF71",
    "DeepSeekHarness": "#4D6BFE", "WorkBuddy": "#F2B01E", "Reasonix": "#FF5C8A",
    "Pi": "#14B8A6", "OpenCode": "#A3E635", "Cursor": "#C7C9D1",
    "Antigravity": "#8B5CF6", "Codex": "#10A37F", "Gemini": "#4285F4",
    "Muse": "#1877F2",
}
FALLBACK_COLORS = ["#FF7A18", "#4D6BFE", "#2FBF71", "#FF5C8A", "#8B5CF6", "#F2B01E"]


ICON_DIR = Path("/vol1/1000/Docker/LobsterDeck/icons")
ICON_MAP = {
    "OpenClaw": "openclaw.png", "ClaudeCode": "claude.png", "Codex": "codex.png",
    "GitHubCopilot": "githubcopilot.png", "OpenCode": "opencode.png",
    "Cursor": "cursor.png", "DeepSeekHarness": "deepseek.png", "Gemini": "gemini.png",
    "KimiCode": "kimi.png", "Pi": "pi.png", "Qoder": "qoder.png",
    "Reasonix": "reasonix.png", "Antigravity": "antigravity.png",
    "WorkBuddy": "workbuddy.png", "ZCode": "zcode.png",
    "Muse": "muse.png",
}


def agent_icon(name: str) -> str:
    fn = ICON_MAP.get(name)
    if not fn:
        return ""
    p = ICON_DIR / fn
    if not p.is_file():
        return ""
    try:
        import base64
        return "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode()
    except Exception:
        return ""


def agent_color(name: str) -> str:
    if name in AGENT_COLORS:
        return AGENT_COLORS[name]
    return FALLBACK_COLORS[sum(ord(c) for c in name) % len(FALLBACK_COLORS)]


def repo_stats() -> dict:
    commits_count = int((git("rev-list", "--count", "HEAD").strip() or "0"))
    files = len([l for l in git("ls-files").splitlines() if l.strip()])
    branch = git("rev-parse", "--abbrev-ref", "HEAD").strip() or "unknown"
    last = git("log", "-1", "--date=iso-strict", "--pretty=format:%ad").strip()
    size_h = ""
    try:
        out = subprocess.run(["du", "-sh", str(LC_REPO / ".git")], capture_output=True,
                             text=True, timeout=20).stdout.strip()
        size_h = out.split("	")[0].replace("G", " GB").replace("M", " MB").replace("K", " KB").strip()
    except Exception:
        pass

    mem = LC_REPO / "Memory"
    dirs = [d for d in mem.iterdir() if d.is_dir() and not d.name.startswith(".")] if mem.is_dir() else []
    with_md = [d for d in dirs if any(d.rglob("*.md"))]
    md_count = sum(1 for d in dirs for _ in d.rglob("*.md"))

    cs = commits(400)
    daily = {}
    for c in cs:
        day = (c["date"] or "")[:10]
        if not day:
            continue
        slot = daily.setdefault(day, {})
        who = c["agent"] or "Other"
        slot[who] = slot.get(who, 0) + 1
    series = []
    for day in sorted(daily):
        agents = daily[day]
        series.append({"date": day, "total": sum(agents.values()),
                       "agents": [{"agent": a, "count": n, "color": agent_color(a)}
                                  for a, n in sorted(agents.items(), key=lambda kv: -kv[1])]})

    return {
        "commits": commits_count, "files": files, "size": size_h or "-",
        "branch": branch, "last_commit": last,
        "memory_dirs": len(dirs), "memory_dirs_with_md": len(with_md),
        "markdown_files": md_count,
        "agents": len(dirs),
        "daily": series[-30:],
    }


def memory_root() -> Path:
    return LC_REPO / "Memory"


def repo_path(rel: str) -> Path:
    base = LC_REPO.resolve()
    target = (base / unquote(rel or "")).resolve()
    if not str(target).startswith(str(base)):
        raise ValueError("bad path")
    return target


def repo_list(rel: str) -> dict:
    target = repo_path(rel)
    if not target.is_dir():
        raise FileNotFoundError(rel)
    dirs, files = [], []
    for p in sorted(target.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower())):
        if p.name.startswith(".") or p.name in ("node_modules", "__pycache__"):
            continue
        try:
            st = p.stat()
        except Exception:
            continue
        item = {"name": p.name, "path": str(p.relative_to(LC_REPO)),
                "is_dir": p.is_dir(),
                "size": 0 if p.is_dir() else st.st_size,
                "size_h": "" if p.is_dir() else human_size(st.st_size),
                "mtime": iso(st.st_mtime),
                "ext": "" if p.is_dir() else p.suffix.lower()}
        (dirs if p.is_dir() else files).append(item)
    return {"path": rel, "dirs": dirs, "files": files}


TEXT_EXT = {".md", ".markdown", ".txt", ".json", ".yml", ".yaml", ".toml", ".py",
            ".sh", ".swift", ".js", ".ts", ".css", ".html", ".gitignore"}


def repo_read(rel: str) -> dict:
    p = repo_path(rel)
    if not p.is_file():
        raise FileNotFoundError(rel)
    if p.suffix.lower() not in TEXT_EXT and p.name != "LICENSE":
        raise ValueError("unsupported file type")
    raw = p.read_text(encoding="utf-8", errors="replace")[:400000]
    if p.suffix.lower() in (".md", ".markdown"):
        import markdown as md_mod
        html = md_mod.markdown(raw, extensions=["fenced_code", "tables", "sane_lists"])
        return {"name": p.name, "path": rel, "kind": "markdown", "html": html}
    return {"name": p.name, "path": rel, "kind": "text", "text": raw}


def memory_recent(limit: int = 6) -> list:
    base = memory_root()
    rows = []
    if not base.is_dir():
        return rows
    for p in base.rglob("*.md"):
        try:
            st = p.stat()
        except Exception:
            continue
        rows.append({"name": p.name, "path": str(p.relative_to(base)),
                     "mtime": st.st_mtime, "size": st.st_size})
    rows.sort(key=lambda r: r["mtime"], reverse=True)
    return rows[:limit]


def memory_path(rel: str) -> Path:
    base = memory_root().resolve()
    target = (base / unquote(rel or "")).resolve()
    if not str(target).startswith(str(base)):
        raise ValueError("bad path")
    return target


def memory_list(rel: str) -> dict:
    target = memory_path(rel)
    if not target.is_dir():
        raise FileNotFoundError(rel)
    dirs, files = [], []
    for p in sorted(target.iterdir(), key=lambda x: x.name.lower()):
        if p.name.startswith("."):
            continue
        try:
            st = p.stat()
        except Exception:
            continue
        item = {"name": p.name, "path": str(p.relative_to(memory_root())),
                "is_dir": p.is_dir(),
                "size": 0 if p.is_dir() else st.st_size,
                "size_h": "" if p.is_dir() else human_size(st.st_size),
                "mtime": iso(st.st_mtime)}
        (dirs if p.is_dir() else files).append(item)
    return {"path": rel, "dirs": dirs, "files": files}


def memory_read(rel: str) -> dict:
    p = memory_path(rel)
    if not p.is_file():
        raise FileNotFoundError(rel)
    raw = p.read_text(encoding="utf-8", errors="replace")[:400000]
    if p.suffix.lower() in (".md", ".markdown"):
        import markdown as md_mod
        html = md_mod.markdown(raw, extensions=["fenced_code", "tables", "sane_lists"])
        return {"name": p.name, "path": rel, "kind": "markdown", "html": html}
    return {"name": p.name, "path": rel, "kind": "text", "text": raw}


def save_upload(rel_dir: str, name: str, data: bytes) -> dict:
    name = os.path.basename(name or "").strip()
    if not name or name.startswith(".") or "/" in name or "\\" in name:
        raise ValueError("bad filename")
    target_dir = rel_safe(rel_dir)
    if not target_dir.is_dir():
        raise ValueError("bad directory")
    target = target_dir / name
    tmp = target.with_name(target.name + ".part")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o664)
    os.replace(tmp, target)
    return {"name": name, "path": str(target.relative_to(INBOX)), "size": len(data)}


# home layout ---------------------------------------------------------------
DEFAULT_LAYOUT = {
    "version": 1, "generated_by": "lobster", "updated_at": None,
    "modules": [
        {"id": "hero", "kind": "hero", "size": "hero", "title": "你好，桂鱼",
         "subtitle": "你的 AI 空间，都在这里。", "accent": "orange"},
        {"id": "recent-reports", "kind": "list", "size": "large", "title": "最新报告",
         "subtitle": "深度调研与每日简报", "source": "reports", "limit": 3},
        {"id": "new-files", "kind": "list", "size": "large", "title": "新到的文件",
         "subtitle": "来自文件站的最新变化", "source": "files", "limit": 4},
        {"id": "agents", "kind": "agents", "size": "large", "title": "Agent 在忙什么",
         "subtitle": "记忆库最近的变化", "source": "agents", "limit": 3},
        {"id": "quick", "kind": "actions", "size": "medium", "title": "快捷入口",
         "items": [
             {"title": "报告台", "subtitle": "reports.liguiyu.com",
              "url": "https://reports.liguiyu.com", "icon": "doc.text"},
             {"title": "文件站", "subtitle": "file.liguiyu.com",
              "url": "https://file.liguiyu.com/fs", "icon": "folder"},
         ]},
    ],
}
LAYOUT_FILE = STATE_DIR / "home.json"


def load_layout() -> dict:
    if LAYOUT_FILE.exists():
        try:
            return json.loads(LAYOUT_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    save_layout(DEFAULT_LAYOUT)
    return dict(DEFAULT_LAYOUT)


def save_layout(layout: dict) -> None:
    layout = dict(layout)
    layout["updated_at"] = now_iso()
    tmp = LAYOUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(layout, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, LAYOUT_FILE)


def resolve_module(m: dict) -> dict:
    out = dict(m)
    kind = m.get("kind", "list")
    limit = int(m.get("limit", 4))
    src = m.get("source")
    if kind == "list" and src == "reports":
        out["items"] = [{"title": r["title"], "subtitle": r["date"], "id": r["id"],
                         "shared": r["shared"]} for r in reports_list()[:limit]]
    elif kind == "list" and src == "files":
        prefix = m.get("prefix")
        pool = files_recent(400) if prefix else files_recent(limit)
        if prefix:
            pool = [f for f in pool if f["path"].startswith(prefix)][:limit]
        out["items"] = [{"title": f["name"],
                         "subtitle": f"{f['size_h']} · " + iso(f["mtime"])[:16].replace("T", " "),
                         "path": f["path"], "new": f.get("new", False)}
                        for f in pool]
    elif kind == "list" and src == "memory":
        out["items"] = [{"title": f["name"],
                         "subtitle": f["path"].rsplit("/", 1)[0] if "/" in f["path"] else "Memory",
                         "path": f["path"]}
                        for f in memory_recent(limit)]
    elif kind == "agents":
        out["items"] = [{"title": a["label"],
                         "subtitle": a["last"][:16].replace("T", " "),
                         "detail": f"{a['commits_30d']} 次更新", "agent": a["agent"]}
                        for a in agents_overview()[:limit]]
    return out


def overview() -> dict:
    layout = load_layout()
    rs = reports_list()
    fl = files_recent(3)
    ag = agents_overview()
    return {"generated_at": now_iso(),
            "layout_updated_at": layout.get("updated_at"),
            "generated_by": layout.get("generated_by", "lobster"),
            "stats": {"reports": len(rs), "files": len(fl), "agents": len(ag)},
            "modules": [resolve_module(m) for m in layout.get("modules", [])]}


# server --------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "LobsterDeck/" + APP_VERSION

    def log_message(self, fmt, *args):
        print("[deck]", self.address_string(), fmt % args)

    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _raw(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _guard(self) -> bool:
        if authed(self):
            return True
        self._json(401, {"error": "unauthorized"})
        return False

    def do_GET(self):
        u = urlparse(self.path)
        p, q = u.path, parse_qs(u.query)
        try:
            if p == "/api/v1/health":
                self._json(200, {"ok": True, "version": APP_VERSION, "time": now_iso()})
                return
            if not self._guard():
                return
            if p == "/api/v1/overview":
                self._json(200, overview())
            elif p == "/api/v1/home/layout":
                self._json(200, load_layout())
            elif p == "/api/v1/reports":
                self._json(200, {"items": reports_list()})
            elif p.startswith("/api/v1/reports/") and p.endswith("/html"):
                name = safe_report_name(p.split("/")[-2])
                if not name:
                    self._json(404, {"error": "not found"})
                else:
                    self._json(200, {"id": name, "html": report_html(name)})
            elif p.startswith("/api/v1/report-assets/"):
                rel = unquote(p[len("/api/v1/report-assets/"):])
                target = (REPORTS_SITE / rel).resolve()
                if not str(target).startswith(str(REPORTS_SITE.resolve())) or not target.is_file():
                    self._json(404, {"error": "not found"})
                    return
                ctype = {".css": "text/css", ".js": "application/javascript",
                         ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                         ".svg": "image/svg+xml", ".woff2": "font/woff2",
                         ".woff": "font/woff"}.get(target.suffix, "application/octet-stream")
                self._raw(200, target.read_bytes(), ctype)
            elif p == "/api/v1/reports/tokens":
                self._json(200, {"tokens": parse_tokens()})
            elif p == "/api/v1/files":
                self._json(200, files_list(q.get("path", [""])[0]))
            elif p == "/api/v1/files/recent":
                items = files_recent(int(q.get("limit", ["20"])[0]))
                self._json(200, {"items": [dict(it, mtime=iso(it["mtime"])) for it in items]})
            elif p == "/api/v1/files/raw":
                target = rel_safe(q.get("path", [""])[0])
                if not target.is_file():
                    self._json(404, {"error": "not found"})
                else:
                    self._raw(200, target.read_bytes(), "application/octet-stream")
            elif p == "/api/v1/agents":
                self._json(200, {"items": agents_overview()})
            elif p == "/api/v1/agents/commit":
                self._json(200, commit_detail(q.get("sha", [""])[0]))
            elif p == "/api/v1/repo":
                self._json(200, repo_stats())
            elif p == "/api/v1/repo/tree":
                self._json(200, repo_list(q.get("path", [""])[0]))
            elif p == "/api/v1/repo/file":
                self._json(200, repo_read(q.get("path", [""])[0]))
            elif p == "/api/v1/memory":
                self._json(200, memory_list(q.get("path", [""])[0]))
            elif p == "/api/v1/memory/file":
                self._json(200, memory_read(q.get("path", [""])[0]))
            elif p.startswith("/api/v1/agents/") and p.endswith("/commits"):
                name = p.split("/")[-2]
                limit = int(q.get("limit", ["40"])[0])
                items = [c for c in commits(300) if c["agent"] == name][:limit]
                self._json(200, {"items": items})
            else:
                self._json(404, {"error": "not found"})
        except FileNotFoundError:
            self._json(404, {"error": "not found"})
        except ValueError as e:
            self._json(400, {"error": str(e)})
        except Exception as e:
            self._json(500, {"error": "server error", "detail": str(e)[:300]})

    def do_PUT(self):
        if not self._guard():
            return
        path = urlparse(self.path).path
        try:
            if path == "/api/v1/home/layout":
                layout = read_json(self)
                if not isinstance(layout.get("modules"), list):
                    raise ValueError("modules required")
                save_layout(layout)
                self._json(200, {"ok": True, "updated_at": load_layout().get("updated_at")})
                return

            # Single-module upsert: several agents can update their own card
            # without clobbering the whole layout.
            if path.startswith("/api/v1/home/modules/"):
                mod_id = unquote(path[len("/api/v1/home/modules/"):]).strip()
                if not mod_id:
                    raise ValueError("module id required")
                module = read_json(self)
                if not isinstance(module, dict):
                    raise ValueError("module object required")
                module["id"] = mod_id

                layout = load_layout()
                modules = [m for m in layout.get("modules", []) if m.get("id") != mod_id]
                anchor = module.pop("after", None) or module.pop("before", None)
                index = len(modules)
                if anchor:
                    for i, m in enumerate(modules):
                        if m.get("id") == anchor:
                            index = i + 1
                            break
                modules.insert(index, module)
                layout["modules"] = modules
                save_layout(layout)
                self._json(200, {"ok": True, "id": mod_id,
                                 "updated_at": load_layout().get("updated_at")})
                return

            self._json(404, {"error": "not found"})
        except Exception as e:
            self._json(400, {"error": str(e)[:300]})

    def do_DELETE(self):
        if not self._guard():
            return
        path = urlparse(self.path).path
        try:
            if path.startswith("/api/v1/home/modules/"):
                mod_id = unquote(path[len("/api/v1/home/modules/"):]).strip()
                layout = load_layout()
                before = len(layout.get("modules", []))
                layout["modules"] = [m for m in layout.get("modules", []) if m.get("id") != mod_id]
                if len(layout["modules"]) == before:
                    self._json(404, {"error": "module not found"})
                    return
                save_layout(layout)
                self._json(200, {"ok": True, "removed": mod_id})
                return
            self._json(404, {"error": "not found"})
        except Exception as e:
            self._json(400, {"error": str(e)[:300]})

    def do_POST(self):
        if not self._guard():
            return
        u = urlparse(self.path)
        p, q = u.path, parse_qs(u.query)
        try:
            if p == "/api/v1/files/upload":
                rel_dir = q.get("path", [""])[0]
                name = q.get("name", [""])[0]
                n = int(self.headers.get("Content-Length", 0) or 0)
                if n <= 0 or n > 300 * 1024 * 1024:
                    raise ValueError("bad size")
                chunks, left = [], n
                while left > 0:
                    block = self.rfile.read(min(1 << 20, left))
                    if not block:
                        break
                    chunks.append(block)
                    left -= len(block)
                self._json(200, save_upload(rel_dir, name, b"".join(chunks)))
                return
            if p == "/api/v1/reports/tokens":
                data = read_json(self)
                name, action = data.get("file", ""), data.get("action", "")
                if not safe_report_name(name):
                    raise ValueError("bad file")
                mapping = parse_tokens()
                if action == "share":
                    mapping[name] = secrets.token_hex(12)
                elif action == "rotate":
                    if name not in mapping:
                        raise ValueError("该报告尚未共享")
                    mapping[name] = secrets.token_hex(12)
                elif action == "revoke":
                    if name not in mapping:
                        raise ValueError("该报告尚未共享")
                    mapping.pop(name, None)
                else:
                    raise ValueError("bad action")
                write_tokens(mapping)
                self._json(200, {"ok": True, "token": mapping.get(name)})
            else:
                self._json(404, {"error": "not found"})
        except Exception as e:
            self._json(400, {"error": str(e)[:300]})


def main() -> None:
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"LobsterDeck API v{APP_VERSION} on :{PORT}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
