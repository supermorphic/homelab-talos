"""Run the native Just canary body against an independent fake API."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class FluxCanaryTests(unittest.TestCase):
    def test_named_encrypted_secret_recreation_uses_atomic_uid_and_same_config(self):
        recipe = json.loads(
            subprocess.check_output(["just", "--dump", "--dump-format", "json"], cwd=ROOT)
        )["modules"]["kube"]["recipes"]["_flux-canary-test-raw"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            config = root / "config"
            config.touch()
            body = []
            for line in recipe["body"]:
                parts = []
                for fragment in line:
                    if isinstance(fragment, str):
                        parts.append(fragment)
                    else:
                        self.assertEqual(fragment, [["variable", "kubeconfig"]])
                        parts.append(str(config))
                body.append("".join(parts))
            kube = root / "bin/kubectl"
            kube.write_text(
                "#!"
                + sys.executable
                + "\n"
                + r"""import datetime,json,os,sys
from pathlib import Path
root=Path(os.environ["CANARY_FIXTURE"])
a=sys.argv[1:]
assert a[:2] == ["--kubeconfig",str(root / "config")]
assert "--context" not in a
if "delete" in a:
    assert "--raw" in a
    assert a[a.index("--raw")+1] == "/api/v1/namespaces/flux-system/secrets/flux-canary"
    assert json.load(sys.stdin)["preconditions"] == {"uid":"original-canary-uid","resourceVersion":"12"}
    (root / "deleted").touch()
elif "lease" in a:
    now=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000Z")
    print(json.dumps({"spec":{"holderIdentity":"fixture-run","renewTime":now,"leaseDurationSeconds":90}}))
elif "--output" in a and a[a.index("--output")+1] == "json":
    print(json.dumps({"metadata":{"uid":"original-canary-uid","resourceVersion":"12","labels":{"app.kubernetes.io/component":"reconciliation-canary"}},"data":{"canary":"U1lOVEhFVElDX0ZJWFRVUkU="}}))
else:
    assert (root / "reconciled").exists()
    print("recreated-canary-uid")
"""
            )
            kube.chmod(0o755)
            flux = root / "bin/flux"
            flux.write_text(
                "#!"
                + sys.executable
                + "\n"
                + r"""import os,sys
from pathlib import Path
root=Path(os.environ["CANARY_FIXTURE"])
a=sys.argv[1:]
assert a[:3] == ["reconcile","kustomization","flux-canary"]
assert a[a.index("--kubeconfig")+1] == str(root / "config")
assert "--with-source" in a and (root / "deleted").exists()
(root / "reconciled").touch()
"""
            )
            flux.chmod(0o755)
            just = root / "bin/just"
            just.write_text(
                '#!/bin/sh\n[ "$*" = "kube flux-verify" ] || exit 64\ntouch "$CANARY_FIXTURE/verified"\n'
            )
            just.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", "\n".join(body)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                    "CANARY_FIXTURE": str(root),
                    "TEST_LEASE_KUBECTL": str(kube),
                    "HOMELAB_DISRUPTION_LEASE_HOLDER": "fixture-run",
                    "FLUX_CANARY_CONFIRM": "recreate:flux-system:flux-canary",
                },
                text=True,
                capture_output=True,
                timeout=20,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("new Secret UID", result.stdout)
            self.assertTrue((root / "verified").exists())
            self.assertNotIn("U1lOVEhFVElDX0ZJWFRVUkU", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
