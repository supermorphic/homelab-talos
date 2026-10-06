"""Run the read-only verifier with independent Kubernetes/Prometheus responses."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]


class NewsVerificationTests(unittest.TestCase):
    def verify(self, *, active=False, workload=False, missing=False, read_error=False):
        with tempfile.TemporaryDirectory(prefix="news-verification-") as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / "scripts/lib").symlink_to(ROOT / "scripts/lib", target_is_directory=True)
            base = root / "kubernetes/apps/news"
            for unit in ("namespace", "postgresql", "freshrss", "alerts"):
                target = base / unit / "ks.yaml"
                target.parent.mkdir(parents=True)
                target.write_text(yaml.safe_dump({"spec": {"suspend": not active}}))
            (root / "kubernetes/apps/kustomization.yaml").write_text(
                yaml.safe_dump({"resources": ["./news"] if active else []})
            )
            (root / "config").touch()
            tools = root / "bin"
            tools.mkdir()
            for tool, body in {
                "kubectl": """import json, os, sys
args=sys.argv[1:]
assert 'get' in args and not any(v in args for v in ('apply','exec','delete','patch','port-forward'))
active=os.environ['FAKE_ACTIVE']=='true'
if os.environ['FAKE_READ_ERROR']=='true' and any(a.startswith(('deployment/','statefulset/')) for a in args):
    print('fixture read denied',file=sys.stderr)
    sys.exit(1)
if 'kustomization' in args:
    if active:
        print(json.dumps({'metadata':{'generation':1},'spec':{'suspend':False},
        'status':{'observedGeneration':1,'conditions':[{'type':'Ready','status':'True','observedGeneration':1}]}}))
elif active and 'deployment' in args:
    print(json.dumps({'metadata':{'generation':1},'spec':{'replicas':1},'status':{'observedGeneration':1,'availableReplicas':1}}))
elif active and 'statefulset' in args:
    print(json.dumps({'metadata':{'generation':1},'spec':{'replicas':1},'status':{'observedGeneration':1,'readyReplicas':1}}))
elif active or os.environ['FAKE_WORKLOAD']=='true':
    print('fixture-resource')
""",
                "curl": """import json, os
print(json.dumps({'status':'success','data':{'result':[] if os.environ['FAKE_MISSING']=='true' else [{'value':[0,'1']}]}}))
""",
            }.items():
                target = tools / tool
                target.write_text("#!" + shutil.which("python") + "\n" + body)
                target.chmod(0o755)
            return subprocess.run(
                ["bash", str(ROOT / "scripts/verify/news.sh"), str(root / "config")],
                cwd=root,
                check=False,
                env=dict(
                    os.environ,
                    PATH=str(tools) + ":" + os.environ["PATH"],
                    FAKE_ACTIVE=json.dumps(active),
                    FAKE_WORKLOAD=json.dumps(workload),
                    FAKE_MISSING=json.dumps(missing),
                    FAKE_READ_ERROR=json.dumps(read_error),
                ),
                capture_output=True,
                text=True,
                timeout=30,
            )

    def test_staged_absence_is_distinct_from_live_acceptance(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("phase=staged-absent", result.stdout)

    def test_staged_workload_is_rejected(self):
        self.assertNotEqual(self.verify(workload=True).returncode, 0)

    def test_failed_reads_cannot_establish_staged_absence(self):
        self.assertNotEqual(self.verify(read_error=True).returncode, 0)

    def test_active_requires_present_healthy_observations(self):
        result = self.verify(active=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.verify(active=True, missing=True).returncode, 0)
