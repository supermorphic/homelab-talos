import contextlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "kubernetes/apps/web-research/crawl4ai/runtime/server_launcher.py"


def load_launcher():
    spec = importlib.util.spec_from_file_location("crawl4ai_server_launcher", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def wait_for(predicate, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    return predicate()


def process_is_running(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        output = subprocess.check_output(["ps", "-o", "stat=", "-p", str(pid)], text=True).strip()
    except subprocess.CalledProcessError:
        return False
    return bool(output) and not output.startswith("Z")


class LauncherProcess:
    def __init__(self, root, *, fixture_mode="stay"):
        self.root = Path(root)
        self.bootstrap = self.root / "bootstrap"
        self.runtime = self.root / "runtime"
        self.templates = self.root / "templates"
        self.source = self.root / "source"
        self.events = self.root / "events.jsonl"
        self.fixture = self.root / "native_fixture.py"
        for directory in (self.bootstrap, self.templates, self.source):
            directory.mkdir()
        (self.source / "server.py").write_text("# native module\n", encoding="utf-8")
        (self.source / "static").mkdir()
        (self.source / "static" / "index.html").write_text("native", encoding="utf-8")
        (self.templates / "config.yml").write_text(
            "security:\n  api_token: ''\nredis:\n  password: ''\n", encoding="utf-8"
        )
        self.fixture.write_text(FIXTURE_PROGRAM, encoding="utf-8")
        command = [
            sys.executable,
            str(MODULE_PATH),
            "--bootstrap-dir",
            str(self.bootstrap),
            "--runtime-dir",
            str(self.runtime),
            "--template-dir",
            str(self.templates),
            "--source-dir",
            str(self.source),
            "--poll-interval",
            "0.03",
            "--restart-initial",
            "0.03",
            "--restart-maximum",
            "0.12",
            "--stop-timeout",
            "0.4",
            "--command",
            sys.executable,
            str(self.fixture),
            str(self.runtime),
            str(self.events),
            fixture_mode,
        ]
        environment = os.environ.copy()
        environment.update(
            {
                "AZURE_OPENAI_API_KEY": "synthetic-azure-secret",
                "AWS_SECRET_ACCESS_KEY": "synthetic-aws-secret",
                "COHERE_API_KEY": "synthetic-cohere-secret",
                "MISTRAL_API_KEY": "synthetic-mistral-secret",
            }
        )
        self.process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )

    def install_bundle(self, name, token, key):
        version = self.bootstrap / name
        version.mkdir()
        (version / "api_token").write_text(token, encoding="ascii")
        (version / "signing_key").write_text(key, encoding="ascii")
        link = self.bootstrap / "..data.next"
        link.symlink_to(name)
        os.replace(link, self.bootstrap / "..data")

    def events_list(self):
        if not self.events.exists():
            return []
        return [json.loads(line) for line in self.events.read_text().splitlines() if line]

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            self.process.wait(timeout=3)
        return self.process.communicate(timeout=1)


FIXTURE_PROGRAM = r'''
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

runtime, events, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
worker_code = r"""
import json, os, signal, subprocess, sys, time
from pathlib import Path
if sys.argv[2] == 'detached':
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
grandchild_code = "import os, signal, time\nif os.environ.get('DETACH_GRANDCHILD') == 'true':\n    os.setsid()\n    signal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(60)\n"
grandchild_environment = os.environ.copy()
grandchild_environment['DETACH_GRANDCHILD'] = str(sys.argv[2] == 'detached').lower()
grandchild = subprocess.Popen([sys.executable, '-c', grandchild_code], env=grandchild_environment)
Path(sys.argv[1]).write_text(json.dumps({'worker': os.getpid(), 'grandchild': grandchild.pid}))
time.sleep(60)
"""
pids_file = runtime / f"pids-{os.getpid()}.json"
worker_mode = 'detached' if mode.startswith('detached') else 'attached'
worker = subprocess.Popen([sys.executable, "-c", worker_code, str(pids_file), worker_mode])
deadline = time.monotonic() + 1
while not pids_file.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
pids = json.loads(pids_file.read_text())
record = {
    'pid': os.getpid(),
    'worker': pids['worker'],
    'grandchild': pids['grandchild'],
    'token': os.environ['CRAWL4AI_API_TOKEN'],
    'key': os.environ['SECRET_KEY'],
    'jwt': os.environ['CRAWL4AI_JWT_ENABLED'],
    'redis_password_set': len(os.environ['REDIS_PASSWORD']) >= 32,
    'ambient_credentials': sorted(
        name for name in (
            'AZURE_OPENAI_API_KEY',
            'AWS_SECRET_ACCESS_KEY',
            'COHERE_API_KEY',
            'MISTRAL_API_KEY',
        ) if name in os.environ
    ),
}
print(os.environ['CRAWL4AI_API_TOKEN'], flush=True)
print(os.environ['SECRET_KEY'], file=sys.stderr, flush=True)
with events.open('a') as stream:
    stream.write(json.dumps(record) + '\n')
    stream.flush()
if mode == 'exit':
    os.kill(worker.pid, signal.SIGTERM)
    worker.wait()
    raise SystemExit(17)
if mode == 'detached_exit':
    raise SystemExit(19)
time.sleep(60)
'''


class ServerLauncherTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)

    def launch(self, **kwargs):
        launcher = LauncherProcess(self.root, **kwargs)
        self.addCleanup(launcher.stop)
        return launcher

    def test_initial_bundle_renders_private_config_and_native_links(self):
        launcher = self.launch()
        launcher.install_bundle("..v1", "a" * 32, "s" * 32)

        self.assertTrue(wait_for(lambda: len(launcher.events_list()) == 1))

        config = (launcher.runtime / "config.yml").read_text()
        self.assertIn("a" * 32, config)
        self.assertNotIn("s" * 32, config)
        self.assertEqual(0o600, (launcher.runtime / "config.yml").stat().st_mode & 0o777)
        self.assertEqual(
            (launcher.source / "server.py").resolve(),
            (launcher.runtime / "server.py").resolve(),
        )
        self.assertEqual(
            (launcher.source / "static").resolve(),
            (launcher.runtime / "static").resolve(),
        )
        event = launcher.events_list()[0]
        self.assertEqual("true", event["jwt"])
        self.assertTrue(event["redis_password_set"])
        self.assertEqual([], event["ambient_credentials"])

    def test_missing_or_malformed_bootstrap_never_starts_a_child(self):
        launcher = self.launch()
        launcher.install_bundle("..bad", "short", "k" * 32)

        health_path = launcher.runtime / "launcher-health.json"
        self.assertTrue(wait_for(health_path.exists))
        time.sleep(0.12)

        self.assertEqual([], launcher.events_list())
        self.assertEqual(
            {"ready": False, "reason": "bootstrap_invalid"},
            json.loads(health_path.read_text()),
        )

    def test_missing_bootstrap_directory_is_reported_as_invalid(self):
        launcher_module = load_launcher()

        with self.assertRaises(launcher_module.BootstrapInvalid):
            launcher_module.read_bootstrap(self.root / "absent")

    def test_projected_directory_replacement_is_read_as_one_coherent_snapshot(self):
        launcher_module = load_launcher()
        bootstrap = self.root / "bootstrap"
        bootstrap.mkdir()
        for name, character in (("..v1", "1"), ("..v2", "2")):
            version = bootstrap / name
            version.mkdir()
            (version / "api_token").write_text(character * 32, encoding="ascii")
            (version / "signing_key").write_text(character * 40, encoding="ascii")
        (bootstrap / "..data").symlink_to("..v1")
        stop = threading.Event()

        def swap():
            index = 0
            while not stop.is_set():
                target = "..v1" if index % 2 else "..v2"
                replacement = bootstrap / f"..next-{index % 2}"
                try:
                    replacement.symlink_to(target)
                    os.replace(replacement, bootstrap / "..data")
                except FileExistsError:
                    pass
                index += 1

        thread = threading.Thread(target=swap)
        thread.start()
        self.addCleanup(thread.join, 1)
        try:
            snapshots = 0
            for _ in range(500):
                try:
                    bundle = launcher_module.read_bootstrap(bootstrap)
                except launcher_module.BootstrapInvalid:
                    continue
                self.assertEqual(bundle.api_token[0], bundle.signing_key[0])
                snapshots += 1
            self.assertGreater(snapshots, 100)
        finally:
            stop.set()
            thread.join(timeout=1)

    def test_bootstrap_replacement_stops_old_tree_before_new_child_starts(self):
        launcher = self.launch(fixture_mode="detached")
        launcher.install_bundle("..v1", "a" * 32, "s" * 32)
        self.assertTrue(wait_for(lambda: len(launcher.events_list()) == 1))
        old = launcher.events_list()[0]

        launcher.install_bundle("..v2", "b" * 32, "t" * 32)
        self.assertTrue(wait_for(lambda: len(launcher.events_list()) == 2))

        new = launcher.events_list()[1]
        self.assertEqual("b" * 32, new["token"])
        self.assertEqual("t" * 32, new["key"])
        for field in ("pid", "worker", "grandchild"):
            self.assertFalse(process_is_running(old[field]), field)

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux subreaper semantics")
    def test_supervisor_crash_cleans_adopted_detached_descendants_before_restart(self):
        launcher = self.launch(fixture_mode="detached_exit")
        launcher.install_bundle("..v1", "a" * 32, "s" * 32)
        self.assertTrue(wait_for(lambda: len(launcher.events_list()) >= 2))
        old = launcher.events_list()[0]

        for field in ("pid", "worker", "grandchild"):
            self.assertFalse(process_is_running(old[field]), field)

    def test_replacement_is_withheld_when_cleanup_cannot_be_proved(self):
        launcher_module = load_launcher()
        runtime = self.root / "runtime"
        templates = self.root / "templates"
        source = self.root / "source"
        for directory in (runtime, templates, source):
            directory.mkdir()
        (templates / "config.yml").write_text(
            "security:\n  api_token: old\nredis:\n  password: old\n", encoding="utf-8"
        )
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            start_new_session=True,
        )

        def stop_child():
            if child.poll() is None:
                child.kill()
            child.wait(timeout=1)

        self.addCleanup(stop_child)
        instance = launcher_module.Launcher(
            bootstrap_dir=self.root,
            runtime_dir=runtime,
            template_dir=templates,
            source_dir=source,
            command=[sys.executable, "-c", "raise SystemExit('must not start')"],
            poll_interval=0.1,
            restart_initial=0.1,
            restart_maximum=1,
            stop_timeout=0.1,
        )
        old = launcher_module.Bootstrap("a" * 32, "s" * 32)
        instance.active_bootstrap = old
        instance.child = child

        output = io.StringIO()
        with (
            mock.patch.object(launcher_module, "_stop_child", return_value=False),
            contextlib.redirect_stderr(output),
        ):
            replaced = instance._replace(launcher_module.Bootstrap("b" * 32, "t" * 32))

        self.assertFalse(replaced)
        self.assertEqual(old, instance.active_bootstrap)
        self.assertIs(child, instance.child)
        self.assertTrue(process_is_running(child.pid))
        self.assertFalse((runtime / "config.yml").exists())
        self.assertEqual("server-launcher: cleanup_incomplete\n", output.getvalue())

    def test_linux_cleanup_tracking_failure_keeps_backend_closed(self):
        launcher_module = load_launcher()
        runtime = self.root / "runtime"
        instance = launcher_module.Launcher(
            bootstrap_dir=self.root,
            runtime_dir=runtime,
            template_dir=self.root,
            source_dir=self.root,
            command=[sys.executable, "-c", "raise SystemExit('must not start')"],
            poll_interval=0.1,
            restart_initial=0.1,
            restart_maximum=1,
            stop_timeout=0.1,
        )

        with mock.patch.object(launcher_module, "_enable_linux_subreaper", return_value=False):
            result = instance.run()

        self.assertEqual(1, result)
        self.assertIsNone(instance.child)
        self.assertEqual(
            {"ready": False, "reason": "cleanup_unavailable"},
            json.loads((runtime / "launcher-health.json").read_text()),
        )

    def test_invalid_replacement_keeps_old_child_and_health_recovers(self):
        launcher = self.launch()
        launcher.install_bundle("..v1", "a" * 32, "s" * 32)
        self.assertTrue(wait_for(lambda: len(launcher.events_list()) == 1))
        original_pid = launcher.events_list()[0]["pid"]

        launcher.install_bundle("..bad", "short", "t" * 32)
        health_path = launcher.runtime / "launcher-health.json"
        self.assertTrue(
            wait_for(
                lambda: json.loads(health_path.read_text()).get("reason") == "bootstrap_invalid"
            )
        )
        self.assertTrue(process_is_running(original_pid))
        self.assertEqual(1, len(launcher.events_list()))

        launcher.install_bundle("..restored", "a" * 32, "s" * 32)
        self.assertTrue(wait_for(lambda: json.loads(health_path.read_text()).get("ready") is True))
        self.assertEqual(1, len(launcher.events_list()))

    def test_unexpected_child_exit_restarts_with_bounded_backoff(self):
        launcher = self.launch(fixture_mode="exit")
        launcher.install_bundle("..v1", "a" * 32, "s" * 32)

        self.assertTrue(wait_for(lambda: len(launcher.events_list()) >= 2))

        self.assertNotEqual(launcher.events_list()[0]["pid"], launcher.events_list()[1]["pid"])

    def test_stopping_launcher_cleans_up_worker_and_grandchild(self):
        launcher = self.launch()
        launcher.install_bundle("..v1", "a" * 32, "s" * 32)
        self.assertTrue(wait_for(lambda: len(launcher.events_list()) == 1))
        pids = launcher.events_list()[0]

        launcher.stop()

        for field in ("pid", "worker", "grandchild"):
            self.assertTrue(wait_for(lambda field=field: not process_is_running(pids[field])))

    def test_logs_and_health_never_contain_credentials(self):
        token = "ADMIN-CREDENTIAL-" + "a" * 32
        key = "SIGNING-CREDENTIAL-" + "s" * 32
        launcher = self.launch()
        launcher.install_bundle("..v1", token, key)
        self.assertTrue(wait_for(lambda: len(launcher.events_list()) == 1))

        stdout, stderr = launcher.stop()
        health = (launcher.runtime / "launcher-health.json").read_text()

        for output in (stdout, stderr, health):
            self.assertNotIn(token, output)
            self.assertNotIn(key, output)


if __name__ == "__main__":
    unittest.main()
