"""Tests for the Entrepreneur Edition setup window (System/bin/onboard/server.py).

    python tests/test_onboard_entrepreneur.py                 # against the overlay source
    ONBOARD_SERVER=<vault>/System/bin/onboard/server.py python tests/test_onboard_entrepreneur.py

Every test builds a throwaway vault from the edition's own starter files and
points the window at a throwaway obsidian.json. Nothing reads or writes the
real Obsidian config, and the Claude app is never launched. Behaviour is
checked through the state the page polls, not through the HTML.
"""

import csv
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
INSTALLER = HERE.parent
PAYLOAD_VAULT = INSTALLER / "editions" / "entrepreneur" / "payload_overlay" / "payload" / "vault"
SERVER = Path(os.environ.get("ONBOARD_SERVER") or PAYLOAD_VAULT / "System" / "bin" / "onboard" / "server.py").resolve()
if os.environ.get("ONBOARD_SERVER"):
    PAYLOAD_VAULT = SERVER.parents[3]   # an installed vault: starter files and organize.py come from it too
ORGANIZE = PAYLOAD_VAULT / "System" / "bin" / "organize.py"
FIXTURE = HERE / "fixtures" / "organize"
SENTINEL = "ZEBRAFISH_SENTINEL_7731"   # vault content that must never leave in a report

os.environ["HEIMDALL_ONBOARD_NO_LAUNCH"] = "1"

spec = importlib.util.spec_from_file_location("onboard_server_entre", str(SERVER))
srv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(srv)


def tree(root, skip=None):
    out = {}
    for p in sorted(Path(root).rglob("*")):
        if p.is_file() and not (skip and skip in p.parts):
            out[str(p.relative_to(root))] = (p.stat().st_size, p.stat().st_mtime_ns, p.read_bytes())
    return out


class VaultCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="onboard_entre_"))
        self.vault = self.tmp / "Second_Brain"
        (self.vault / "System" / "plans").mkdir(parents=True)
        (self.vault / "Work").mkdir()
        for rel in ("START_HERE.md", "Ledger.md", "Work/README.md"):
            shutil.copy(str(PAYLOAD_VAULT / rel), str(self.vault / rel))
        self.obs_cfg = self.tmp / "obsidian.json"
        os.environ["HEIMDALL_OBSIDIAN_CONFIG"] = str(self.obs_cfg)

    def tearDown(self):
        shutil.rmtree(str(self.tmp), ignore_errors=True)

    def record(self):
        (self.vault / "System" / "heimdall_install.json").write_text(json.dumps({
            "edition": "entrepreneur", "tag": "v0.1.0-beta", "installed_at": "2026-10-28T15:00:00Z"}), encoding="utf-8")

    def open_in_obsidian(self):
        self.obs_cfg.write_text(json.dumps({"vaults": {"v1": {"path": str(self.vault), "ts": 1}}}), encoding="utf-8")
        (self.vault / ".obsidian").mkdir(exist_ok=True)
        (self.vault / ".obsidian" / "workspace.json").write_text("{}", encoding="utf-8")

    def finish_setup(self):
        (self.vault / "START_HERE.md").write_text("# Start here\n\n## Who I am\nRuns " + SENTINEL + ".\n", encoding="utf-8")

    def area(self, name):
        d = self.vault / "Work" / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "README.md").write_text("# " + name + "\n", encoding="utf-8")

    def state(self, session=None):
        st = srv.compute_state(session or srv.Session(self.vault))
        return st, {s["id"]: s for s in st["steps"]}


class StateMachine(VaultCase):
    def test_steps_in_order(self):
        st, by = self.state()
        self.assertEqual([s["id"] for s in st["steps"]], ["installed", "obsidian", "setup", "areas", "organize", "recap"])
        self.assertEqual(by["installed"]["status"], "failed")
        self.assertIsNone(st["recap"])

        self.record()
        _, by = self.state()
        self.assertEqual(by["installed"]["status"], "done")
        self.assertEqual(by["obsidian"]["status"], "waiting")
        self.assertTrue(by["obsidian"]["open_url"].startswith("obsidian://open?path="))

        self.open_in_obsidian()
        _, by = self.state()
        self.assertEqual(by["obsidian"]["status"], "done")
        self.assertEqual(by["setup"]["status"], "waiting")
        self.assertEqual(by["setup"]["action"], "open-claude")
        self.assertEqual(by["setup"]["command"], "/setup")
        self.assertEqual(by["areas"]["status"], "waiting")
        self.assertEqual(by["organize"]["action"], "", "no /organize prompt before the work areas exist")

        self.finish_setup()
        st, by = self.state()
        self.assertEqual(by["setup"]["status"], "done")
        self.assertEqual(by["areas"]["status"], "running")
        self.assertIsNotNone(st["recap"])
        self.assertFalse(st["recap"]["sorted"])

        self.area("Clients"); self.area("Sales")
        (self.vault / "Work" / "loose_folder_no_readme").mkdir()
        _, by = self.state()
        self.assertEqual(by["areas"]["status"], "done")
        self.assertEqual(by["areas"]["areas"], ["Clients", "Sales"])
        self.assertEqual(by["organize"]["status"], "waiting")
        self.assertEqual(by["organize"]["action"], "copy-command")
        self.assertEqual(by["organize"]["command"], "/organize Downloads")

    def test_organize_run_end_to_end(self):
        """A real organize.py scan and apply moves the window from waiting to running to done."""
        self.record(); self.open_in_obsidian(); self.finish_setup(); self.area("Clients")
        src = self.tmp / "Downloads"
        shutil.copytree(str(FIXTURE), str(src))
        originals = tree(src)
        tool = self.vault / "System" / "bin" / "organize.py"
        tool.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(str(ORGANIZE), str(tool))
        py = [sys.executable, "-X", "utf8", str(tool), "--vault", str(self.vault)]

        subprocess.run(py + ["scan", str(src)], check=True, capture_output=True, timeout=60)
        _, by = self.state()
        self.assertEqual(by["organize"]["status"], "running")
        self.assertEqual(by["organize"]["kept_out"], 4, "tax, bank, passport and the SSN file")

        plan = next((self.vault / "System" / "plans").glob("organize_*.csv"))
        with open(str(plan), newline="", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            header, rows = reader.fieldnames, list(reader)
        with open(str(plan), "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=header)
            w.writeheader()
            for r in rows:
                if not r.get("keep_out"):
                    r["destination"] = "Archive"
                w.writerow(r)
        subprocess.run(py + ["apply", str(plan), "--yes"], check=True, capture_output=True, timeout=60)
        st, by = self.state()
        self.assertEqual(by["organize"]["status"], "done")
        self.assertEqual(by["organize"]["counts"]["copied"], 5)
        self.assertEqual(by["recap"]["status"], "done")
        self.assertTrue(st["recap"]["sorted"])
        self.assertEqual(st["recap"]["kept_out"], 4)
        self.assertEqual(originals, tree(src), "originals byte-identical, same size and mtime, none moved")

    def test_inbox_runs_do_not_count(self):
        self.record(); self.finish_setup(); self.area("Clients")
        plans = self.vault / "System" / "plans"
        (plans / "inbox_20261028_120000.csv").write_text("source,keep_out\n", encoding="utf-8")
        (plans / "inbox_20261028_120000_result.csv").write_text("source,copied_to,status\n", encoding="utf-8")
        _, by = self.state()
        self.assertEqual(by["organize"]["status"], "waiting")


class ReadOnly(VaultCase):
    def test_window_writes_only_its_run_folder(self):
        self.record(); self.open_in_obsidian(); self.finish_setup(); self.area("Clients")
        before = tree(self.vault, skip=".onboard")
        s = srv.Session(self.vault)
        for _ in range(3):
            srv.compute_state(s)
        srv.build_report(s)
        srv.open_claude(s)
        self.assertEqual(before, tree(self.vault, skip=".onboard"))


class Report(VaultCase):
    def test_report_has_no_vault_content(self):
        self.record(); self.open_in_obsidian(); self.finish_setup(); self.area("Acme_" + SENTINEL)
        report = srv.build_report(srv.Session(self.vault))
        for needle in (SENTINEL, str(Path.home()), os.environ.get("USERNAME") or os.environ.get("USER") or "\x00"):
            self.assertNotIn(needle, report)
        self.assertIn("Edition: entrepreneur", report)
        self.assertIn("[done] Installed", report)
        self.assertIn("[done] Work areas: 1 work area set up", report)


class Network(VaultCase):
    def test_no_sockets_while_computing_state(self):
        self.record(); self.open_in_obsidian(); self.finish_setup()
        seen = []
        real_connect = socket.socket.connect

        def spy(sock, addr):
            seen.append(addr)
            return real_connect(sock, addr)

        socket.socket.connect = spy
        try:
            s = srv.Session(self.vault)
            srv.compute_state(s)
            srv.build_report(s)
        finally:
            socket.socket.connect = real_connect
        self.assertEqual(seen, [])

    def test_page_names_no_remote_host(self):
        static = SERVER.parent / "static"
        for f in static.rglob("*"):
            if f.suffix in (".html", ".js", ".css"):
                text = f.read_text(encoding="utf-8")
                self.assertIsNone(re.search(r"https?://|//fonts\.|@import", text), f.name)

    def test_page_names_no_connector(self):
        for f in (SERVER.parent / "static").rglob("*"):
            if f.suffix in (".html", ".js"):
                text = f.read_text(encoding="utf-8")
                self.assertNotIn("Local REST API", text, f.name)
                self.assertNotIn("api key", text.lower(), f.name)


class Http(VaultCase):
    def setUp(self):
        super().setUp()
        self.record()
        self.proc = subprocess.Popen(
            [sys.executable, "-X", "utf8", str(SERVER), "--vault", str(self.vault), "--no-browser"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ))
        line = self.proc.stdout.readline()
        m = re.search(r"http://127\.0\.0\.1:(\d+)/\?t=(\S+)", line)
        if not m:
            self.fail("no address printed: " + line + self.proc.stderr.read())
        self.port, self.token = int(m.group(1)), m.group(2)

    def tearDown(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=10)
        self.proc.stdout.close(); self.proc.stderr.close()
        super().tearDown()

    def call(self, method, path, token=True, host=None):
        headers = {}
        if token:
            headers["X-Onboard-Token"] = self.token if token is True else token
        if host:
            headers["Host"] = host
        data = b"" if method == "POST" else None
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), data=data, headers=headers, method=method)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req, timeout=10) as r:
                return r.status, r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8")

    def test_token_and_host_guard(self):
        for path in ("/api/open-claude", "/api/finish"):
            self.assertEqual(self.call("POST", path, token=False)[0], 403, path)
            self.assertEqual(self.call("POST", path, token="wrong")[0], 403, path)
        self.assertEqual(self.call("GET", "/api/state", token=False)[0], 403)
        self.assertEqual(self.call("GET", "/api/state", host="evil.example:%d" % self.port)[0], 403, "DNS rebinding")
        self.assertEqual(self.call("POST", "/api/wire-key")[0], 404, "no connector endpoints")
        code, body = self.call("GET", "/api/state")
        self.assertEqual(code, 200)
        self.assertEqual(len(json.loads(body)["steps"]), 6)
        for page in ("/", "/index.html", "/app.js", "/app.css", "/tokens.css"):
            self.assertEqual(self.call("GET", page, token=False)[0], 200, page)
        self.assertEqual(self.call("GET", "/../server.py", token=False)[0], 404)

    def test_finish_retires(self):
        code, _ = self.call("POST", "/api/finish")
        self.assertEqual(code, 200)
        self.proc.wait(timeout=10)
        self.assertTrue((self.vault / "System" / ".onboard" / "done.json").exists())
        out = subprocess.run([sys.executable, "-X", "utf8", str(SERVER), "--vault", str(self.vault), "--state"],
                             capture_output=True, text=True, timeout=30)
        self.assertTrue(json.loads(out.stdout)["retired"])

    def test_second_run_reuses_window(self):
        out = subprocess.run([sys.executable, "-X", "utf8", str(SERVER), "--vault", str(self.vault), "--no-browser"],
                             capture_output=True, text=True, timeout=30)
        self.assertIn("already running", out.stdout)
        self.assertIn(":%d/" % self.port, out.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
