import gzip
import http.client
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path

import fastmac_core as C
import fastmac_report as R
import fastmac_serve as S


class FastMacTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(dir=os.getcwd())
        self.state = tempfile.TemporaryDirectory(dir=os.getcwd())
        self.root = Path(self.work.name) / "fixture"
        (self.root / "nested").mkdir(parents=True)
        (self.root / "a.bin").write_bytes(b"a" * (2 * 1024 * 1024))
        (self.root / "nested" / "b.bin").write_bytes(b"b" * 1024)

        self.old = (C.STATE, C.SCANS, C.QUEUE, C.LOGF)
        C.STATE = Path(self.state.name)
        C.SCANS = C.STATE / "scans"
        C.QUEUE = C.STATE / "queue.json"
        C.LOGF = C.STATE / "cleanup.log"

    def tearDown(self):
        C.STATE, C.SCANS, C.QUEUE, C.LOGF = self.old
        self.state.cleanup()
        self.work.cleanup()

    def test_scan_and_prune_keep_recursive_sizes(self):
        scanner = C.Scanner(str(self.root), workers=99, progress=False)
        tree = scanner.run()
        self.assertEqual(scanner.workers, 8)
        self.assertEqual(tree.files, 2)
        self.assertGreaterEqual(tree.disk, 2 * 1024 * 1024)
        view = C.prune(tree, min_bytes=1024 * 1024)
        self.assertEqual(view["k"], "dir")
        self.assertTrue(all(child.get("k") in {"dir", "other"}
                            for child in view.get("c", [])))

    def test_snapshot_write_is_atomic_and_loadable(self):
        scanner = C.Scanner(str(self.root), workers=1, progress=False)
        tree = scanner.run()
        saved = C.save_scan("fixture", tree, scanner, extras={"quick": []})
        self.assertTrue(saved.exists())
        with gzip.open(saved, "rt", encoding="utf-8") as fh:
            self.assertEqual(json.load(fh)["version"], 2)
        loaded = C.load_scan("fixture")
        self.assertEqual(loaded["root"], str(self.root.resolve()))
        self.assertEqual(C.list_scans()[0][0], "fixture")

    def test_queue_rejects_nested_and_symlink_paths_and_never_hard_deletes(self):
        target = self.root / "a.bin"
        added, refused = C.queue_add([str(target)], "test")
        self.assertEqual((added, refused), (1, []))
        added, refused = C.queue_add([str(self.root), str(target)], "test")
        self.assertEqual(added, 0)
        self.assertTrue(any("overlaps" in why for _, why in refused))

        link = self.root / "link"
        link.symlink_to(target)
        added, refused = C.queue_add([str(link)], "test")
        self.assertEqual(added, 0)
        self.assertTrue(any("symbolic" in why for _, why in refused))

        done, freed, failed = C.queue_purge(apply=False)
        self.assertEqual(done, 1)
        self.assertGreaterEqual(freed, target.stat().st_size)
        self.assertEqual(failed, [])
        with self.assertRaises(ValueError):
            C.queue_purge(apply=False, use_trash=False)
        self.assertTrue(target.exists())

    def test_queue_rejects_changed_file_and_hardlink_aliases(self):
        target = self.root / "nested" / "b.bin"
        added, refused = C.queue_add([str(target)], "test")
        self.assertEqual((added, refused), (1, []))
        target.write_bytes(b"changed")
        done, _, failed = C.queue_purge(apply=False)
        self.assertEqual(done, 0)
        self.assertTrue(any("changed" in why for _, why in failed))
        C.queue_remove()

        alias = self.root / "nested" / "alias.bin"
        alias.hardlink_to(self.root / "a.bin")
        added, refused = C.queue_add([str(alias)], "test")
        self.assertEqual(added, 0)
        self.assertTrue(any("hard-linked" in why for _, why in refused))
        self.assertEqual(C.find_duplicates({self.root.joinpath("a.bin").stat().st_size:
                                             [str(self.root / "a.bin"), str(alias)]}), [])

    def test_queue_rejects_changed_directory_totals(self):
        folder = self.root / "nested"
        added, refused = C.queue_add([str(folder)], "test")
        self.assertEqual((added, refused), (1, []))
        (folder / "b.bin").write_bytes(b"b" * 4096)
        done, _, failed = C.queue_purge(apply=False)
        self.assertEqual(done, 0)
        self.assertTrue(any("changed" in why for _, why in failed))

    def test_state_root_is_protected(self):
        ok, why = C.is_safe_to_delete(str(C.STATE))
        self.assertFalse(ok)
        self.assertIn("protected", why)

    def test_live_api_is_strict_and_scoped(self):
        old_token, old_root, old_page = S.TOKEN, S.SCAN_ROOT, S.PAGE
        S.TOKEN, S.SCAN_ROOT, S.PAGE = "unit-token", str(self.root), b"ok"
        try:
            server = S.ThreadingHTTPServer(("127.0.0.1", 0), S.Handler)
        except PermissionError:
            self.skipTest("sandbox does not permit binding a local test socket")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            conn.request("GET", "/")
            response = conn.getresponse()
            self.assertEqual(response.status, 403); response.read()
            conn.request("GET", "/?t=unit-token")
            response = conn.getresponse()
            self.assertEqual(response.status, 200); response.read()

            headers = {"X-Fastmac-Token": "unit-token", "Content-Type": "application/json"}
            conn.request("POST", "/api/purge", '{"apply":"false"}', headers)
            response = conn.getresponse()
            self.assertEqual(response.status, 400); response.read()
            conn.request("POST", "/api/stage",
                         json.dumps({"paths": [str(self.root / "a.bin"), "/tmp/not-in-scan"]}),
                         headers)
            response = conn.getresponse()
            self.assertEqual(response.status, 200)
            staged = json.loads(response.read())
            self.assertEqual(staged["added"], 1)
            self.assertEqual(len(staged["refused"]), 1)
        finally:
            C.queue_remove()
            server.shutdown(); server.server_close(); thread.join(timeout=3)
            S.TOKEN, S.SCAN_ROOT, S.PAGE = old_token, old_root, old_page

    def test_report_escapes_paths_inside_data_script(self):
        hostile = "/tmp/</script><script>alert(1)</script>"
        scan = {
            "root": hostile,
            "created": 0,
            "elapsed": 0,
            "totals": {"bytes": 1, "files": 0, "dirs": 0, "errors": 0},
            "tree": {"n": "root", "p": hostile, "k": "dir", "s": 1, "l": 1,
                     "f": 0, "d": 0, "m": 0},
        }
        page = R.build(scan, {})
        data_script = page.split("<script>const DATA=", 1)[1].split("</script>", 1)[0]
        self.assertNotIn("</script>", data_script)
        self.assertIn("\\u003c/script\\u003e", data_script)
        self.assertIn("Top Sizes", page)


if __name__ == "__main__":
    unittest.main()
