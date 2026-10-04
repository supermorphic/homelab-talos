"""Fresh Longhorn provisioning retains placement proof and creation-owned cleanup."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class StorageProvisioningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "bin").mkdir()
        (self.root / "run/diagnostics").mkdir(parents=True)
        (self.root / "config").touch()
        fake = self.root / "bin/kubectl"
        fake.write_text(
            "#!"
            + sys.executable
            + "\n"
            + r"""import json, os, sys
from pathlib import Path
import yaml
root = Path(os.environ["STORAGE_TEST_ROOT"])
a = sys.argv[1:]
assert a[:2] == ["--kubeconfig", str(root / "config")]
assert "--context" not in a
operation = next(x for x in a if x in {"create", "get", "wait", "delete"})
state = root / "state.json"
if operation == "create":
    obj = yaml.safe_load(Path(a[a.index("--filename") + 1]).read_text())
    assert not state.exists()
    obj["metadata"].update(uid="synthetic-owned", resourceVersion="12")
    state.write_text(json.dumps(obj))
    (root / "created.json").write_text(json.dumps(obj))
    print(json.dumps(obj))
elif operation == "wait":
    obj = json.loads(state.read_text())
    obj["metadata"]["resourceVersion"] = "13"
    obj["metadata"]["annotations"] = {"pv.kubernetes.io/bind-completed": "yes"}
    obj["spec"]["volumeName"] = "synthetic-pv"
    obj["status"] = {"phase": "Bound"}
    state.write_text(json.dumps(obj))
elif operation == "get":
    resource = a[a.index("get") + 1]
    if resource == "replicas.longhorn.io":
        assert a[a.index("--selector") + 1] == "longhornvolume=synthetic-pv"
        print(json.dumps({"items": [{"spec": {"nodeID": "synthetic-a"}}, {"spec": {"nodeID": "synthetic-b"}}]}))
        if os.environ.get("STORAGE_TEST_REPLACE") == "true":
            obj = json.loads(state.read_text())
            obj["metadata"]["uid"] = "synthetic-replacement"
            state.write_text(json.dumps(obj))
    elif state.exists():
        if "--output" in a and a[a.index("--output") + 1].startswith("jsonpath="):
            print("synthetic-pv")
        else:
            print(state.read_text())
elif operation == "delete":
    options = json.load(sys.stdin) if "--raw" in a else None
    (root / "deleted.json").write_text(json.dumps({"args": a, "options": options}))
    state.unlink(missing_ok=True)
"""
        )
        fake.chmod(0o755)

    def execute(self, **environment):
        return subprocess.run(
            ["scripts/test/scenarios/storage-provisioning.sh", str(self.root / "config")],
            cwd=ROOT,
            env={
                **os.environ,
                "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                "STORAGE_TEST_ROOT": str(self.root),
                "STORAGE_PROVISIONING_CONFIRM": "test:storage-provisioning",
                "HOMELAB_TEST_RUN_DIR": str(self.root / "run"),
                **environment,
            },
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def test_fresh_claim_proves_placement_and_deletes_with_uid_and_version(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        created = json.loads((self.root / "created.json").read_text())
        self.assertRegex(created["metadata"]["name"], r"^storage-provisioning-[0-9]+-[0-9]+$")
        self.assertEqual(created["spec"]["resources"]["requests"]["storage"], "1Gi")
        deleted = json.loads((self.root / "deleted.json").read_text())
        self.assertIn("--raw", deleted["args"])
        self.assertEqual(
            deleted["options"]["preconditions"],
            {"uid": "synthetic-owned", "resourceVersion": "13"},
        )
        self.assertEqual(deleted["options"]["propagationPolicy"], "Foreground")
        self.assertFalse((self.root / "state.json").exists())
        self.assertEqual(
            json.loads((self.root / "run/cleanup.json").read_text())["status"], "passed"
        )

    def test_replaced_claim_is_retained_and_cleanup_failure_preserves_assertion(self):
        result = self.execute(STORAGE_TEST_REPLACE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "deleted.json").exists())
        self.assertEqual(
            json.loads((self.root / "state.json").read_text())["metadata"]["uid"],
            "synthetic-replacement",
        )
        self.assertEqual(
            json.loads((self.root / "run/assertion.json").read_text())["status"], "passed"
        )
        self.assertEqual(
            json.loads((self.root / "run/cleanup.json").read_text())["status"], "failed"
        )
        ledger = (self.root / "run/diagnostics/storage-owned.jsonl").read_text()
        self.assertIn("synthetic-owned", ledger)
        self.assertNotIn("synthetic-replacement", ledger)


if __name__ == "__main__":
    unittest.main()
