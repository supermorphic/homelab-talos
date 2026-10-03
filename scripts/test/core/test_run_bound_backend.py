"""Backend supervision preserves output/exit status and waits for signal cleanup."""

import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class BoundBackendTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / "backend.log"

    def launch(self, *command):
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "scripts.test.run_bound_backend",
                str(self.log),
                "--",
                *command,
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )

        def stop():
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    if (self.root / "backend-pid").exists():
                        try:
                            os.killpg(int((self.root / "backend-pid").read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    process.kill()
                    process.communicate()
            for stream in (process.stdout, process.stderr):
                if stream is not None and not stream.closed:
                    stream.close()

        self.addCleanup(stop)
        return process

    def test_streamed_stdout_stderr_and_primary_exit_are_preserved(self):
        process = self.launch(
            sys.executable,
            "-c",
            "import os; os.write(1,b'out\\n'); os.write(2,b'err\\n'); raise SystemExit(7)",
        )
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 7)
        self.assertEqual(output, b"out\nerr\n")
        self.assertEqual(error, b"")
        self.assertEqual(self.log.read_bytes(), output)

    def test_failed_launch_does_not_expose_command_arguments(self):
        process = self.launch("/synthetic/CREDENTIAL_MARKER_not_an_executable")
        output, error = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn(b"CREDENTIAL_MARKER", output + error)
        self.assertEqual(error, b"Backend could not start.\n")

    def test_attended_password_and_stdin_prompts_keep_terminal_and_hide_password(self):
        backend = """from scripts.openbao.operator import private_prompt
assert private_prompt('Operator password: ') == 'synthetic-private-value'
assert input('Recovery confirmation: ') == 'confirm'
print('ATTENDED_SUCCESS', flush=True)
"""
        harness = """import os,subprocess,sys
original = os.tcgetpgrp(0)
code = subprocess.call(['scripts/test/run-catalog-suite.sh', 'verification.metrics-server', '--', sys.executable, '-c', sys.argv[1]])
assert os.tcgetpgrp(0) == original, 'Terminal foreground group was not restored'
print('TERMINAL_RESTORED', flush=True)
raise SystemExit(code)
"""
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        for source, name in (
            ("tests/fixtures/test-access/fake-uv.sh", "uv"),
            ("tests/fixtures/result-coordinator/fake-kubectl.sh", "kubectl"),
        ):
            shutil.copy2(ROOT / source, binary_dir / name)
        environment = {
            **os.environ,
            "PATH": f"{binary_dir}:{os.environ['PATH']}",
            "TEST_FIXTURE_REAL_UV": shutil.which("uv"),
            "TEST_FIXTURE_ACCESS_TRACE": str(self.root / "access-trace"),
            "TEST_FIXTURE_ACCESS_ROOT": str(self.root),
            "TEST_RESULTS_ROOT": str(self.root / "results"),
            "TEST_KUBECONFIG": "",
            "TEST_ACCESS_CONFIG": "",
            "TEST_EXECUTION_ORIGIN": "agent",
        }
        environment.pop("TEST_CATALOG_PATH", None)
        pid, terminal = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execve(sys.executable, [sys.executable, "-c", harness, backend], environment)
        output = bytearray()
        reaped = False
        try:

            def receive(marker):
                deadline = time.monotonic() + 10
                while marker not in output:
                    remaining = deadline - time.monotonic()
                    self.assertGreater(remaining, 0, repr(bytes(output)))
                    if select.select([terminal], [], [], remaining)[0]:
                        try:
                            chunk = os.read(terminal, 4096)
                        except OSError:
                            self.fail(repr(bytes(output)))
                        self.assertTrue(chunk, repr(bytes(output)))
                        output.extend(chunk)

            receive(b"Operator password: ")
            os.write(terminal, b"synthetic-private-value\n")
            receive(b"Recovery confirmation: ")
            os.write(terminal, b"confirm\n")
            receive(b"TERMINAL_RESTORED")
            _, status = os.waitpid(pid, 0)
            reaped = True
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, repr(bytes(output)))
            self.assertIn(b"ATTENDED_SUCCESS", output)
            self.assertNotIn(b"synthetic-private-value", output)
            logs = list((self.root / "results").glob("*/logs/console.log"))
            self.assertEqual(len(logs), 1)
            self.assertNotIn(b"synthetic-private-value", logs[0].read_bytes())
        finally:
            if not reaped:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(terminal)

    def test_interrupts_reach_child_group_and_wait_for_cleanup(self):
        grandchild = """import signal,sys,time
from pathlib import Path
def stop(number,frame):
 Path(sys.argv[1]).write_text("cleaned")
 raise SystemExit(0)
signal.signal(signal.SIGINT,stop)
signal.signal(signal.SIGTERM,stop)
print("READY",flush=True)
while True: time.sleep(0.05)
"""
        backend = """import os,signal,subprocess,sys,time
from pathlib import Path
root=Path(sys.argv[1])
(root/"backend-pid").write_text(str(os.getpid()))
child=subprocess.Popen([sys.executable,"-c",sys.argv[2],str(root/"grandchild-cleanup")],stdout=subprocess.PIPE)
assert child.stdout.readline()==b"READY\\n"
def stop(number,frame):
 child.wait(timeout=5)
 (root/"backend-cleanup").write_text("cleaned")
 print("CLEANUP",flush=True)
 raise SystemExit(0)
signal.signal(signal.SIGINT,stop)
signal.signal(signal.SIGTERM,stop)
print("READY",flush=True)
while True: time.sleep(0.05)
"""
        for number in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number):
                for name in ("grandchild-cleanup", "backend-cleanup"):
                    (self.root / name).unlink(missing_ok=True)
                process = self.launch(sys.executable, "-c", backend, str(self.root), grandchild)
                self.assertEqual(process.stdout.readline(), b"READY\n")
                process.send_signal(number)
                output, error = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 128 + number, error)
                self.assertEqual(output, b"CLEANUP\n")
                self.assertEqual((self.root / "grandchild-cleanup").read_text(), "cleaned")
                self.assertEqual((self.root / "backend-cleanup").read_text(), "cleaned")
                self.assertEqual(self.log.read_bytes(), b"READY\nCLEANUP\n")
