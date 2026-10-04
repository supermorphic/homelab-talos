"""Exercise retained-PVC and UI recovery through the actual persistence script."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/verify/portainer-persistence.sh"


class PortainerPersistenceTests(unittest.TestCase):
    def test_new_pod_preserves_claim_and_ui_with_atomic_disruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            (root / "config").touch()
            kube = root / "bin/kubectl"
            kube.write_text(
                "#!"
                + sys.executable
                + "\n"
                + r"""import datetime, json, os, sys
from pathlib import Path
root=Path(os.environ["PORTAINER_FIXTURE"])
a=sys.argv[1:]
assert a[:2] == ["--kubeconfig",str(root / "config")]
assert "--context" not in a
op=next(x for x in a if x in {"get","delete","rollout"})
if op == "delete":
    assert "--raw" in a
    assert a[a.index("--raw")+1] == "/api/v1/namespaces/portainer/pods/portainer-old"
    options=json.load(sys.stdin)
    assert options["preconditions"] == {"uid":"old-uid","resourceVersion":"12"}
    assert options["propagationPolicy"] == "Foreground"
    (root / "deleted").touch()
elif op == "get":
    kind=a[a.index("get")+1]
    if kind == "lease":
        now=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000Z")
        print(json.dumps({"spec":{"holderIdentity":"fixture-run","renewTime":now,"leaseDurationSeconds":90}}))
    elif kind == "deployment": print("1")
    elif kind == "persistentvolumeclaim": print("Bound" if ".status.phase" in a[-1] else "retained-pvc-uid")
    elif kind == "pod":
        if "-l" in a: print("portainer-new" if (root / "deleted").exists() else "portainer-old")
        elif a[-1] == "json":
            if not (root / "deleted").exists():
                print(json.dumps({"kind":"Pod","metadata":{"name":"portainer-old","namespace":"portainer","uid":"old-uid","resourceVersion":"12"}}))
        else: print("new-uid" if (root / "deleted").exists() else "old-uid")
    else: raise ValueError(kind)
"""
            )
            kube.chmod(0o755)
            curl = root / "bin/curl"
            curl.write_text('#!/bin/sh\ntouch "$PORTAINER_FIXTURE/ui-checked"\n')
            curl.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT), str(root / "config")],
                cwd=ROOT,
                env={
                    **os.environ,
                    "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                    "PORTAINER_FIXTURE": str(root),
                    "TEST_LEASE_KUBECTL": str(kube),
                    "TEST_CAMPAIGN_LEASE_HOLDER": "fixture-run",
                    "PORTAINER_PERSISTENCE_CONFIRM": "recreate:portainer:pod:preserve-pvc",
                },
                text=True,
                capture_output=True,
                timeout=20,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("original PVC and the UI recovered", result.stdout)
            self.assertTrue((root / "deleted").exists())
            self.assertTrue((root / "ui-checked").exists())


if __name__ == "__main__":
    unittest.main()
