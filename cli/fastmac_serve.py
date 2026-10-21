"""fastmac server — backs the UI so it can delete and read live memory.

Security posture, because this process can remove files:
  • binds 127.0.0.1 only, never a routable interface
  • every /api/ call must carry a random per-session token
  • Host header is pinned to loopback (blocks DNS rebinding)
  • every path is re-validated server-side; the client is never trusted
  • deletion still defaults to the Trash, and still needs an explicit apply
"""
from __future__ import annotations
import json, os, secrets, subprocess, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import fastmac_core as C
import fastmac_mem as M
import fastmac_report as R

TOKEN = ""
PAGE = b""
SCAN_NAME = ""
SCAN_ROOT = ""


class Handler(BaseHTTPRequestHandler):
    server_version = "fastmac"

    def log_message(self, *a):
        pass  # stay quiet; the CLI prints what matters

    # ── helpers ────────────────────────────────────────────────
    def _send(self, code, body, ctype="application/json", cookie=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        if ctype.startswith("text/html"):
            self.send_header("Content-Security-Policy",
                             "default-src 'none'; style-src 'unsafe-inline'; "
                             "script-src 'unsafe-inline'; connect-src 'self';")
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _loopback_host(self) -> bool:
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost", "[::1]", "::1")

    def _authed(self) -> bool:
        if not self._loopback_host():
            return False
        tok = self.headers.get("X-Fastmac-Token", "")
        if secrets.compare_digest(tok, TOKEN):
            return True
        for part in (self.headers.get("Cookie") or "").split(";"):
            name, sep, value = part.strip().partition("=")
            if sep and name == "fastmac-token" and secrets.compare_digest(value, TOKEN):
                return True
        return False

    def _in_scan_scope(self, path: str) -> bool:
        if not isinstance(path, str) or not path:
            return False
        expanded = os.path.expanduser(path)
        if not os.path.isabs(expanded) or not SCAN_ROOT:
            return False
        rp = os.path.realpath(expanded)
        if C._under(rp, SCAN_ROOT):
            return True
        # A home snapshot may include installed apps as an explicit application
        # footprint; keep those report paths available without opening the API
        # to arbitrary paths elsewhere on the machine.
        return (SCAN_ROOT == str(C.HOME)
                and (C._under(rp, "/Applications")
                     or C._under(rp, C.HOME / "Applications")))

    def _body(self) -> dict | None:
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if n <= 0 or n > 4_000_000:
            return {} if n == 0 else None
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
            return body if isinstance(body, dict) else None
        except Exception:
            return None

    # ── routes ─────────────────────────────────────────────────
    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            query_token = (parse_qs(u.query).get("t") or [""])[0]
            if (not self._loopback_host()
                    or (not self._authed() and not secrets.compare_digest(query_token, TOKEN))):
                return self._send(403, {"error": "bad or missing token"})
            cookie = ("fastmac-token=" + TOKEN
                      + "; Path=/; HttpOnly; SameSite=Strict") if query_token else None
            return self._send(200, PAGE, "text/html; charset=utf-8", cookie=cookie)
        if not u.path.startswith("/api/"):
            return self._send(404, {"error": "not found"})
        if not self._authed():
            return self._send(403, {"error": "bad or missing token"})

        if u.path == "/api/ping":
            return self._send(200, {"ok": True, "scan": SCAN_NAME})
        if u.path == "/api/mem":
            return self._send(200, {"mem": M.sample(), "procs": M.processes(14),
                                    "disk": M.disk()})
        if u.path == "/api/state":
            return self._send(200, {"queue": C.queue_load()})
        if u.path == "/api/inspect":
            p = (parse_qs(u.query).get("path") or [""])[0]
            if not self._in_scan_scope(p):
                return self._send(400, {"error": "path is outside the scanned root"})
            try:
                return self._send(200, C.inspect(p))
            except OSError as e:
                return self._send(400, {"error": str(e)})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        if not self._authed():
            return self._send(403, {"error": "bad or missing token"})
        b = self._body()
        if b is None:
            return self._send(400, {"error": "request body must be a JSON object"})

        if u.path == "/api/stage":
            raw_paths = b.get("paths")
            if not isinstance(raw_paths, list):
                return self._send(400, {"error": "paths must be an array"})
            paths = [p for p in raw_paths if isinstance(p, str)][:5000]
            if len(paths) != len(raw_paths[:5000]):
                return self._send(400, {"error": "paths must contain only strings"})
            reason = b.get("reason", "staged from the UI")
            if not isinstance(reason, str):
                return self._send(400, {"error": "reason must be a string"})
            scoped = [p for p in paths if self._in_scan_scope(p)]
            refused = [(p, "outside the scanned root") for p in paths if p not in scoped]
            added, more_refused = C.queue_add(scoped, reason[:240])
            refused.extend(more_refused)
            return self._send(200, {"added": added,
                                    "refused": [{"path": p, "why": w} for p, w in refused],
                                    "queue": C.queue_load()})

        if u.path == "/api/unstage":
            all_items = b.get("all", False)
            paths = b.get("paths", [])
            if not isinstance(all_items, bool) or not isinstance(paths, list) \
                    or not all(isinstance(p, str) for p in paths):
                return self._send(400, {"error": "all must be boolean and paths an array of strings"})
            items = C.queue_load()
            if all_items:
                C.queue_remove()
            else:
                C.queue_remove(paths)
            return self._send(200, {"queue": C.queue_load()})

        if u.path == "/api/purge":
            apply = b.get("apply", False)
            hard = b.get("hard", False)
            if not isinstance(apply, bool) or not isinstance(hard, bool):
                return self._send(400, {"error": "apply and hard must be boolean"})
            if hard:
                return self._send(400, {"error": "permanent deletion is disabled; use the Trash"})
            # Re-check every staged path here. The client's opinion does not count.
            before = C.queue_load()
            blocked = [{"path": i.get("path", ""), "why": w}
                       for i in before
                       for ok, w in [C.is_safe_to_delete(i.get("path", ""))] if not ok]
            done, freed, failed, removed_items = C.queue_purge(
                apply=apply, use_trash=True, return_removed=True)
            after = C.queue_load()
            removed = []
            if apply:
                for item in removed_items:
                    path = item.get("path", "")
                    if isinstance(path, str):
                        removed.append({"path": path,
                                        "size": item.get("allocated", item.get("size", 0)),
                                        "logical": item.get("logical", item.get("size", 0)),
                                        "is_dir": item.get("is_dir", False)})
            return self._send(200, {
                "applied": apply, "hard": False, "items": done, "moved": freed,
                "blocked": blocked,
                "failed": [{"path": p, "why": w} for p, w in failed],
                "removed": removed, "queue": after, "disk": M.disk()})

        if u.path == "/api/reveal":
            p = b.get("path", "")
            if not self._in_scan_scope(p):
                return self._send(400, {"error": "path is outside the scanned root"})
            ok, why = (os.path.exists(p), "does not exist")
            if ok:
                subprocess.run(["open", "-R", p], capture_output=True)
                return self._send(200, {"ok": True})
            return self._send(400, {"error": why})

        if u.path == "/api/shutdown":
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return self._send(200, {"ok": True})

        return self._send(404, {"error": "not found"})


def serve(scan: dict, extras: dict, name: str, port: int = 0, open_browser=True):
    global PAGE, SCAN_NAME, TOKEN, SCAN_ROOT
    TOKEN = secrets.token_urlsafe(24)
    SCAN_NAME = name
    SCAN_ROOT = os.path.realpath(os.path.expanduser(str(scan.get("root", ""))))
    PAGE = R.build(scan, extras, live=True).encode()

    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    real_port = httpd.server_address[1]
    url = f"http://127.0.0.1:{real_port}/?t={TOKEN}#t={TOKEN}"

    print(f"\n  \033[1mfastmac live\033[0m  {url}")
    print(f"  \033[2mDeleting and the RAM monitor are enabled in this window.\033[0m")
    print(f"  \033[2mLoopback only, token-protected. Ctrl-C to stop.\033[0m\n", flush=True)
    if open_browser:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("  stopped")
    finally:
        httpd.server_close()
