"""Execute dedicated backends against independent command and API fixtures."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class DedicatedBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.config = self.directory / "selected-config"
        self.config.touch()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "DEDICATED_FIXTURE": str(self.directory),
            "HOMELAB_DISRUPTION_LEASE_HOLDER": "synthetic-run",
            "HOMELAB_TEST_RUN_DIR": str(self.directory / "synthetic-run"),
        }
        (self.directory / "synthetic-run" / "diagnostics").mkdir(parents=True)
        self.executable(
            "kubectl",
            r"""import datetime,json,os,sys
from pathlib import Path
root=Path(os.environ['DEDICATED_FIXTURE']); a=sys.argv[1:]
assert a[:2] == ['--kubeconfig',str(root/'selected-config')]
assert '--context' not in a
with (root/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
if 'lease' in a:
    print(json.dumps({'spec':{'holderIdentity':'synthetic-run','renewTime':datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000000Z'),'leaseDurationSeconds':90}}))
elif 'api-resources' in a:
    print('ciliumclusterwidenetworkpolicies.cilium.io\nciliumcidrgroups.cilium.io\nciliumclusterwideenvoyconfigs.cilium.io\nclusternetworkpolicies.policy.networking.k8s.io')
elif 'get' in a:
    if 'node' in a:
        print(json.dumps({'apiVersion':'v1','kind':'Node','metadata':{'name':'nuc2','uid':'node-uid','resourceVersion':'7'},'spec':{'unschedulable':os.environ.get('ALREADY_CORDONED')=='yes'}}))
    elif 'deployment' in a:
        name=a[a.index('deployment')+1]
        assert name in ['source-controller','kustomize-controller','helm-controller','notification-controller']
        print(json.dumps({'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':name,'uid':name+'-uid','resourceVersion':'12'},'spec':{'template':{'metadata':{}}}}))
    elif 'ciliumcidrgroups.cilium.io' in a and os.environ.get('FOREIGN_GLOBAL')=='yes':
        print('{"metadata":{"uid":"foreign-policy"}}')
    elif 'namespace' in a or 'namespaces' in a:
        resource='namespace' if 'namespace' in a else 'namespaces'
        name=a[a.index(resource)+1]; state=root/(name+'.json')
        if state.exists(): print(state.read_text())
elif 'create' in a:
    d=json.loads(Path(a[a.index('--filename')+1]).read_text()); m=d['metadata']; name=m['name']
    assert m['annotations']=={'homelab.supermorphic.com/test-run':'synthetic-run'}
    if d['kind']=='Namespace':
        assert name in ['cilium-test-1','cilium-test-ccnp1','cilium-test-ccnp2']
        assert m['labels']=={'app.kubernetes.io/name':'cilium-cli','pod-security.kubernetes.io/enforce':'privileged'}
    else:
        assert d['kind']=='RoleBinding' and name=='homelab-test-cilium-fixtures'
        ns=m['namespace']; assert (root/(ns+'.json')).exists()
        assert m['ownerReferences']==[{'apiVersion':'v1','kind':'Namespace','name':ns,'uid':ns+'-uid'}]
        role='homelab-test-cilium-fixtures-1' if ns=='cilium-test-1' else 'homelab-test-cilium-fixtures-ccnp'
        assert d['roleRef']=={'apiGroup':'rbac.authorization.k8s.io','kind':'ClusterRole','name':role}
        assert d['subjects']==[{'kind':'ServiceAccount','name':'homelab-test-cilium-connectivity','namespace':'kube-system'}]
    m.update(uid=name+'-uid',resourceVersion='12')
    if d['kind']=='Namespace': m['labels']['kubernetes.io/metadata.name']=name
    print(json.dumps(d))
    if d['kind']=='Namespace': (root/(name+'.json')).write_text(json.dumps(d))
elif 'patch' in a:
    assert '--type=json' in a
    patch=json.loads(a[a.index('--patch')+1]); target=a[a.index('patch')+1]
    if target=='node':
        assert patch[:2]==[{'op':'test','path':'/metadata/uid','value':'node-uid'},{'op':'test','path':'/metadata/resourceVersion','value':'7'}]
        assert patch[2]=={'op':'add','path':'/spec/unschedulable','value':os.environ.get('NODE_ACTION','cordon')=='cordon'}
    else:
        assert target=='deployment'; name=a[a.index('deployment')+1]
        assert patch[:2]==[{'op':'test','path':'/metadata/uid','value':name+'-uid'},{'op':'test','path':'/metadata/resourceVersion','value':'12'}]
        assert patch[2]['path']=='/spec/template/metadata/annotations'
        assert set(patch[2]['value'])=={'kubectl.kubernetes.io/restartedAt'}
    assert len(patch)==3
elif 'delete' in a:
    assert '--raw' in a
    endpoint=a[a.index('--raw')+1]; name=endpoint.rsplit('/',1)[1]
    assert endpoint=='/api/v1/namespaces/'+name
    assert json.load(sys.stdin)['preconditions']=={'uid':name+'-uid','resourceVersion':'12'}
    (root/(name+'.json')).unlink()
elif 'rollout' in a:
    assert a[a.index('rollout')+1]=='status'
else: raise AssertionError(a)
""",
        )
        self.executable(
            "just",
            "import os,sys\nfrom pathlib import Path\na=sys.argv[1:]\nassert a in [['kube','flux-verify'],['kube','cilium-postflight']]\nPath(os.environ['DEDICATED_FIXTURE'],'postflight').touch()\n",
        )
        self.env["TEST_LEASE_KUBECTL"] = str(self.bin / "kubectl")

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{source}")
        path.chmod(0o755)

    def run_backend(self, command):
        return subprocess.run(
            command,
            cwd=ROOT,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def calls(self):
        path = self.directory / "calls"
        return (
            [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        )

    def test_postflight_suites_declare_their_talos_reader_input(self):
        from scripts.test.access import resolve_suite_access

        for suite in (
            "test.cilium-connectivity",
            "verification.cilium",
            "verification.flux",
            "verification.foundation",
            "test.flux-restart",
            "test.flux-canary",
        ):
            with self.subTest(suite=suite):
                self.assertIn("talos-reader", resolve_suite_access(ROOT, suite)["prerequisites"])

    def test_node_scheduling_uses_atomic_patch_and_fresh_lease(self):
        for action in ("cordon", "uncordon"):
            with self.subTest(action=action):
                self.env["NODE_ACTION"] = action
                result = self.run_backend(
                    [
                        "bash",
                        "scripts/test/actions/node-scheduling.sh",
                        action,
                        str(self.config),
                        "nuc2",
                    ]
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum("patch" in a for a in self.calls()), 2)
        self.assertEqual(sum("lease" in a for a in self.calls()), 2)

    def test_cilium_unconfirmed_call_has_no_api_or_cleanup(self):
        self.executable(
            "cilium",
            "import os\nfrom pathlib import Path\nPath(os.environ['DEDICATED_FIXTURE'],'cli-called').touch()\n",
        )
        result = self.run_backend(
            ["bash", "scripts/test/scenarios/cilium-connectivity.sh", str(self.config)]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.directory / "cli-called").exists())

    def install_cilium(self):
        self.executable(
            "cilium",
            r"""import os,sys
from pathlib import Path
root=Path(os.environ['DEDICATED_FIXTURE']); a=sys.argv[1:]
assert a[a.index('--kubeconfig')+1]==str(root/'selected-config')
assert '--context' not in a and '--cleanup' not in a
(root/'cli-called').touch()
if a[:2]==['connectivity','test']:
    assert all((root/(n+'.json')).exists() for n in ['cilium-test-1','cilium-test-ccnp1','cilium-test-ccnp2'])
    assert a[a.index('--namespace-annotations')+1]=='homelab.supermorphic.com/test-run=synthetic-run'
    for key,value in [('--ip-families','ipv4'),('--flow-validation','disabled'),('--test','!no-unexpected-packet-drops'),('--timeout','45m')]: assert a[a.index(key)+1]==value
    assert '--hubble=false' in a and '--sysdump-output-filename' in a
    if os.environ.get('REPLACE_NAMESPACE')=='yes':
        import json
        path=root/'cilium-test-1.json'; d=json.loads(path.read_text())
        d['metadata']['uid']='replacement-uid'; path.write_text(json.dumps(d))
    sys.exit(int(os.environ.get('CILIUM_RESULT','0')))
assert a[0]=='sysdump'
(root/'diagnosed').touch(); sys.exit(2)
""",
        )

    def test_cilium_owned_namespaces_keep_canonical_coverage_and_same_diagnostics(self):
        self.install_cilium()
        self.env["CILIUM_CONNECTIVITY_CONFIRM"] = "test:cilium-connectivity"
        self.env["CILIUM_RESULT"] = "7"
        result = self.run_backend(
            ["bash", "scripts/test/scenarios/cilium-connectivity.sh", str(self.config)]
        )
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertTrue((self.directory / "diagnosed").exists())
        self.assertIn("diagnostics failed", result.stderr)
        self.assertEqual(sum("delete" in a for a in self.calls()), 3)
        self.assertFalse(any(self.directory.glob("cilium-test*.json")))

    def test_cilium_replaced_namespace_preserves_primary_and_reports_cleanup_failure(self):
        self.install_cilium()
        self.env.update(
            CILIUM_CONNECTIVITY_CONFIRM="test:cilium-connectivity",
            CILIUM_RESULT="7",
            REPLACE_NAMESPACE="yes",
        )
        result = self.run_backend(
            ["bash", "scripts/test/scenarios/cilium-connectivity.sh", str(self.config)]
        )
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(sum("delete" in a for a in self.calls()), 2)
        self.assertEqual(
            json.loads((self.directory / "cilium-test-1.json").read_text())["metadata"]["uid"],
            "replacement-uid",
        )
        self.assertEqual(
            json.loads((self.directory / "synthetic-run/cleanup.json").read_text())["status"],
            "failed",
        )
        self.assertFalse((self.directory / "postflight").exists())

    def test_cilium_success_checks_postflight_after_owned_cleanup(self):
        self.install_cilium()
        self.env["CILIUM_CONNECTIVITY_CONFIRM"] = "test:cilium-connectivity"
        result = self.run_backend(
            ["bash", "scripts/test/scenarios/cilium-connectivity.sh", str(self.config)]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.directory / "postflight").exists())

        self.assertEqual(sum("delete" in a for a in self.calls()), 3)
        self.assertFalse(any(self.directory.glob("cilium-test*.json")))

    def test_cilium_refuses_existing_namespace_without_adopting_it(self):
        self.install_cilium()
        self.env["CILIUM_CONNECTIVITY_CONFIRM"] = "test:cilium-connectivity"
        (self.directory / "cilium-test-1.json").write_text('{"metadata":{"uid":"foreign"}}')
        result = self.run_backend(
            ["bash", "scripts/test/scenarios/cilium-connectivity.sh", str(self.config)]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "cli-called").exists())
        self.assertFalse(any("create" in a or "delete" in a for a in self.calls()))

    def test_cilium_refuses_existing_global_fixture_without_cleanup(self):
        self.install_cilium()
        self.env["CILIUM_CONNECTIVITY_CONFIRM"] = "test:cilium-connectivity"
        self.env["FOREIGN_GLOBAL"] = "yes"
        result = self.run_backend(
            ["bash", "scripts/test/scenarios/cilium-connectivity.sh", str(self.config)]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / "cli-called").exists())
        self.assertFalse(any("create" in a or "delete" in a for a in self.calls()))

    def test_flux_restarts_four_exact_controllers_atomically(self):
        recipe = json.loads(
            subprocess.check_output(["just", "--dump", "--dump-format", "json"], cwd=ROOT)
        )["modules"]["kube"]["recipes"]["_flux-restart-raw"]
        body = []
        for line in recipe["body"]:
            parts = []
            for fragment in line:
                if isinstance(fragment, str):
                    parts.append(fragment)
                else:
                    self.assertEqual(fragment, [["variable", "kubeconfig"]])
                    parts.append(str(self.config))
            body.append("".join(parts))
        self.executable(
            "flux",
            r"""import os,sys
from pathlib import Path
a=sys.argv[1:]; root=Path(os.environ['DEDICATED_FIXTURE'])
assert a[a.index('--kubeconfig')+1]==str(root/'selected-config')
assert a[0]=='check' or (a[:3]==['reconcile','kustomization','cluster-apps'] and '--with-source' in a)
""",
        )
        self.env["FLUX_RESTART_CONFIRM"] = "restart:flux-system:controllers"
        result = self.run_backend(["bash", "-c", "\n".join(body)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        patches = [a for a in self.calls() if "patch" in a]
        self.assertEqual(
            [a[a.index("deployment") + 1] for a in patches],
            [
                "source-controller",
                "kustomize-controller",
                "helm-controller",
                "notification-controller",
            ],
        )
        self.assertEqual(sum("lease" in call for call in self.calls()), 5)
        self.assertTrue((self.directory / "postflight").exists())


if __name__ == "__main__":
    unittest.main()
