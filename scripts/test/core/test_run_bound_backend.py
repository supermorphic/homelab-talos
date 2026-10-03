"""Backend supervision preserves output/exit status and waits for signal cleanup."""

import os
import signal
import subprocess
import sys
import tempfile
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
