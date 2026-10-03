"""WAN measurement succeeds only after its creation-owned Pod is removed."""

import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / "scripts/test/lib/wan-reference.sh"


class WanReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.run_dir = self.directory / "synthetic-run"
        self.run_dir.mkdir()
        self.config = self.directory / "synthetic.config"
        self.config.touch()
        binary = self.directory / "bin"
        binary.mkdir()
        fake = binary / "kubectl"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['WAN_FIXTURE'])
args = sys.argv[1:]
assert args[:2] == ['--kubeconfig', str(root / 'synthetic.config')]
with (root / 'calls.jsonl').open('a') as calls: calls.write(json.dumps(args) + '\\n')
mode = os.environ.get('WAN_MODE', '')
state_path = root / 'state.json'
if 'get' in args and 'lease' in args:
    lost = mode == 'missing-lease' or (mode == 'lease-loss' and state_path.exists())
    print(json.dumps({'spec': {'holderIdentity': 'another-run' if lost else 'synthetic-run',
        'leaseDurationSeconds': 90, 'renewTime': '2099-01-01T00:00:00Z'}}))
elif 'create' in args:
    if mode == 'collision': sys.exit(1)
    state = json.loads(Path(args[args.index('--filename') + 1]).read_text())
    state['metadata'].update(uid='synthetic-owned', resourceVersion='12')
    state_path.write_text(json.dumps(state))
    if mode == 'bad-response': state['metadata'].pop('uid')
    print(json.dumps(state))
elif 'wait' in args:
    if mode == 'signal':
        import time
        (root / 'waiting').touch()
        time.sleep(60)
    if mode == 'wait-failure': sys.exit(1)
    state = json.loads(state_path.read_text())
    state['status'] = {'phase': 'Succeeded'}
    state_path.write_text(json.dumps(state))
elif 'logs' in args:
    print('198.51.100.77')
    if mode == 'replacement':
        state = json.loads(state_path.read_text())
        state['metadata']['uid'] = 'synthetic-replacement'
        state_path.write_text(json.dumps(state))
elif 'get' in args:
    if state_path.exists(): print(state_path.read_text())
elif 'delete' in args:
    options = json.loads(sys.stdin.read())
    state = json.loads(state_path.read_text())
    assert options['preconditions'] == {'uid': state['metadata']['uid'], 'resourceVersion': '12'}
    (root / 'deletion.json').write_text(json.dumps(options))
    state_path.unlink()
else: sys.exit(64)
""")
        fake.chmod(0o700)
        self.environment = {
            **os.environ,
            "PATH": str(binary) + ":" + os.environ["PATH"],
            "HOMELAB_TEST_RUN_DIR": str(self.run_dir),
            "WAN_FIXTURE": str(self.directory),
        }

    def run_reference(self, mode="", conditional=False):
        body = 'source "$1"; wan_reference_ip "$2" qbprobe-wan-1234'
        if conditional:
            body = 'source "$1"; result="$(wan_reference_ip "$2" qbprobe-wan-1234)" || exit 1; printf "%s\\n" "$result"'
        return subprocess.run(
            [
                "bash",
                "-eu",
                "-c",
                body,
                "fixture",
                str(HELPER),
                str(self.config),
            ],
            cwd=ROOT,
            env={**self.environment, "WAN_MODE": mode},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_caller_conditional_cannot_disable_lease_or_measurement_guards(self):
        for mode in ("missing-lease", "wait-failure"):
            with self.subTest(mode=mode):
                result = self.run_reference(mode, conditional=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                calls = [
                    json.loads(line)
                    for line in (self.directory / "calls.jsonl").read_text().splitlines()
                ]
                if mode == "missing-lease":
                    self.assertFalse(any("create" in call for call in calls))
                else:
                    self.assertFalse((self.directory / "state.json").exists())
                (self.directory / "calls.jsonl").unlink()

    def test_reference_is_emitted_only_after_atomic_owned_cleanup(self):
        result = self.run_reference()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "198.51.100.77\n")
        self.assertFalse((self.directory / "state.json").exists())
        self.assertEqual(
            json.loads((self.directory / "deletion.json").read_text())["preconditions"],
            {"uid": "synthetic-owned", "resourceVersion": "12"},
        )
        self.assertEqual(
            json.loads((self.run_dir / "cleanup.json").read_text())["status"], "passed"
        )

    def test_failed_measurement_still_removes_the_created_pod(self):
        result = self.run_reference("wait-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertFalse((self.directory / "state.json").exists())
        self.assertEqual(
            json.loads((self.run_dir / "cleanup.json").read_text())["status"], "passed"
        )

    def test_replacement_and_lease_loss_refuse_cleanup_and_reference_success(self):
        for mode in ("replacement", "lease-loss"):
            with self.subTest(mode=mode):
                result = self.run_reference(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertTrue((self.directory / "state.json").exists())
                self.assertFalse((self.directory / "deletion.json").exists())
                self.assertEqual(
                    json.loads((self.run_dir / "cleanup.json").read_text())["status"], "failed"
                )
                (self.directory / "state.json").unlink()

    def test_failed_creation_never_adopts_or_deletes_a_resource(self):
        result = self.run_reference("collision")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        calls = [
            json.loads(line) for line in (self.directory / "calls.jsonl").read_text().splitlines()
        ]
        self.assertFalse(any("delete" in call for call in calls))

    def test_unrecorded_creation_cannot_claim_successful_cleanup(self):
        result = self.run_reference("bad-response")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertTrue((self.directory / "state.json").exists())
        self.assertFalse((self.directory / "deletion.json").exists())
        self.assertEqual(
            json.loads((self.run_dir / "cleanup.json").read_text())["status"], "failed"
        )

    def test_interrupt_and_termination_remove_only_the_created_pod(self):
        for sig, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(signal=sig):
                process = subprocess.Popen(
                    [
                        "bash",
                        "-eu",
                        "-c",
                        'source "$1"; wan_reference_ip "$2" qbprobe-wan-1234',
                        "fixture",
                        str(HELPER),
                        str(self.config),
                    ],
                    cwd=ROOT,
                    env={**self.environment, "WAN_MODE": "signal"},
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + 5
                    while (
                        not (self.directory / "waiting").exists() and time.monotonic() < deadline
                    ):
                        time.sleep(0.01)
                    self.assertTrue((self.directory / "waiting").exists())
                    os.killpg(process.pid, sig)
                    stdout, stderr = process.communicate(timeout=5)
                    # A signal can terminate the outer shell while its guarded
                    # subshell finishes cleanup. Both POSIX representations fail.
                    self.assertIn(process.returncode, (expected, -sig), stderr)
                    self.assertEqual(stdout, "")
                    self.assertFalse((self.directory / "state.json").exists())
                    self.assertEqual(
                        json.loads((self.run_dir / "cleanup.json").read_text())["status"], "passed"
                    )
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                    (self.directory / "waiting").unlink(missing_ok=True)
