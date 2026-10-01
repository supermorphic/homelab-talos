#!/usr/bin/env python3
"""Task resolution with independent synthetic registries and observed objects."""

import contextlib
import copy
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
import automation_data_inventory as inventory_api
from automation_data_access import ProfileMetadata
from automation_data_inventory import SCHEMA_REVISIONS, DiscoveryRequest, validate_observation

APP_ROLE = "app_477b60c9d8d9e90016cc7889711704b3_integration"


def fixtures():
    now = datetime.now(UTC).isoformat()
    role = lambda name, login=True: {
        "kind": "role",
        "id": name,
        "role": name,
        "login": login,
        "superuser": False,
        "createDb": False,
        "createRole": False,
        "inherit": False,
        "replication": False,
        "bypassRls": False,
    }
    platform = [
        {
            "kind": "domain",
            "id": "sample",
            "domain": "sample",
            "database": "sample",
            "ownerRole": "sample_owner",
            "migratorRole": "sample_migrator",
            "runtimeRole": "sample_runtime",
            "state": "ready",
            "generation": 4,
            "migratorCredentialId": "fixture-migrator",
            "runtimeCredentialId": "fixture-runtime",
            "migratorUpdatedAt": now,
            "runtimeUpdatedAt": now,
            "updatedAt": now,
        },
        {
            "kind": "application",
            "id": "sample:interview",
            "domain": "sample",
            "application": "interview",
            "schema": "consumer_schema",
            "role": APP_ROLE,
            "state": "ready",
            "operation": None,
            "operationId": None,
            "credentialGeneration": 2,
            "updatedAt": now,
            "errorCode": None,
        },
        {
            "kind": "mapping",
            "id": "sample:default",
            "domain": "sample",
            "pair": "default",
            "readerSchema": "sample_reader_schema",
            "operatorSchema": None,
        },
        {
            "kind": "source",
            "id": "sample:default:reader",
            "domain": "sample",
            "pair": "default",
            "accessKind": "reader",
            "role": "sample_reader",
            "state": "ready",
            "operation": "sync",
            "generation": 3,
            "credentialGeneration": 2,
            "baseId": "fixture-base",
            "integrationId": "fixture-integration",
            "sourceId": "fixture-source",
            "updatedAt": now,
            "validatedAt": now,
            "errorCode": None,
        },
        *[role(name) for name in [APP_ROLE, "sample_migrator", "sample_runtime", "sample_reader"]],
    ]
    nocodb = [
        {"kind": "workspace", "id": "fixture-workspace"},
        {"kind": "base", "id": "fixture-base", "workspaceId": "fixture-workspace"},
        {
            "kind": "integration",
            "id": "fixture-integration",
            "workspaceId": "fixture-workspace",
            "type": "database",
            "subType": "pg",
            "updatedAt": now,
        },
        {
            "kind": "source",
            "id": "fixture-source",
            "workspaceId": "fixture-workspace",
            "baseId": "fixture-base",
            "integrationId": "fixture-integration",
            "dataEditAllowed": False,
            "schemaEditAllowed": False,
            "enabled": True,
            "deleted": False,
            "intrinsic": False,
            "updatedAt": now,
        },
    ]
    n8n = [
        {
            "kind": "credential",
            "id": "fixture-runtime",
            "name": "automation-data/sample/runtime",
            "type": "postgres",
            "updatedAt": now,
        },
        {
            "kind": "credential",
            "id": "fixture-migrator",
            "name": "automation-data/sample/migrator",
            "type": "postgres",
            "updatedAt": now,
        },
        {
            "kind": "workflow",
            "id": "fixture-workflow",
            "published": True,
            "versionId": "fixture-version",
        },
        {
            "kind": "binding",
            "id": "fixture-workflow:1:postgres",
            "workflowId": "fixture-workflow",
            "node": "1",
            "credentialId": "fixture-runtime",
            "credentialType": "postgres",
            "published": True,
        },
    ]
    return {
        source: {
            "source": source,
            "status": "ok",
            "complete": True,
            "schemaRevision": SCHEMA_REVISIONS[source],
            "observedAt": now,
            "objects": objects,
        }
        for source, objects in [("platform", platform), ("nocodb", nocodb), ("n8n", n8n)]
    }


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(
            callable(getattr(inventory_api, "build_inventory", None)),
            "Task inventory implementation missing",
        )
        self.raw = fixtures()
        self.profile = ProfileMetadata(
            "ready", Path("/synthetic/private/service.conf"), "synthetic_service", 15432
        )

    def build(self):
        return inventory_api.build_inventory(
            [validate_observation(raw, source) for source, raw in self.raw.items()]
        )

    def resolve(self, purpose, **selectors):
        return inventory_api.resolve(
            DiscoveryRequest("resolve", "sample", purpose, **selectors), self.build(), self.profile
        )

    def test_fixed_database_credentials_and_tokens_keep_distinct_families(self):
        names = [
            "Automation Data Provisioner",
            "Automation Data Inventory Reader",
            "NocoDB Inventory Reader",
            "n8n Inventory Reader",
        ]
        for index, name in enumerate(names):
            self.raw["n8n"]["objects"].append(
                {"kind": "credential", "id": f"platform-{index}", "name": name, "type": "postgres"}
            )
        self.raw["n8n"]["objects"].extend(
            [
                {
                    "kind": "credential",
                    "id": "fixed-header",
                    "name": "Automation Data Inventory Header",
                    "type": "httpHeaderAuth",
                },
                {
                    "kind": "credential",
                    "id": "wrong-type",
                    "name": "Automation Data Provisioner",
                    "type": "httpHeaderAuth",
                },
            ]
        )
        items = {
            item["credentialId"]: item for item in self.build().items if item.get("credentialId")
        }
        for index in range(len(names)):
            self.assertEqual(items[f"platform-{index}"]["family"], "platform")
        self.assertEqual(items["fixed-header"]["family"], "api_webhook")
        self.assertEqual(items["wrong-type"]["family"], "unclassified")

    def test_all_four_purposes_and_typed_actions(self):
        application = self.resolve("application", application="interview")
        self.assertEqual(application.decision, "ready")
        self.assertEqual(
            application.next_action,
            {
                "kind": "recipe",
                "recipe": "automation-data-connect",
                "arguments": ["sample", "application/interview"],
            },
        )
        migration = self.resolve("migration")
        self.assertEqual(migration.decision, "ready")
        self.assertEqual(migration.next_action["arguments"], ["sample", "migrator"])
        self.assertEqual(self.resolve("workflow").decision, "ready")
        self.assertEqual(
            self.resolve("source", pair="default", access_kind="reader").decision, "ready"
        )
        self.assertNotIn("authorized", json.dumps(inventory_api.to_wire(application)))

    def test_multi_node_reuse_is_valid_but_missing_credential_is_not(self):
        binding = copy.deepcopy(self.raw["n8n"]["objects"][-1])
        binding["id"] = "fixture-workflow:2:postgres"
        binding["node"] = "2"
        self.raw["n8n"]["objects"].append(binding)
        self.assertEqual(self.resolve("workflow").decision, "ready")
        self.raw["n8n"]["objects"] = [
            o for o in self.raw["n8n"]["objects"] if o["id"] != "fixture-runtime"
        ]
        self.assertEqual(self.resolve("workflow").decision, "inconsistent")

    def test_unpublished_binding_does_not_establish_readiness(self):
        self.raw["n8n"]["objects"][-1]["published"] = False
        self.assertNotEqual(self.resolve("workflow").decision, "ready")

    def test_unavailable_source_cannot_assert_missing_objects(self):
        self.raw["n8n"] = {
            "source": "n8n",
            "status": "unavailable",
            "complete": False,
            "errorCode": "source_unavailable",
        }
        result = self.resolve("migration")
        self.assertEqual(result.decision, "unavailable")
        self.assertFalse(
            any(d["code"] == "missing_credential" for d in self.build().discrepancies)
        )

    def test_old_and_future_observations_block_ready(self):
        for delta in [-61, 5]:
            self.raw["platform"]["observedAt"] = (
                datetime.now(UTC) + timedelta(seconds=delta)
            ).isoformat()
            self.assertEqual(self.resolve("migration").decision, "unavailable")

    def test_pending_and_stale_profiles_require_recovery(self):
        for status in ["pending", "stale", "unbound", "unsafe"]:
            self.profile = ProfileMetadata(status)
            self.assertEqual(
                self.resolve("application", application="interview").decision, "recovery_required"
            )
        self.profile = ProfileMetadata("missing")
        self.assertEqual(
            self.resolve("application", application="interview").decision, "setup_required"
        )

    def test_awaiting_grants_nologin_is_legitimate(self):
        source = next(o for o in self.raw["platform"]["objects"] if o["kind"] == "source")
        source.update(
            state="awaiting_grants",
            sourceId=None,
            baseId=None,
            integrationId=None,
            credentialGeneration=0,
        )
        role = next(
            o
            for o in self.raw["platform"]["objects"]
            if o.get("role") == "sample_reader" and o["kind"] == "role"
        )
        role["login"] = False
        result = self.resolve("source", pair="default", access_kind="reader")
        self.assertEqual(result.decision, "setup_required")
        self.assertFalse(any(d["code"] == "missing_source" for d in self.build().discrepancies))

    def test_cross_pair_assignment_is_inconsistent(self):
        source = copy.deepcopy(
            next(o for o in self.raw["platform"]["objects"] if o["kind"] == "source")
        )
        source.update(
            id="sample:extra:reader",
            pair="extra",
            role="nocodb_c5a3aa32680d2c32c1c6f8aa8661f6e7_reader",
        )
        self.raw["platform"]["objects"].append(source)
        self.assertEqual(
            self.resolve("source", pair="default", access_kind="reader").decision, "inconsistent"
        )
        self.assertIn("duplicate_assignment", {d["code"] for d in self.build().discrepancies})

    def test_intrinsic_and_unclassified_objects_are_not_adopted(self):
        self.raw["nocodb"]["objects"].append(
            {
                "kind": "source",
                "id": "fixture-intrinsic",
                "baseId": "fixture-base",
                "workspaceId": "fixture-workspace",
                "integrationId": None,
                "dataEditAllowed": True,
                "schemaEditAllowed": True,
                "enabled": True,
                "deleted": False,
                "intrinsic": True,
                "updatedAt": datetime.now(UTC).isoformat(),
            }
        )
        self.raw["platform"]["objects"].append(
            {
                "kind": "role",
                "id": "unregistered_fixture",
                "role": "unregistered_fixture",
                "login": False,
            }
        )
        result = self.build()
        self.assertTrue(any(item.get("classification") == "intrinsic" for item in result.items))
        self.assertTrue(any(item.get("classification") == "unclassified" for item in result.items))
        self.assertFalse(result.discrepancies)

    def test_uncertain_claim_blocks_source(self):
        self.raw["platform"]["objects"].append(
            {
                "kind": "claim",
                "id": "sample:default",
                "domain": "sample",
                "pair": "default",
                "operationId": "fixture-operation",
                "operation": "rotate",
                "accessKind": "reader",
                "generation": 4,
                "phase": "sql_applied",
            }
        )
        self.assertNotEqual(
            self.resolve("source", pair="default", access_kind="reader").decision, "ready"
        )

    def test_completed_observational_sync_claim_does_not_change_source_generation(self):
        self.raw["platform"]["objects"].append(
            {
                "kind": "claim",
                "id": "sample:default",
                "domain": "sample",
                "pair": "default",
                "operationId": "fixture-new-sync",
                "operation": "sync",
                "accessKind": None,
                "generation": 20,
                "phase": "complete",
            }
        )
        # A repeated successful sync obtains a new operation claim while preserving
        # current source and credential generations when no source mutation is needed.
        result = self.resolve("source", pair="default", access_kind="reader")
        self.assertEqual(result.decision, "ready")
        self.assertEqual(result.identity["operationGeneration"], 3)
        self.assertEqual(result.identity["credentialGeneration"], 2)
        self.assertEqual(result.identity["evidence"]["claim"]["generation"], 20)

    def test_builtin_default_mapping_is_distinct_from_registered_custom_mapping(self):
        self.raw["platform"]["objects"] = [
            o for o in self.raw["platform"]["objects"] if o["kind"] != "mapping"
        ]
        result = self.resolve("source", access_kind="reader")
        self.assertEqual(result.decision, "ready")
        self.assertEqual(result.identity["mappingOrigin"], "built_in_default")
        self.assertEqual(result.identity["evidence"]["mapping"]["readerSchema"], "read_model")
        row = next(o for o in self.raw["platform"]["objects"] if o["kind"] == "source")
        row.update(
            id="sample:extra:reader",
            pair="extra",
            role="nocodb_c5a3aa32680d2c32c1c6f8aa8661f6e7_reader",
        )
        self.assertNotEqual(
            self.resolve("source", pair="extra", access_kind="reader").decision, "ready"
        )

    def test_incomplete_role_attributes_cannot_produce_ready(self):
        role = next(
            o
            for o in self.raw["platform"]["objects"]
            if o["kind"] == "role" and o["role"] == APP_ROLE
        )
        del role["superuser"]
        self.assertNotEqual(self.resolve("application", application="interview").decision, "ready")

    def test_wrong_registered_identity_and_excess_role_attributes_block_ready(self):
        for field, value in [("role", "sample_migrator"), ("domain", "other")]:
            self.raw = fixtures()
            app = next(o for o in self.raw["platform"]["objects"] if o["kind"] == "application")
            app[field] = value
            self.assertNotEqual(
                self.resolve("application", application="interview").decision, "ready"
            )
        self.raw = fixtures()
        role = next(o for o in self.raw["platform"]["objects"] if o["id"] == APP_ROLE)
        role["inherit"] = True
        self.assertEqual(
            self.resolve("application", application="interview").decision, "inconsistent"
        )

    def test_conflicting_node_binding_blocks_affected_credentials(self):
        conflicting = copy.deepcopy(self.raw["n8n"]["objects"][-1])
        conflicting.update(id="fixture-alias", credentialId="fixture-migrator")
        self.raw["n8n"]["objects"].append(conflicting)
        self.assertEqual(self.resolve("workflow").decision, "inconsistent")
        self.assertEqual(self.resolve("migration").decision, "inconsistent")

    def test_absent_retained_identity_is_unknown_not_proof_of_absence(self):
        domain = next(o for o in self.raw["platform"]["objects"] if o["kind"] == "domain")
        domain["migratorCredentialId"] = None
        result = self.resolve("migration")
        self.assertEqual(result.decision, "unavailable")
        self.assertFalse(
            any(d["code"] == "missing_credential" for d in result.identity["discrepancies"])
        )

    def test_missing_workspace_and_mapping_facts_cannot_produce_ready(self):
        for kind, field in [("base", "workspaceId"), ("mapping", "readerSchema")]:
            self.raw = fixtures()
            source = "nocodb" if kind == "base" else "platform"
            row = next(o for o in self.raw[source]["objects"] if o["kind"] == kind)
            row[field] = None
            self.assertNotEqual(self.resolve("source", access_kind="reader").decision, "ready")

    def test_text_preserves_every_versioned_fact(self):
        # Text is a readable rendering of the same versioned data, including evidence.
        for result in [self.build(), self.resolve("migration")]:
            text = inventory_api.render_result(result, "text")
            wire = json.loads(inventory_api.render_result(result, "json"))
            self.assertEqual(json.loads(text[text.index("{") :]), wire)

    def test_recipe_forwards_literal_arguments_without_shell_interpretation(self):
        marker = ROOT / ".tmp/discovery-argv-must-not-execute"
        self.assertFalse(marker.exists())
        result = subprocess.run(
            [
                "mise",
                "exec",
                "--",
                "just",
                "kube",
                "automation-data-credentials",
                "resolve",
                f"sample; touch {marker}",
                "migration",
                "--format=json",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertFalse(marker.exists())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout), {"schemaVersion": 1, "errorCode": "invalid_arguments"}
        )

    def test_cli_json_text_and_exit_codes(self):
        path = ROOT / "scripts/operations/automation-data-credentials.py"
        self.assertTrue(path.exists(), "Task discovery command implementation missing")
        spec = importlib.util.spec_from_file_location("discovery_command", path)
        command = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(command)
        observed = [validate_observation(raw, source) for source, raw in self.raw.items()]

        def invoke(arguments):
            output = io.StringIO()
            with (
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(io.StringIO()),
                patch.object(command, "load_access_config", return_value=object()),
                patch.object(command, "fetch_observations", return_value=observed),
                patch.object(command, "inspect_profile", return_value=self.profile),
            ):
                status = command.main(arguments)
            return status, output.getvalue()

        for purpose, extra in [
            ("application", ["--application", "interview"]),
            ("migration", []),
            ("workflow", []),
            ("source", ["--pair", "default", "--access-kind", "reader"]),
        ]:
            status, text = invoke(["resolve", "sample", purpose, *extra])
            self.assertEqual(status, 0)
            self.assertIn("ready", text)
            status, text = invoke(["resolve", "sample", purpose, *extra, "--format=json"])
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(text)["resolution"]["decision"], "ready")
        self.assertEqual(invoke(["list", "--domain", "sample"])[0], 0)
        for args in [
            ["resolve", "sample", "application"],
            ["list", "--purpose", "migration"],
            ["resolve", "sample", "migration", "--pair", "extra"],
            ["resolve", "sample", "source", "--access-kind", "SENTINEL_SECRET"],
            ["list", "--domain", "../sample"],
        ]:
            status, text = invoke([*args, "--format=json"])
            self.assertEqual(status, 2)
            self.assertNotIn("SENTINEL_SECRET", text)
        self.profile = ProfileMetadata("missing")
        self.assertEqual(invoke(["resolve", "sample", "migration"])[0], 1)


if __name__ == "__main__":
    unittest.main()
