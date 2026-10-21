"""fastmac memory — live RAM sampling. Pure stdlib, read-only."""
from __future__ import annotations
import os, re, subprocess, time

_PAGE = 4096
_TOTAL = 0


def _init():
    global _PAGE, _TOTAL
    try:
        _TOTAL = int(subprocess.run(["sysctl", "-n", "hw.memsize"],
                                    capture_output=True, text=True).stdout.strip())
    except Exception:
        _TOTAL = 0
    try:
        _PAGE = os.sysconf("SC_PAGE_SIZE")
    except Exception:
        _PAGE = 4096


_init()


def _vm_stat() -> dict[str, int]:
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True,
                             timeout=5, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    page = _PAGE
    m = re.search(r"page size of (\d+) bytes", out)
    if m:
        page = int(m.group(1))
    vals = {}
    for line in out.splitlines()[1:]:
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        v = v.strip().rstrip(".")
        if v.isdigit():
            vals[k.strip()] = int(v) * page
    return vals


def _swap() -> dict[str, float]:
    try:
        out = subprocess.run(["sysctl", "-n", "vm.swapusage"],
                             capture_output=True, text=True, timeout=5,
                             check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    g = dict(re.findall(r"(\w+) = ([\d.]+)M", out))
    return {k: float(v) * 1024 * 1024 for k, v in g.items()}


def sample() -> dict:
    """One point-in-time memory reading."""
    v = _vm_stat()
    g = lambda *keys: next((v[k] for k in keys if k in v), 0)

    free = g("Pages free")
    active = g("Pages active")
    inactive = g("Pages inactive")
    spec = g("Pages speculative")
    wired = g("Pages wired down")
    compressor = g("Pages occupied by compressor")
    stored = g("Pages stored in compressor")
    purgeable = g("Pages purgeable")
    filebacked = g("File-backed pages")

    app = active + inactive + spec
    used = app + wired + compressor
    sw = _swap()
    swap_used = sw.get("used", 0.0)
    swap_total = sw.get("total", 0.0)
    ratio = (stored / compressor) if compressor else 0.0

    # macOS-style pressure: how much of RAM is genuinely unavailable for reuse
    reclaimable = filebacked + purgeable
    pressure = max(0.0, min(100.0,
                   (wired + compressor + max(0, app - reclaimable)) / _TOTAL * 100)) \
        if _TOTAL else 0.0

    if swap_used > 1024 ** 3 or pressure > 80:
        level, verdict = "bad", "under pressure — swapping to disk, expect stalls"
    elif swap_used > 256 * 1024 ** 2 or pressure > 60:
        level, verdict = "warn", "moderate — the compressor is working hard"
    else:
        level, verdict = "good", "comfortable"

    return {
        "t": time.time(), "total": _TOTAL,
        "app": app, "wired": wired, "compressor": compressor, "free": free,
        "stored": stored, "used": used, "purgeable": purgeable,
        "filebacked": filebacked, "ratio": ratio,
        "swap_used": swap_used, "swap_total": swap_total,
        "pressure": pressure, "level": level, "verdict": verdict,
        "pageins": g("Pageins"), "pageouts": g("Pageouts"),
    }


def _app_name(path: str) -> str:
    m = re.search(r"/([^/]+)\.app/", path)
    if m:
        return m.group(1)
    n = path.rsplit("/", 1)[-1].strip()
    return n or path


def processes(limit: int = 14) -> list[dict]:
    """Top memory consumers, grouped by application."""
    try:
        out = subprocess.run(["ps", "-Ao", "rss=,pid=,comm="],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    groups: dict[str, dict] = {}
    total = 0
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            rss = int(parts[0]) * 1024
        except ValueError:
            continue
        name = _app_name(parts[2])
        g = groups.setdefault(name, {"name": name, "rss": 0, "procs": 0})
        g["rss"] += rss
        g["procs"] += 1
        total += rss
    rows = sorted(groups.values(), key=lambda x: -x["rss"])[:max(0, int(limit))]
    for r in rows:
        r["share"] = (r["rss"] / total * 100) if total else 0
    return rows


def disk(path: str = "/System/Volumes/Data") -> dict:
    try:
        st = os.statvfs(path)
    except OSError:
        return {"path": path, "free": 0, "total": 0, "used": 0, "pct": 0}
    free = st.f_bavail * st.f_frsize
    total = st.f_blocks * st.f_frsize
    return {"path": path, "free": free, "total": total, "used": total - free,
            "pct": (total - free) / total * 100 if total else 0}
