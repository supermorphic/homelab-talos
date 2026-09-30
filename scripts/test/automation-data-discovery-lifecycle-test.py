#!/usr/bin/env python3
"""A successful mutation and its independent readback have separate outcomes."""

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
import automation_data_access as access
from automation_data_inventory import validate_observation

spec = importlib.util.spec_from_file_location(
    "lifecycle_fixtures", Path(__file__).with_name("automation-data-discovery-command-test.py")
)
fixtures_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures_module)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.raw = fixtures_module.fixtures()
        self.mutation = {
            "ok": True,
            "domain": "sample",
            "operation": "login-complete",
            "application": "interview",
            "role": fixtures_module.APP_ROLE,
            "state": "ready",
            "credentialGeneration": 2,
        }

    def readback(self):
        self.assertTrue(
            callable(getattr(access, "lifecycle_readback", None)), "Lifecycle readback missing"
        )
        with (
            patch.object(access, "load_access_config", return_value=object()),
            patch.object(
                access,
                "fetch_observations",
                side_effect=lambda *_: [
                    validate_observation(raw, source) for source, raw in self.raw.items()
                ],
            ),
        ):
            return access.lifecycle_readback(self.mutation)

    def test_acknowledged_generation_is_independently_observed(self):
        self.assertEqual(self.readback()["status"], "observed")
        row = next(o for o in self.raw["platform"]["objects"] if o["kind"] == "application")
        row["credentialGeneration"] = 1
        self.assertEqual(self.readback()["status"], "inconsistent")

    def test_failed_enumeration_is_incomplete_and_retry_has_no_mutation(self):
        self.raw["platform"] = {"source": "platform", "status": "unavailable", "complete": False}
        self.assertEqual(self.readback()["status"], "unavailable")
        self.assertEqual(self.readback()["status"], "unavailable")
        self.assertEqual(self.mutation["ok"], True)

    def test_direct_workflow_response_preserves_success_after_readback_failure(self):
        runner = """const fs=require('fs');const vm=require('vm');
const input=JSON.parse(fs.readFileSync(0,'utf8')); const mutation=input.mutation;
for(const name of ['automation-data-provisioner','nocodb-source-provisioner']) {
 const graph=JSON.parse(fs.readFileSync('kubernetes/apps/automation/n8n/app/workflows/'+name+'.json'));
 const node=graph.nodes.find(n=>n.name==='Attach Inventory Readback');
 if(!node)throw Error('Lifecycle workflow readback missing');
 const http=graph.nodes.find(n=>n.name==='Observe Mutation Inventory');
 if(http.parameters.url!=='http://127.0.0.1:5678/webhook/automation-data-credential-inventory')throw Error('Unexpected inventory destination');
 if(http.credentials.httpHeaderAuth.name!=='Automation Data Inventory Header')throw Error('Broader credential used');
 const run=vm.runInNewContext('(function(){'+node.parameters.jsCode+'})()',{
   $json:input.inventory ?? {error:'SENTINEL_REMOTE_SECRET'},$:()=>({first:()=>({json:{mutation,startedAt:Date.now()}})}), Date, Buffer});
 if(run[0].json.ok!==true || run[0].json.inventoryReadback.status!==input.expected)throw Error('Incorrect independent evidence');
 if(JSON.stringify(run).includes('SENTINEL_REMOTE_SECRET'))throw Error('Raw error leaked');
 console.log(JSON.stringify(run[0].json));
} """
        inventory = {
            "schemaVersion": 1,
            "sources": [{**raw, "objectCount": len(raw["objects"])} for raw in self.raw.values()],
        }
        for evidence, expected in [(None, "unavailable"), (inventory, "observed")]:
            result = subprocess.run(
                ["mise", "exec", "--", "node", "-e", runner],
                input=json.dumps(
                    {"mutation": self.mutation, "inventory": evidence, "expected": expected}
                ),
                text=True,
                capture_output=True,
                cwd=ROOT,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            for output in result.stdout.splitlines():
                self.assertEqual(
                    {k: v for k, v in json.loads(output).items() if k != "inventoryReadback"},
                    self.mutation,
                )


if __name__ == "__main__":
    unittest.main()
