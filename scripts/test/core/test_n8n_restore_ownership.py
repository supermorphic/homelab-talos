"""The actual restore backend cleans only API-created temporary resources."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class N8nRestoreOwnershipTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "bin").mkdir()
        (self.root / "fixture-run/diagnostics").mkdir(parents=True)
        (self.root / "config").touch()
        fake = self.root / "bin/kubectl"
        fake.write_text(
            "#!"
            + sys.executable
            + "\n"
            + r"""import datetime, json, os, sys
from pathlib import Path
import yaml
root = Path(os.environ["RESTORE_TEST_ROOT"])
a = sys.argv[1:]
assert a[:2] == ["--kubeconfig", str(root / "config")]
assert "--context" not in a
op = next(x for x in a if x in {"create", "get", "delete", "rollout", "logs"})
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps({"op":op,"args":a}) + "\n")
state = root / "state.json"
objects = json.loads(state.read_text()) if state.exists() else {}
aliases = {"job":"Job","jobs":"Job","deployment":"Deployment","deployments":"Deployment","service":"Service","services":"Service","ciliumnetworkpolicy":"CiliumNetworkPolicy","ciliumnetworkpolicies":"CiliumNetworkPolicy"}
ns = a[a.index("--namespace")+1] if "--namespace" in a else ""
if op == "create":
    path = a[a.index("--filename")+1]
    documents = yaml.safe_load_all(sys.stdin.read() if path == "-" else Path(path).read_text())
    created=[]
    for doc in documents:
        for obj in (doc if isinstance(doc,list) else [doc]):
            obj["metadata"].update(uid="api-"+obj["metadata"]["name"],resourceVersion="12")
            key = obj["metadata"]["namespace"]+"/"+obj["kind"]+"/"+obj["metadata"]["name"]
            assert key not in objects
            objects[key]=obj
            created.append(obj)
    if "--output" in a:
        assert len(created)==1
        print(json.dumps(created[0]))
    state.write_text(json.dumps(objects))
elif op == "get":
    target=a[a.index("get")+1]
    if target == "lease":
        now=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000Z")
        holder="another-run" if os.environ.get("RESTORE_TEST_LOSE_LEASE") == "true" and (root / "request-complete").exists() else "fixture-run"
        print(json.dumps({"spec":{"holderIdentity":holder,"renewTime":now,"leaseDurationSeconds":90}}))
    elif target.startswith("httproutes"):
        print('{"items":[]}')
    else:
        if "/" in target: resource,name=target.split("/",1)
        else: resource,name=target,a[a.index("get")+2]
        key=ns+"/"+aliases[resource]+"/"+name
        obj=objects.get(key)
        if obj is None and os.environ.get("RESTORE_TEST_FOREIGN") == "true" and aliases[resource] == "Job":
            obj={"kind":"Job","metadata":{"name":name,"uid":"foreign","namespace":ns}}
        if obj is not None:
            if a[a.index("--output")+1] == "name": print(resource+"/"+name)
            else:
                obj["status"]={"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}
                if obj["kind"] == "Job" and name.endswith("-request"):
                    (root / "request-complete").touch()
                print(json.dumps(obj))
elif op == "delete":
    if "--raw" in a:
        ns,resource,name=a[a.index("--raw")+1].split("/")[-3:]
        options=json.load(sys.stdin)
        key=ns+"/"+aliases[resource]+"/"+name
        assert options["preconditions"] == {"uid":objects[key]["metadata"]["uid"],"resourceVersion":"12"}
        assert options["propagationPolicy"] == "Foreground"
    else:
        resource,name=a[a.index("delete")+1:a.index("delete")+3]
        key=ns+"/"+aliases[resource]+"/"+name
    objects.pop(key,None)
    state.write_text(json.dumps(objects))
elif op == "logs":
    print("selected_dump=n8n-postgresql-20260101T000000Z.dump")
"""
        )
        fake.chmod(0o755)

    def execute(self, **environment):
        return subprocess.run(
            ["scripts/test/scenarios/n8n-restore-drill.sh", str(self.root / "config")],
            cwd=ROOT,
            env={
                **os.environ,
                "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                "RESTORE_TEST_ROOT": str(self.root),
                "N8N_RESTORE_DRILL_CONFIRM": "restore:n8n-postgresql:temporary",
                "HOMELAB_TEST_RUN_DIR": str(self.root / "fixture-run"),
                "TEST_LEASE_KUBECTL": str(self.root / "bin/kubectl"),
                "TEST_CAMPAIGN_LEASE_HOLDER": "fixture-run",
                **environment,
            },
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_existing_job_is_never_adopted_or_deleted_on_preflight_failure(self):
        result = self.execute(RESTORE_TEST_FOREIGN="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to adopt", result.stderr)
        self.assertEqual([call for call in self.calls() if call["op"] in {"create", "delete"}], [])

    def test_restore_consumer_and_cleanup_retain_all_fixed_helpers_and_creation_uids(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        deletes = [call for call in calls if call["op"] == "delete"]
        self.assertEqual(len(deletes), 7)
        self.assertTrue(all("--raw" in call["args"] for call in deletes))
        self.assertEqual(json.loads((self.root / "state.json").read_text()), {})
        run = self.root / "fixture-run"
        self.assertEqual(json.loads((run / "assertion.json").read_text())["status"], "passed")
        self.assertEqual(json.loads((run / "cleanup.json").read_text())["status"], "passed")
        records = [
            json.loads(line)
            for line in (run / "diagnostics/n8n-owned.jsonl").read_text().splitlines()
        ]
        self.assertEqual(
            Counter(record["kind"] for record in records),
            {"Job": 3, "Deployment": 1, "Service": 1, "CiliumNetworkPolicy": 2},
        )
        self.assertTrue(
            all(record["metadata"]["uid"].startswith("api-n8n-restore-") for record in records)
        )
        self.assertTrue(
            all(set(record) == {"apiVersion", "kind", "metadata"} for record in records)
        )

    def test_lost_lease_blocks_new_drop_job_and_retains_primary_assertion(self):
        result = self.execute(RESTORE_TEST_LOSE_LEASE="true")
        self.assertNotEqual(result.returncode, 0)
        run = self.root / "fixture-run"
        self.assertEqual(json.loads((run / "assertion.json").read_text())["status"], "passed")
        self.assertEqual(json.loads((run / "cleanup.json").read_text())["status"], "failed")
        records = [
            json.loads(line)
            for line in (run / "diagnostics/n8n-owned.jsonl").read_text().splitlines()
        ]
        self.assertFalse(any(record["metadata"]["name"].endswith("-drop") for record in records))


if __name__ == "__main__":
    unittest.main()
