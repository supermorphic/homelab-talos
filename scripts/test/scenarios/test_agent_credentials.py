"""Offline guards for the single attended profile acceptance scenario."""

import copy
import json
import tempfile
import unittest
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import Mock, patch

from scripts.openbao.configuration import SafeError
from scripts.test.scenarios import agent_credentials as scenario


class AcceptanceGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        self.client = Mock()
        self.client.token = "OPERATOR_MARKER"
        self.approved = {"source_revision": "a" * 40, "cluster_uid": "synthetic-cluster"}
        self.scope = scenario.BrokerScope(
            Path("/synthetic/operator"),
            "synthetic-run",
            self.directory,
            self.client,
            self.approved,
        )

    def test_only_run_owned_role_prefix_can_be_managed(self):
        actor = self.scope.actor("a")
        self.assertTrue(actor["role"].startswith("agent-acceptance-"))
        self.assertNotEqual(actor["role"], "agent-workstation")
        with self.assertRaises(SafeError):
            self.scope.actor("production")

    def test_cleanup_refuses_foreign_entity_without_mutation(self):
        actor = self.scope.actor("a")
        self.client.read.return_value = {
            "data": {"id": "foreign", "metadata": {"test_run": "other"}}
        }
        with self.assertRaises(SafeError):
            self.scope.owned_entity(actor)
        self.client.post.assert_not_called()
        self.client.delete.assert_not_called()

    def test_identity_mapping_and_disabled_barrier_are_verified(self):
        actor = self.scope.actor("a")
        actor.update(
            entity_id="synthetic-entity",
            role_id="synthetic-role",
            mount_accessor="synthetic-mount",
        )
        entity = {
            "id": actor["entity_id"],
            "name": actor["role"],
            "metadata": {"test_run": "synthetic-run"},
            "disabled": False,
            "policies": [],
            "group_ids": [],
            "direct_group_ids": [],
            "inherited_group_ids": [],
            "aliases": [
                {
                    "name": actor["role_id"],
                    "mount_accessor": actor["mount_accessor"],
                    "canonical_id": actor["entity_id"],
                }
            ],
        }
        self.client.read.return_value = {"data": entity}
        self.assertEqual(self.scope.owned_entity(actor), entity)
        for bad in ({"policies": ["root"]}, {"group_ids": ["unexpected"]}, {"aliases": []}):
            value = copy.deepcopy(entity)
            value.update(bad)
            self.client.read.return_value = {"data": value}
            with self.assertRaises(SafeError):
                self.scope.owned_entity(actor)

    def test_lost_lease_or_changed_target_blocks_broker_write(self):
        actor = self.scope.actor("a")
        for changed in (True, False):
            with (
                patch(
                    "scripts.openbao.guards.assert_mutation_allowed",
                    side_effect=SafeError("source-mismatch") if changed else None,
                ),
                patch(
                    "scripts.openbao.workstation.target",
                    return_value={**self.approved, "cluster_uid": "other"},
                ),
                self.assertRaises(SafeError),
            ):
                self.scope.post(actor["path"], {})
            self.client.post.assert_not_called()

    def test_outage_is_only_in_fixture_transport_and_never_stops_server(self):
        text = scenario.fixture_launcher()
        self.assertIn("AGENT_ACCEPTANCE_DIRECTORY", text)
        self.assertIn("outage", text)
        self.assertIn("credentials.main", text)
        self.assertNotIn("BAO_TOKEN", text)
        self.assertNotIn("delete pod", text)
        self.assertNotIn("insecure", text)

    def test_fixture_topology_never_installs_into_operator_checkout(self):
        with self.assertRaises(SafeError):
            scenario.check_fixture_root(scenario.guards.ROOT)
        with self.assertRaises(SafeError):
            scenario.check_fixture_root(scenario.guards.ROOT / ".tmp/fixture")

    def test_partial_accessor_inventory_cannot_complete_cleanup(self):
        actor = self.scope.actor("a")
        self.client.read.return_value = {
            "data": {"keys": ["synthetic-accessor"], "next_page": "more"}
        }
        with self.assertRaisesRegex(SafeError, "incomplete-list"):
            self.scope.destroy_ids(actor)
        self.client.post.assert_not_called()
        self.client.delete.assert_not_called()

    def test_disable_requires_independent_barrier_readback(self):
        actor = self.scope.actor("a")
        with (
            patch.object(
                self.scope,
                "owned_entity",
                return_value={"id": "synthetic-entity", "disabled": False},
            ),
            patch.object(self.scope, "post") as post,
            self.assertRaises(SafeError),
        ):
            self.scope.disable(actor)
        post.assert_called_once_with("identity/entity/id/synthetic-entity", {"disabled": True})
        self.assertNotIn("disabled_at", actor)

    def test_each_caller_requires_issuance_after_its_observed_expiry(self):
        events = self.directory / "events.jsonl"
        actor = {"directory": self.directory}
        records = [
            {"profile": "diagnostic", "issued_at": 100, "expires_at": 700},
            {"profile": "diagnostic", "issued_at": 699, "expires_at": 1299},
        ]
        events.write_text("\n".join(json.dumps(r) for r in records))
        with self.assertRaises(SafeError):
            scenario.assert_caller_refresh(actor, ["diagnostic"])
        records[1]["issued_at"] = 701
        events.write_text("\n".join(json.dumps(r) for r in records))
        scenario.assert_caller_refresh(actor, ["diagnostic"])
        with self.assertRaises(SafeError):
            scenario.assert_caller_refresh(actor, ["diagnostic", "publisher"])

    def test_lifetime_cannot_pass_when_watch_reconnection_fails(self):
        actor = {"directory": self.directory}

        @contextmanager
        def running(*args, **kwargs):
            yield Mock(poll=Mock(return_value=None))

        calls = []

        @contextmanager
        def watch(*args, **kwargs):
            calls.append("watch")
            if len(calls) == 2:
                raise SafeError("invalid-response")
            yield Mock(poll=Mock(return_value=None))

        with (
            patch.object(
                scenario.credentials,
                "load_workstation",
                return_value={
                    "cluster": {
                        "certificate_authority_data": "c3ludGhldGlj",
                        "server": "https://example.test",
                    }
                },
            ),
            patch.object(
                scenario.credentials,
                "issue_exec_credential",
                return_value={
                    "status": {
                        "token": "SYNTHETIC",
                        "expirationTimestamp": datetime.fromtimestamp(700, UTC).isoformat(),
                    }
                },
            ),
            patch.object(scenario.ssl, "create_default_context"),
            patch.object(scenario, "BaoClient"),
            patch.object(scenario, "process", side_effect=running),
            patch.object(scenario, "watch_connection", side_effect=watch, create=True),
            patch.object(scenario, "diagnostic_connection", side_effect=running, create=True),
            patch.object(scenario, "publisher_operations", create=True),
            patch.object(scenario, "coordinator_window", side_effect=running, create=True),
            patch.object(scenario, "assert_caller_refresh", create=True),
            patch.object(scenario, "read_url", side_effect=[200, 200, 0, 401, 200]),
            patch.object(scenario, "kubectl"),
            patch.object(scenario.time, "sleep"),
            patch.object(scenario.time, "time", return_value=2000),
            self.assertRaises(SafeError),
        ):
            scenario.lifetime_outage(self.directory, actor)
        self.assertEqual(calls, ["watch", "watch"])

    def test_scope_selection_requires_explicit_operator_context_and_run(self):
        with patch.dict("os.environ", {}, clear=True), self.assertRaises(SafeError):
            scenario.run_inputs()


if __name__ == "__main__":
    unittest.main()
