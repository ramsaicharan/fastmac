"""diskmap core — scanning, storage, analysis. Pure stdlib."""
from __future__ import annotations
import os, sys, json, time, gzip, hashlib, plistlib, shutil, subprocess
import tempfile, threading, re
from contextlib import contextmanager
try:
    import fcntl
except ImportError:  # pragma: no cover - Windows fallback for development
    fcntl = None
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, asdict
from pathlib import Path

HOME = Path.home()
STATE = HOME / ".diskmap"
SCANS = STATE / "scans"
QUEUE = STATE / "queue.json"
LOGF  = STATE / "cleanup.log"
# Importing the module must be read-only.  In particular, `diskmap mem` and
# `diskmap --help` must not create a diskmap directory just because the disk
# scanner is also available in the same process.
_QUEUE_LOCK = threading.RLock()
MAX_QUEUE_ITEMS = 5_000
MAX_SNAPSHOTS = 12
MAX_DUPLICATE_PATHS = 120_000

def _ensure_state() -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    SCANS.mkdir(parents=True, exist_ok=True)

def _under(path: str | Path, root: str | Path) -> bool:
    p = os.path.realpath(os.fspath(path))
    r = os.path.realpath(os.fspath(root)).rstrip(os.sep) or os.sep
    return p == r or p.startswith(r + os.sep)


@contextmanager
def _queue_process_lock():
    """Serialize queue read/modify/write operations across CLI/server processes."""
    _ensure_state()
    lock_path = QUEUE.with_name(QUEUE.name + ".lock")
    with open(lock_path, "a+", encoding="utf-8") as fh:
        if fcntl is not None:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            if fcntl is not None:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)

def _snapshot_name(name: str) -> str:
    """Return a portable snapshot basename; never allow path traversal."""
    if not name or name in {".", ".."} or os.path.basename(name) != name:
        raise ValueError("snapshot name must be a simple filename")
    if any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in name):
        raise ValueError("snapshot name may contain only letters, numbers, dot, dash and underscore")
    return name

# ───────────────────────────── safety ─────────────────────────────

PROTECTED = {
    str(HOME), str(HOME / "Documents"), str(HOME / "Downloads"), str(HOME / "Desktop"),
    str(HOME / "Library"), str(HOME / "Pictures"), str(HOME / "Movies"),
    str(HOME / "Music"), str(HOME / ".ssh"), str(HOME / "Applications"), str(HOME / ".Trash"),
    str(STATE),
}
SYSTEM_PREFIXES = ("/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple", "/cores", "/dev", "/Volumes/Preboot")

def is_safe_to_delete(p: str) -> tuple[bool, str]:
    """Never stage system-critical paths. Mirrors DiskBuddy's exclusion rule."""
    try:
        raw = os.path.expanduser(os.fspath(p))
        if isinstance(raw, bytes):
            raw = os.fsdecode(raw)
        if not isinstance(raw, str) or not raw or "\x00" in raw:
            return False, "invalid path"
        if ".." in Path(raw).parts:
            return False, "parent-directory traversal is not allowed"
    except (TypeError, ValueError):
        return False, "invalid path"
    try:
        rp = os.path.realpath(raw)
    except (OSError, TypeError, ValueError):
        return False, "unresolvable path"
    if rp in PROTECTED:
        return False, "protected root directory"
    state_root = os.path.realpath(os.fspath(STATE))
    if rp == state_root or rp.startswith(state_root + os.sep):
        return False, "diskmap state is protected"
    if rp.startswith(str(HOME / ".Trash") + os.sep):
        return False, "Trash contents are not staged"
    try:
        if os.path.ismount(rp):
            return False, "mounted volume root is not staged"
    except (OSError, TypeError, ValueError):
        return False, "unresolvable path"
    if rp == "/" or rp.count(os.sep) < 2:
        return False, "too close to filesystem root"
    for pre in SYSTEM_PREFIXES:
        if rp == pre or rp.startswith(pre + os.sep):
            return False, "system path"
    if rp.startswith("/Applications/") and rp.count(os.sep) == 2 and not rp.endswith(".app"):
        return False, "system path"
    inside_home = rp == str(HOME) or rp.startswith(str(HOME) + os.sep)
    if not (inside_home or rp.startswith("/Applications/") or rp.startswith("/Volumes/")):
        return False, "outside home, /Applications and /Volumes"
    return True, ""

# ─────────────────────────── scan model ───────────────────────────

@dataclass
class Node:
    name: str
    path: str
    size: int = 0          # logical bytes (st_size)
    disk: int = 0          # bytes actually on disk (st_blocks * 512)
    files: int = 0
    dirs: int = 0
    mtime: float = 0.0
    is_dir: bool = True
    children: list = field(default_factory=list)

def _fmt(n: float) -> str:
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or u == "TB":
            return f"{n:.0f} {u}" if u in ("B", "KB") else f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TB"

class Scanner:
    """Concurrent directory walk. Threads help because os.scandir releases the GIL."""
    def __init__(self, root: str, workers: int = 16, progress=True,
                 max_files_kept: int = MAX_DUPLICATE_PATHS):
        self.root = os.path.realpath(os.path.expanduser(root))
        # More threads retain more stacks and directory entries without making a
        # metadata-heavy APFS walk meaningfully faster. Keep the default bounded.
        self.workers = max(1, min(int(workers), 8))
        self.progress = progress and sys.stderr.isatty()
        self.n_files = 0
        self.n_dirs = 0
        self.n_bytes = 0
        self.errors = 0
        self.t0 = time.time()
        self.big_files: list[tuple[int, float, str]] = []   # (disk, mtime, path)
        self.by_size: dict[int, list[str]] = {}             # for duplicate detection
        self.max_files_kept = max_files_kept
        self._last_tick = 0.0
        self._lock = threading.Lock()
        if not os.path.isdir(self.root) or not os.access(self.root, os.R_OK):
            raise ValueError(f"scan root is not a readable directory: {self.root}")

    def _tick(self):
        if not self.progress:
            return
        now = time.time()
        if now - self._last_tick < 0.15:
            return
        self._last_tick = now
        el = now - self.t0
        with self._lock:
            n_files, n_bytes = self.n_files, self.n_bytes
        rate = n_files / el if el else 0
        sys.stderr.write(
            f"\r  scanning… {n_files:,} files  {_fmt(n_bytes)}  "
            f"{rate:,.0f} files/s  {el:.1f}s   ")
        sys.stderr.flush()

    def _walk(self, path: str, depth: int) -> Node:
        node = Node(name=os.path.basename(path) or path, path=path)
        subdirs: list[str] = []
        try:
            with os.scandir(path) as it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue
                        if e.is_dir(follow_symlinks=False):
                            subdirs.append(e.path)
                        else:
                            st = e.stat(follow_symlinks=False)
                            disk = st.st_blocks * 512
                            node.size += st.st_size
                            node.disk += disk
                            node.files += 1
                            node.mtime = max(node.mtime, st.st_mtime)
                            with self._lock:
                                self.n_files += 1
                                self.n_bytes += disk
                                if disk >= 50 * 1024 * 1024:
                                    entry = (disk, st.st_mtime, e.path)
                                    # Keep a bounded sample of the largest files.  This
                                    # keeps a pathological tree from retaining millions
                                    # of path strings solely for Age Map.
                                    if len(self.big_files) < 4000:
                                        self.big_files.append(entry)
                                    else:
                                        j = min(range(len(self.big_files)),
                                                key=lambda i: self.big_files[i][0])
                                        if disk > self.big_files[j][0]:
                                            self.big_files[j] = entry
                                if st.st_size >= 1024 * 1024 and self.n_files <= self.max_files_kept:
                                    self.by_size.setdefault(st.st_size, []).append(e.path)
                    except OSError:
                        with self._lock:
                            self.errors += 1
        except OSError:
            with self._lock:
                self.errors += 1
            return node

        with self._lock:
            self.n_dirs += len(subdirs)
        self._tick()

        if depth == 0 and len(subdirs) > 1:
            with ThreadPoolExecutor(max_workers=self.workers) as ex:
                kids = list(ex.map(lambda d: self._walk(d, depth + 1), subdirs))
        else:
            kids = [self._walk(d, depth + 1) for d in subdirs]

        for k in kids:
            node.size += k.size
            node.disk += k.disk
            node.files += k.files
            node.dirs += k.dirs + 1
            node.mtime = max(node.mtime, k.mtime)
            node.children.append(k)

        node.children.sort(key=lambda c: c.disk, reverse=True)
        return node

    def run(self) -> Node:
        tree = self._walk(self.root, 0)
        if self.progress:
            with self._lock:
                n_files, n_dirs, n_bytes, errors = self.n_files, self.n_dirs, self.n_bytes, self.errors
            el = time.time() - self.t0
            sys.stderr.write(
                f"\r  scanned {n_files:,} files in {n_dirs:,} dirs — "
                f"{_fmt(n_bytes)} in {el:.1f}s"
                + (f"  ({errors:,} unreadable)" if errors else "") + "\n")
            sys.stderr.flush()
        return tree

# ─────────────────────── prune / serialise ───────────────────────

def prune(node: Node, min_bytes: int, max_children: int = 60, depth: int = 0,
          max_depth: int = 12) -> dict:
    """Shrink the tree for the viewer: drop noise, roll the tail into 'other'."""
    d = {"n": node.name, "p": node.path, "k": "dir", "s": node.disk,
         "l": node.size, "f": node.files, "d": node.dirs, "m": int(node.mtime)}
    if depth >= max_depth or not node.children:
        return d
    kids = [c for c in node.children if c.disk >= min_bytes]
    kept, tail = kids[:max_children], kids[max_children:]
    out = [prune(c, min_bytes, max_children, depth + 1, max_depth) for c in kept]
    rest = sum(c.disk for c in tail) + sum(c.disk for c in node.children if c.disk < min_bytes)
    rest_logical = (sum(c.size for c in tail)
                    + sum(c.size for c in node.children if c.disk < min_bytes))
    n_rest = len(tail) + sum(1 for c in node.children if c.disk < min_bytes)
    if rest > 0 and n_rest:
        out.append({"n": f"… {n_rest:,} smaller items", "p": node.path,
                    "k": "other", "s": rest, "l": rest_logical,
                    "f": 0, "d": 0, "m": int(node.mtime),
                    "other": True})
    if out:
        d["c"] = out
    return d

def save_scan(name: str, tree: Node, scanner: Scanner, meta: dict | None = None,
              extras: dict | None = None) -> Path:
    _ensure_state()
    name = _snapshot_name(name)
    payload = {
        "version": 2,
        "root": scanner.root,
        "created": time.time(),
        "elapsed": time.time() - scanner.t0,
        "totals": {"files": scanner.n_files, "dirs": scanner.n_dirs,
                   "bytes": scanner.n_bytes, "errors": scanner.errors},
        "tree": prune(tree, min_bytes=1024 * 1024),
        "big_files": sorted(scanner.big_files, reverse=True)[:4000],
        "extras": extras or {},          # quick wins / apps / dupes, so reopening is instant
        "meta": meta or {},
    }
    path = SCANS / f"{name}.json.gz"
    fd, temp = tempfile.mkstemp(prefix=f"{name}.", suffix=".tmp", dir=SCANS)
    os.close(fd)
    try:
        with gzip.open(temp, "wt", encoding="utf-8") as fh:
            json.dump(payload, fh, separators=(",", ":"), ensure_ascii=False)
        os.replace(temp, path)
    finally:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
    # Snapshots are derived reports, not user documents. Keep a small rolling
    # window so repeated scans cannot quietly consume the whole disk.
    snapshots = sorted(SCANS.glob("*.json.gz"),
                       key=lambda p: p.stat().st_mtime if p.exists() else 0,
                       reverse=True)
    for old in snapshots[MAX_SNAPSHOTS:]:
        try:
            old.unlink()
        except OSError:
            pass
    return path

def load_scan(name: str) -> dict:
    path = SCANS / f"{_snapshot_name(name)}.json.gz"
    if not path.exists():
        raise SystemExit(f"no snapshot named '{name}'. try: diskmap snapshots")
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        return json.load(fh)

def list_scans() -> list[tuple[str, dict]]:
    if not SCANS.is_dir():
        return []
    out = []
    for p in sorted(SCANS.glob("*.json.gz")):
        try:
            with gzip.open(p, "rt", encoding="utf-8") as fh:
                head = json.load(fh)
            out.append((p.name[:-8], head))
        except Exception:
            continue
    return sorted(out, key=lambda x: x[1].get("created", 0), reverse=True)

# ───────────────────────────── analysis ─────────────────────────────

YEAR = 365 * 86400

AGE_BUCKETS = [
    ("< 1 week",   7 * 86400),
    ("< 1 month",  30 * 86400),
    ("< 3 months", 90 * 86400),
    ("< 6 months", 180 * 86400),
    ("< 1 year",   YEAR),
    ("< 2 years",  2 * YEAR),
    ("2+ years",   float("inf")),
]

def age_map(big_files) -> dict:
    """Bucket bytes by last-modified age, plus the Big & Untouched set."""
    now = time.time()
    buckets = {label: {"bytes": 0, "count": 0} for label, _ in AGE_BUCKETS}
    untouched = []
    for disk, mtime, path in big_files:
        age = now - mtime
        for label, limit in AGE_BUCKETS:
            if age < limit:
                buckets[label]["bytes"] += disk
                buckets[label]["count"] += 1
                break
        if age > YEAR and disk >= 100 * 1024 * 1024:
            untouched.append({"path": path, "size": disk, "mtime": mtime,
                              "age_days": int(age / 86400)})
    untouched.sort(key=lambda x: x["size"], reverse=True)
    return {"buckets": buckets, "untouched": untouched[:400]}

# Quick Wins — the categories that are almost always reclaimable.
QUICK_WINS = [
    ("Downloads",            [HOME / "Downloads"],                                   "review"),
    ("User caches",          [HOME / "Library" / "Caches"],                          "safe"),
    ("Logs",                 [HOME / "Library" / "Logs"],                            "safe"),
    ("Xcode DerivedData",    [HOME / "Library/Developer/Xcode/DerivedData"],          "safe"),
    ("Xcode archives",       [HOME / "Library/Developer/Xcode/Archives"],             "review"),
    ("iOS simulators",       [HOME / "Library/Developer/CoreSimulator/Devices"],      "review"),
    ("npm cache",            [HOME / ".npm/_cacache", HOME / ".npm/_npx"],            "safe"),
    ("pnpm / Yarn",          [HOME / "Library/Caches/pnpm", HOME / "Library/Caches/Yarn"], "safe"),
    ("pip cache",            [HOME / "Library/Caches/pip"],                           "safe"),
    ("Gradle caches",        [HOME / ".gradle/caches"],                               "safe"),
    ("CocoaPods cache",      [HOME / "Library/Caches/CocoaPods"],                     "safe"),
    ("Homebrew cache",       [HOME / "Library/Caches/Homebrew"],                      "safe"),
    ("Docker data",          [HOME / "Library/Containers/com.docker.docker"],         "review"),
    ("Go module cache",      [HOME / "go/pkg/mod"],                                   "safe"),
    ("Rust target dirs",     [HOME / ".cargo/registry"],                              "safe"),
]

BUILD_DIR_NAMES = {"node_modules", ".venv", "venv", "build", "target", ".next",
                   "dist", "__pycache__", ".gradle", "DerivedData", ".pytest_cache",
                   ".turbo", ".parcel-cache"}

def last_activity(p: Path | str) -> float:
    """Newest mtime below a path, without recursion."""
    return _dir_size_and_activity(p)[1]

def dir_size(p: Path | str, excluded: list[str] | tuple[str, ...] = ()) -> int:
    """Return allocated bytes without recursion, optionally skipping subtrees."""
    total = 0
    roots = tuple(os.path.realpath(os.fspath(x)) for x in excluded)
    start = os.path.realpath(os.fspath(p))
    if any(_under(start, x) for x in roots):
        return 0
    try:
        st = os.lstat(start)
        if os.path.islink(start):
            return 0
        if not os.path.isdir(start):
            return int(st.st_blocks) * 512
    except OSError:
        return 0
    stack = [start]
    while stack:
        cur = stack.pop()
        if any(_under(cur, x) for x in roots):
            continue
        try:
            with os.scandir(cur) as it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            total += e.stat(follow_symlinks=False).st_blocks * 512
                    except OSError:
                        pass
        except OSError:
            pass
    return total


def _dir_size_and_activity(p: Path | str) -> tuple[int, float]:
    """Measure allocated bytes and newest mtime in one walk."""
    start = os.path.realpath(os.fspath(p))
    try:
        st = os.lstat(start)
        if os.path.islink(start):
            return 0, 0.0
        if not os.path.isdir(start):
            return int(st.st_blocks) * 512, float(st.st_mtime)
    except OSError:
        return 0, 0.0
    total = 0
    newest = 0.0
    stack = [start]
    while stack:
        cur = stack.pop()
        try:
            newest = max(newest, os.stat(cur, follow_symlinks=False).st_mtime)
            with os.scandir(cur) as it:
                for entry in it:
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                        else:
                            child = entry.stat(follow_symlinks=False)
                            total += int(child.st_blocks) * 512
                            newest = max(newest, child.st_mtime)
                    except OSError:
                        continue
        except OSError:
            continue
    return total, newest


def _path_sizes(path: str) -> tuple[int, int] | None:
    """Return recursive (logical, allocated) file bytes without following links."""
    try:
        st = os.lstat(path)
        if os.path.islink(path):
            return None
        if not os.path.isdir(path):
            return int(st.st_size), int(st.st_blocks) * 512
    except (OSError, TypeError, ValueError):
        return None

    logical = allocated = 0
    stack = [path]
    while stack:
        cur = stack.pop()
        try:
            with os.scandir(cur) as it:
                for entry in it:
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                        else:
                            child = entry.stat(follow_symlinks=False)
                            logical += int(child.st_size)
                            allocated += int(child.st_blocks) * 512
                    except OSError:
                        continue
        except OSError:
            continue
    return logical, allocated

def quick_wins(root: str | None = None, tree: Node | dict | None = None) -> list[dict]:
    """Find reclaimable folders in scope and report a unique total.

    More specific categories are measured before parent categories, with
    already-owned subtrees excluded from later measurements.
    """
    scope = os.path.realpath(os.path.expanduser(root)) if root else str(HOME)
    if not os.path.isdir(scope):
        return []
    indexed: dict[str, int] | None = None
    if tree is not None:
        indexed = {}
        pending = [tree]
        while pending:
            node = pending.pop()
            if isinstance(node, Node):
                indexed[node.path] = node.disk
                pending.extend(node.children)
            elif isinstance(node, dict):
                path = node.get("p")
                if isinstance(path, str) and isinstance(node.get("s"), (int, float)):
                    indexed[path] = int(node["s"])
                pending.extend(c for c in node.get("c", []) if isinstance(c, dict))
    out = []
    covered: list[str] = []
    ordered = sorted(QUICK_WINS,
                     key=lambda x: max((len(str(p).parts) for p in x[1]), default=0),
                     reverse=True)
    for label, paths, tier in ordered:
        if indexed is None:
            existing = [p for p in paths if p.exists() and _under(p, scope)]
        else:
            existing = [p for p in paths
                        if str(p) in indexed and _under(p, scope)]
        if not existing:
            continue
        fresh = [p for p in existing
                 if not any(_under(p, c) or _under(c, p) for c in covered)]
        if not fresh:
            continue
        if indexed is None:
            size = sum(dir_size(p, excluded=covered) for p in fresh)
        else:
            size = sum(indexed.get(str(p), 0) for p in fresh)
        if size < 10 * 1024 * 1024:
            continue
        out.append({"label": label, "tier": tier, "size": size,
                    "paths": [str(p) for p in fresh]})
        covered.extend(str(p) for p in fresh)
    return sorted(out, key=lambda x: x["size"], reverse=True)

def find_build_dirs(roots: list[str], min_age_days: int = 0,
                    min_size: int = 50 * 1024 * 1024) -> list[dict]:
    """Locate build artifacts; prune so we never descend into one."""
    now = time.time()
    found = []
    for root in roots:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, _ in os.walk(root, topdown=True):
            hits = [d for d in dirnames if d in BUILD_DIR_NAMES]
            for h in hits:
                dirnames.remove(h)
                full = os.path.join(dirpath, h)
                sz, activity = _dir_size_and_activity(full)
                if not activity:
                    continue
                age = (now - activity) / 86400
                if age < min_age_days:
                    continue
                if sz >= min_size:
                    found.append({"path": full, "size": sz,
                                  "age_days": int(age), "kind": h,
                                  "last_activity": activity})
    return sorted(found, key=lambda x: x["size"], reverse=True)

# ───────────────────────── duplicate detection ─────────────────────────

def _digest(path: str, limit: int | None = None) -> str | None:
    h = hashlib.blake2b(digest_size=16)
    try:
        with open(path, "rb", buffering=0) as fh:
            if limit:
                h.update(fh.read(limit))
            else:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def _unique_inode_paths(paths: list[str]) -> list[str]:
    """Keep only singly-linked files; hard links do not reclaim their shared blocks."""
    out, seen = [], set()
    for p in paths:
        try:
            st = os.lstat(p)
            if os.path.islink(p) or not os.path.isfile(p) or st.st_nlink > 1:
                continue
            key = (st.st_dev, st.st_ino)
        except OSError:
            continue
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
    return out


def _allocated_file_bytes(path: str) -> int:
    try:
        return int(os.lstat(path).st_blocks) * 512
    except OSError:
        return 0

def find_duplicates(by_size: dict[int, list[str]], progress=True) -> list[dict]:
    """Byte-for-byte matching: size bucket → 64 KB head digest → full digest."""
    progress = progress and sys.stderr.isatty()
    candidates = {s: _unique_inode_paths(ps) for s, ps in by_size.items()}
    candidates = {s: ps for s, ps in candidates.items() if len(ps) > 1}
    if not candidates:
        return []
    groups: list[dict] = []
    total = len(candidates)
    with ThreadPoolExecutor(max_workers=8) as ex:
        for i, (size, paths) in enumerate(candidates.items()):
            if progress and i % 200 == 0:
                sys.stderr.write(f"\r  hashing… {i:,}/{total:,} size-groups   ")
                sys.stderr.flush()
            heads: dict[str, list[str]] = {}
            for p, hd in zip(paths, ex.map(lambda x: _digest(x, 65536), paths)):
                if hd:
                    heads.setdefault(hd, []).append(p)
            for hd, same_head in heads.items():
                if len(same_head) < 2:
                    continue
                if size <= 65536:
                    full = {hd: same_head}
                else:
                    full = {}
                    for p, fd in zip(same_head, ex.map(_digest, same_head)):
                        if fd:
                            full.setdefault(fd, []).append(p)
                for fd, dupes in full.items():
                    if len(dupes) > 1:
                        allocations = [_allocated_file_bytes(p) for p in dupes]
                        allocations = [a or size for a in allocations]
                        reclaimable = max(0, sum(allocations) - min(allocations))
                        groups.append({"size": size, "count": len(dupes),
                                       "allocated": sum(allocations),
                                       "wasted": reclaimable,
                                       "logical_wasted": size * (len(dupes) - 1),
                                       "digest": fd, "paths": sorted(dupes)})
    if progress:
        sys.stderr.write("\r" + " " * 60 + "\r")
    return sorted(groups, key=lambda g: g["wasted"], reverse=True)

# ─────────────────────── application footprint ───────────────────────

LEFTOVER_DIRS = [
    "Library/Application Support", "Library/Caches", "Library/Preferences",
    "Library/Logs", "Library/Containers", "Library/Group Containers",
    "Library/HTTPStorages", "Library/Saved Application State",
    "Library/WebKit", "Library/Cookies", "Library/Application Scripts",
]

_BUNDLE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,254}\Z")


def _safe_bundle_component(base: Path, component: str, bundle_id: bool = True) -> Path | None:
    """Resolve a bundle-derived child without allowing path traversal/symlinks."""
    if not isinstance(component, str) or not component or component in {".", ".."}:
        return None
    if bundle_id and not _BUNDLE_ID.fullmatch(component):
        return None
    if any(ord(c) < 32 or c in "/\\" for c in component):
        return None
    candidate = base / component
    if not _under(candidate, base) or os.path.realpath(candidate) == os.path.realpath(base):
        return None
    return candidate

def _bundle_id(app: Path) -> str | None:
    try:
        with open(app / "Contents" / "Info.plist", "rb") as fh:
            value = plistlib.load(fh).get("CFBundleIdentifier")
            return value if isinstance(value, str) and _BUNDLE_ID.fullmatch(value) else None
    except Exception:
        return None

def _last_used(p: Path) -> float | None:
    try:
        out = subprocess.run(["mdls", "-name", "kMDItemLastUsedDate", "-raw", str(p)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        if out and out != "(null)":
            return time.mktime(time.strptime(out[:19], "%Y-%m-%d %H:%M:%S"))
    except Exception:
        pass
    return None

def app_footprints(root: str | None = None, include_leftovers=True) -> list[dict]:
    """Every app with its true footprint: bundle plus scattered Library data."""
    scope = os.path.realpath(os.path.expanduser(root)) if root else None
    # Application footprints are meaningful for a home scan or an Applications
    # scan.  A random project directory or an external volume must not suddenly
    # display the user's unrelated installed applications.
    if scope and scope not in (str(HOME), "/Applications", str(HOME / "Applications")):
        return []
    apps = []
    roots = [Path("/Applications"), HOME / "Applications"]
    if scope == "/Applications":
        roots = [Path("/Applications")]
    elif scope == str(HOME / "Applications"):
        roots = [HOME / "Applications"]
    seen_ids: set[str] = set()
    for root in roots:
        if not root.is_dir():
            continue
        for app in sorted(root.glob("*.app")):
            bid = _bundle_id(app)
            name = app.stem
            identity = (bid or str(app)).lower()
            if identity in seen_ids:
                continue
            seen_ids.add(identity)
            bundle = dir_size(app)
            extras = []
            if bid:
                for rel in LEFTOVER_DIRS:
                    base = HOME / rel
                    for cand in (base / bid, base / name):
                        safe = _safe_bundle_component(base, cand.name, bundle_id=False)
                        if safe is not None and cand.exists() and _under(cand, base):
                            extras.append({"path": str(cand), "size": dir_size(cand)})
                    pref = _safe_bundle_component(base, f"{bid}.plist")
                    if pref is not None and pref.exists() and _under(pref, base):
                        extras.append({"path": str(pref),
                                       "size": pref.stat().st_blocks * 512})
            electron = (app / "Contents/Frameworks/Electron Framework.framework").is_dir()
            unique_extras = {e["path"]: e for e in extras}
            extras = list(unique_extras.values())
            apps.append({
                "name": name, "path": str(app), "bundle_id": bid,
                "bundle_size": bundle,
                "leftover_size": sum(e["size"] for e in extras),
                "total": bundle + sum(e["size"] for e in extras),
                "leftovers": extras, "electron": electron,
                "last_used": _last_used(app),
            })
    return sorted(apps, key=lambda a: a["total"], reverse=True)

def orphan_data(root: str | None = None) -> list[dict]:
    """Library data whose owning app is gone."""
    scope = os.path.realpath(os.path.expanduser(root)) if root else None
    if scope and scope != str(HOME):
        return []
    installed = set()
    for root in (Path("/Applications"), HOME / "Applications"):
        if root.is_dir():
            for app in root.glob("*.app"):
                installed.add(app.stem.lower())
                if (b := _bundle_id(app)):
                    installed.add(b.lower())
    out = []
    for rel in ("Library/Application Support", "Library/Containers",
                "Library/Group Containers", "Library/Caches"):
        base = HOME / rel
        if not base.is_dir():
            continue
        for child in base.iterdir():
            if not child.is_dir():
                continue
            nm = child.name.lower()
            if nm.startswith(("com.apple", "apple", "group.com.apple", "org.mozilla")):
                continue
            stem = nm.split(".")[-1]
            if nm in installed or stem in installed:
                continue
            if any(nm in i or i in nm for i in installed if len(i) > 4):
                continue
            sz = dir_size(child)
            if sz >= 100 * 1024 * 1024:
                out.append({"path": str(child), "name": child.name, "size": sz})
    return sorted(out, key=lambda x: x["size"], reverse=True)

# ─────────────────────── staged cleanup queue ───────────────────────
# Nothing is ever deleted during a scan. Items land here, you review, then purge.

def _queue_load_unlocked() -> list[dict]:
    if not QUEUE.exists():
        return []
    try:
        data = json.loads(QUEUE.read_text(encoding="utf-8"))
        if not isinstance(data, list):
            return []
        # Ignore malformed entries rather than allowing a corrupt queue to
        # break unstage/purge or turn an arbitrary JSON value into a path.
        return [item for item in data
                if isinstance(item, dict) and isinstance(item.get("path"), str)]
    except Exception:
        # Preserve a corrupt queue for recovery instead of silently treating it
        # as staged work. A future explicit repair command can inspect the file.
        return []


def queue_load() -> list[dict]:
    with _QUEUE_LOCK:
        with _queue_process_lock():
            return _queue_load_unlocked()


def _queue_save_unlocked(items: list[dict]) -> None:
    payload = json.dumps(items, indent=2, ensure_ascii=False).encode("utf-8")
    fd, temp = tempfile.mkstemp(prefix="queue.", suffix=".tmp", dir=STATE)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temp, QUEUE)
    finally:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass


def queue_save(items: list[dict]) -> None:
    with _QUEUE_LOCK:
        with _queue_process_lock():
            _queue_save_unlocked(items)


def queue_remove(paths: list[str] | None = None) -> int:
    """Atomically remove selected queue entries, or all entries when paths is None."""
    with _QUEUE_LOCK:
        with _queue_process_lock():
            items = _queue_load_unlocked()
            if paths is None:
                removed = len(items)
                _queue_save_unlocked([])
                return removed
            drop = set(paths)
            keep = [i for i in items if i.get("path") not in drop]
            _queue_save_unlocked(keep)
            return len(items) - len(keep)


def _identity(path: str) -> tuple[int, int, bool, int, int, int, int] | None:
    """Return device/inode/type, logical/allocated size, mtime and link count."""
    try:
        st = os.lstat(path)
        if os.path.islink(path):
            return None
        return (st.st_dev, st.st_ino, os.path.isdir(path),
                int(st.st_size), int(st.st_blocks) * 512,
                int(st.st_mtime_ns), int(st.st_nlink))
    except (OSError, TypeError, ValueError):
        return None

def _nested(a: str, b: str) -> bool:
    return a == b or a.startswith(b + os.sep) or b.startswith(a + os.sep)

def queue_add(paths, reason: str = "") -> tuple[int, list[tuple[str, str]]]:
    with _QUEUE_LOCK:
        with _queue_process_lock():
            items = _queue_load_unlocked()
            added, refused = 0, []
            queued = [i.get("path", "") for i in items]
            for p in paths:
                raw = os.path.expanduser(str(p))
                if os.path.islink(raw):
                    refused.append((raw, "symbolic links are not staged"))
                    continue
                rp = os.path.realpath(raw)
                if rp in queued:
                    continue
                if len(items) >= MAX_QUEUE_ITEMS:
                    refused.append((rp, f"queue limit reached ({MAX_QUEUE_ITEMS:,} items)"))
                    continue
                ident = _identity(rp)
                if ident is None:
                    refused.append((rp, "missing or symbolic link"))
                    continue
                if not ident[2] and ident[6] != 1:
                    refused.append((rp, "hard-linked files are not staged"))
                    continue
                ok, why = is_safe_to_delete(rp)
                if not ok:
                    refused.append((rp, why))
                    continue
                if any(_nested(rp, q) for q in queued if q):
                    refused.append((rp, "overlaps another queued path"))
                    continue
                sizes = _path_sizes(rp)
                if sizes is None:
                    refused.append((rp, "could not measure path"))
                    continue
                logical, allocated = sizes
                dev, ino, is_dir, _, _, mtime_ns, nlink = ident
                items.append({"path": rp, "size": allocated,
                              "logical": logical, "allocated": allocated,
                              "device": dev, "inode": ino, "is_dir": is_dir,
                              "mtime_ns": mtime_ns, "nlink": nlink,
                              "reason": str(reason)[:240], "staged": time.time()})
                queued.append(rp)
                added += 1
            _queue_save_unlocked(items)
            return added, refused


def _log_cleanup(bytes_moved: int, path: str) -> None:
    """Append a bounded audit line; logs are useful, but must not grow forever."""
    _ensure_state()
    try:
        if LOGF.exists() and LOGF.stat().st_size > 256 * 1024:
            tail = LOGF.read_bytes()[-128 * 1024:]
            fd, temp = tempfile.mkstemp(prefix="cleanup.", suffix=".tmp", dir=STATE)
            with os.fdopen(fd, "wb") as fh:
                fh.write(tail)
                fh.flush(); os.fsync(fh.fileno())
            os.replace(temp, LOGF)
    except OSError:
        pass
    try:
        with open(LOGF, "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%F %T')}  trashed  {bytes_moved}  {path}\n")
    except OSError:
        pass

def queue_purge(apply: bool = False, use_trash: bool = True,
                return_removed: bool = False):
    """Move staged items to Trash; permanent deletion is intentionally unsupported."""
    if not use_trash:
        raise ValueError("permanent deletion is disabled; use the Trash")
    with _QUEUE_LOCK:
        with _queue_process_lock():
            items = _queue_load_unlocked()
            moved, done, failed, removed_items = 0, 0, [], []
            for it in items:
                p = it.get("path", "")
                ok, why = is_safe_to_delete(p)
                if not ok:
                    failed.append((p, why))
                    continue
                ident = _identity(p)
                if ident is None:
                    if os.path.lexists(p):
                        failed.append((p, "path is now a symbolic link; restage it"))
                    # It may already have been removed or moved by the user.
                    elif apply:
                        removed_items.append(dict(it))
                    continue
                required = ("device", "inode", "is_dir", "mtime_ns", "nlink",
                            "logical", "allocated")
                if any(k not in it for k in required):
                    failed.append((p, "missing staging identity; restage it"))
                    continue
                if (type(it.get("is_dir")) is not bool
                        or any(type(it.get(k)) is not int
                               for k in ("device", "inode", "mtime_ns", "nlink",
                                         "logical", "allocated"))):
                    failed.append((p, "invalid staging identity; restage it"))
                    continue
                if (ident[0] != int(it["device"]) or ident[1] != int(it["inode"])
                        or ident[2] != bool(it["is_dir"])
                        or ident[5] != int(it["mtime_ns"])
                        or ident[6] != int(it["nlink"])
                        or (not ident[2] and ident[6] != 1)):
                    failed.append((p, "changed since it was staged"))
                    continue
                # A file can change contents in place without changing its inode;
                # size, allocation and mtime close that replacement hole. A directory's
                # own mtime does not change when a child's contents change, so remeasure
                # its recursive totals before moving it.
                if ident[2]:
                    current_sizes = _path_sizes(p)
                    if current_sizes is None or current_sizes != (int(it["logical"]), int(it["allocated"])):
                        failed.append((p, "changed since it was staged"))
                        continue
                elif (ident[3] != int(it["logical"])
                      or ident[4] != int(it["allocated"])):
                    failed.append((p, "changed since it was staged"))
                    continue
                allocated = int(it["allocated"])
                if not apply:
                    moved += allocated
                    done += 1
                    continue
                try:
                    # Pass the path as osascript argv. Interpolating it into an
                    # AppleScript string allows a filename containing quotes to
                    # change the script being executed.
                    script = ('on run argv\n'
                              '  tell application "Finder" to delete POSIX file (item 1 of argv)\n'
                              'end run')
                    subprocess.run(["osascript", "-e", script, p],
                                   capture_output=True, timeout=120, check=True)
                    moved += allocated
                    done += 1
                    removed_items.append(dict(it))
                    _log_cleanup(allocated, p)
                except Exception as e:
                    failed.append((p, str(e)[:120]))
            if apply:
                failed_paths = {f[0] for f in failed}
                survivors = [i for i in items if i.get("path") in failed_paths
                             and os.path.lexists(i.get("path", ""))]
                _queue_save_unlocked(survivors)
            result = (done, moved, failed)
            return (*result, removed_items) if return_removed else result

# ───────────────────────── snapshot comparison ─────────────────────────

def _flatten(node: dict, depth: int, max_depth: int, acc: dict) -> None:
    acc[node["p"]] = node["s"]
    if depth < max_depth:
        for c in node.get("c", []):
            if not c.get("other"):
                _flatten(c, depth + 1, max_depth, acc)

def diff_scans(old: dict, new: dict, max_depth: int = 5) -> dict:
    a, b = {}, {}
    _flatten(old["tree"], 0, max_depth, a)
    _flatten(new["tree"], 0, max_depth, b)
    grew, shrank, added, removed = [], [], [], []
    for p, sz in b.items():
        if p in a:
            d = sz - a[p]
            if d > 50 * 1024 * 1024:
                grew.append({"path": p, "delta": d, "from": a[p], "to": sz})
            elif d < -50 * 1024 * 1024:
                shrank.append({"path": p, "delta": d, "from": a[p], "to": sz})
        elif sz > 50 * 1024 * 1024:
            added.append({"path": p, "delta": sz, "from": 0, "to": sz})
    for p, sz in a.items():
        if p not in b and sz > 50 * 1024 * 1024:
            removed.append({"path": p, "delta": -sz, "from": sz, "to": 0})
    grew.sort(key=lambda x: -x["delta"])
    shrank.sort(key=lambda x: x["delta"])
    added.sort(key=lambda x: -x["delta"])
    removed.sort(key=lambda x: x["delta"])
    return {
        "old_created": old["created"], "new_created": new["created"],
        "old_bytes": old["totals"]["bytes"], "new_bytes": new["totals"]["bytes"],
        "grew": grew[:60], "shrank": shrank[:60],
        "added": added[:60], "removed": removed[:60],
    }

# ───────────────────────────── inspector ─────────────────────────────

def inspect(path: str) -> dict:
    p = os.path.realpath(os.path.expanduser(path))
    st = os.stat(p)
    info = {"path": p, "is_dir": os.path.isdir(p),
            "created": st.st_birthtime if hasattr(st, "st_birthtime") else st.st_ctime,
            "modified": st.st_mtime}
    if info["is_dir"]:
        logical = files = dirs = disk = 0
        sizes: dict[str, int] = {p: 0}
        kids: dict[str, dict] = {}
        stack = [p]
        while stack:
            cur = stack.pop()
            try:
                with os.scandir(cur) as it:
                    for e in it:
                        try:
                            if e.is_symlink():
                                continue
                            if e.is_dir(follow_symlinks=False):
                                sizes[e.path] = 0
                                dirs += 1
                                if cur == p:
                                    kids[e.path] = {"name": e.name, "size": 0, "is_dir": True}
                                stack.append(e.path)
                                continue
                            s = e.stat(follow_symlinks=False)
                            logical += s.st_size
                            allocated = s.st_blocks * 512
                            disk += allocated
                            files += 1
                            sizes[cur] = sizes.get(cur, 0) + allocated
                            if cur == p:
                                kids[e.path] = {"name": e.name, "size": allocated, "is_dir": False}
                        except OSError:
                            pass
            except OSError:
                pass
        # Fold each measured directory into its parent once, rather than walking
        # every direct child again to calculate the largest-inside list.
        for child in sorted((x for x in sizes if x != p),
                            key=lambda x: x.count(os.sep), reverse=True):
            parent = os.path.dirname(child)
            sizes[parent] = sizes.get(parent, 0) + sizes[child]
            if child in kids:
                kids[child]["size"] = sizes[child]
        kids = list(kids.values())
        kids.sort(key=lambda x: -x["size"])
        info.update({"logical": logical, "disk": disk, "files": files,
                     "dirs": dirs, "largest": kids[:20]})
    else:
        info.update({"logical": st.st_size, "disk": st.st_blocks * 512,
                     "files": 1, "dirs": 0, "largest": []})
    # Logical minus allocated. Sparse files (disk images, qcow2, VM volumes) account
    # for most of this on a dev machine; APFS compression is the remainder.
    saved = info["logical"] - info["disk"]
    info["compression_saved"] = saved if saved > 0 else 0
    info["compression_pct"] = (saved / info["logical"] * 100) if info["logical"] else 0
    parent = os.path.dirname(p)
    try:
        psz = dir_size(parent)
        info["parent"] = parent
        info["share_of_parent"] = (info["disk"] / psz * 100) if psz else 0
    except OSError:
        info["parent"], info["share_of_parent"] = parent, 0
    return info
