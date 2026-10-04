"""Offline guards for the single attended profile acceptance scenario."""

import copy
import io
import json
import tempfile
import unittest
from contextlib import contextmanager, nullcontext, redirect_stdout
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
        directory_patch = patch.object(scenario, "ACCEPTANCE_DIRECTORY", self.directory)
        directory_patch.start()
        self.addCleanup(directory_patch.stop)
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

    def recovery_record(self):
        actor = self.scope.actor("a")
        actor["fields"] = copy.deepcopy(next(
            obj.fields for obj in scenario.load_document(scenario.apply.DESIRED)["objects"]
            if obj.kind == "approle-role"
        ))
        actor.update(role_id="synthetic-role", entity_id="synthetic-entity",
                     mount_accessor="synthetic-mount", disabled_at=999999999)
        self.scope.persist()
        return json.loads((self.scope.directory / "operator.json").read_text())

    def test_recovery_rebinds_source_but_never_cluster_or_run_owned_roles(self):
        record = self.recovery_record()
        current = {**self.approved, "source_revision": "b" * 40}
        recovered = scenario.load_recovery_scope(
            self.directory, "synthetic-run", self.scope.kubeconfig, self.client, current,
        )
        self.assertEqual(recovered.approved, current)
        self.assertEqual(recovered.actors[0]["role"], record["actors"][0]["role"])
        # A monotonic clock value from another process cannot shorten the barrier.
        self.assertNotIn("disabled_at", recovered.actors[0])
        for change in ("cluster", "run", "role", "path", "policy", "unexpected-field"):
            changed = copy.deepcopy(record)
            if change == "cluster":
                changed["target"]["cluster_uid"] = "foreign-cluster"
            elif change == "run":
                changed["run_id"] = "another-run"
            elif change == "role":
                changed["actors"][0]["role"] = "agent-workstation"
            elif change == "path":
                changed["actors"][0]["path"] = "auth/homelab-approle/role/agent-workstation"
            elif change == "policy":
                changed["actors"][0]["fields"]["token_policies"] = ["root"]
            else:
                changed["actors"][0]["directory"] = "/foreign"
            scenario.workstation.write_private(self.directory / "operator.json", changed)
            with self.subTest(change=change), self.assertRaises(scenario.SafeError):
                scenario.load_recovery_scope(
                    self.directory, "synthetic-run", self.scope.kubeconfig, self.client, current,
                )

    def test_cleanup_rejects_alias_without_recorded_or_live_role_binding(self):
        actor = self.scope.actor("a")
        self.client.read.return_value = {"data": {
            "name": actor["role"], "id": "synthetic-entity",
            "metadata": {"test_run": "synthetic-run"},
            "aliases": [{"id": "foreign-alias"}],
        }}
        with self.assertRaises(SafeError):
            self.scope.owned_entity(actor, allow_unbound=True)

    def test_recovered_cleanup_disables_destroys_waits_and_verifies_deletion(self):
        record = self.recovery_record()
        scope = scenario.load_recovery_scope(
            self.directory, "synthetic-run", self.scope.kubeconfig, self.client, self.approved,
        )
        actor = record["actors"][0]
        entity = {"id": "synthetic-entity", "name": actor["role"], "disabled": False,
                  "metadata": {"test_run": "synthetic-run"}, "aliases": [{
                      "id": "synthetic-alias", "name": "synthetic-role",
                      "mount_accessor": "synthetic-mount", "canonical_id": "synthetic-entity",
                  }]}
        state = {actor["path"]: actor["fields"],
                 actor["path"] + "/role-id": {"role_id": "synthetic-role"},
                 actor["path"] + "/secret-id": {"keys": ["synthetic-accessor"]},
                 "identity/entity/name/" + actor["role"]: entity,
                 "sys/auth": {"homelab-approle/": {"accessor": "synthetic-mount"}}}
        elapsed = [0]
        clock = Mock()
        clock.monotonic.side_effect = lambda: elapsed[0]
        clock.sleep.side_effect = lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)
        scope.clock = clock

        def read(path, **kwargs):
            if path not in state:
                raise scenario.NotFound()
            return {"data": copy.deepcopy(state[path])}

        def post(path, payload, **kwargs):
            if path == "identity/entity/id/synthetic-entity":
                self.assertEqual(payload, {"disabled": True})
                entity["disabled"] = True
            elif path == actor["path"] + "/secret-id-accessor/destroy":
                self.assertTrue(entity["disabled"])
                self.assertEqual(payload, {"secret_id_accessor": "synthetic-accessor"})
                state[actor["path"] + "/secret-id"]["keys"].clear()
            else:
                self.fail("Unexpected recovery mutation")

        def delete(path, **kwargs):
            self.assertGreaterEqual(elapsed[0], 90)
            self.assertTrue(entity["disabled"])
            self.assertEqual(state[actor["path"] + "/secret-id"]["keys"], [])
            if path == "identity/entity-alias/id/synthetic-alias":
                entity["aliases"].clear()
            elif path == "identity/entity/id/synthetic-entity":
                del state["identity/entity/name/" + actor["role"]]
            elif path == actor["path"]:
                del state[path]
            else:
                self.fail("Unexpected recovery deletion")

        self.client.read.side_effect = read
        self.client.post.side_effect = post
        self.client.delete.side_effect = delete
        with (patch.object(scenario.guards, "assert_mutation_allowed"),
              patch.object(scenario.workstation, "target", return_value=self.approved)):
            scope.cleanup()
        self.assertNotIn(actor["path"], state)
        self.assertNotIn("identity/entity/name/" + actor["role"], state)
        self.assertEqual(elapsed[0], 90)

    def test_recovery_keeps_journal_on_failure_and_removes_it_only_after_cleanup(self):
        owned = self.directory / "agent-synthetic"
        owned.mkdir(mode=0o700)
        self.scope.directory = owned
        self.scope.run_id = "20261001T000000Z-aaaaaaaaaaaa-operator-bbbbbbbb"
        self.recovery_record()
        config = self.directory / "operator"
        config.write_text("SYNTHETIC")
        for error in (RuntimeError("SECRET_MARKER"), None):
            output = io.StringIO()
            with (
                patch.object(scenario, "ACCEPTANCE_DIRECTORY", self.directory, create=True),
                patch.dict("os.environ", {"OPENBAO_OPERATOR_KUBECONFIG": str(config),
                                          "TEST_KUBECONFIG": str(config)}),
                patch.object(scenario.workstation, "target", return_value=self.approved),
                patch.object(scenario, "OperatorClient", return_value=self.client),
                patch.object(scenario, "private_prompt", side_effect=lambda text:
                    text.removeprefix("Exact confirmation ").removesuffix(": ")
                    if text.startswith("Exact confirmation ") else "SECRET_MARKER"),
                patch.object(scenario, "operator_password_session", return_value=nullcontext("SYN")),
                patch.object(scenario, "lease", return_value=nullcontext()),
                patch.object(scenario.BrokerScope, "cleanup", side_effect=error),
                patch.object(scenario, "install_interrupt_handlers"),
                redirect_stdout(output),
            ):
                self.assertEqual(scenario.recover(self.scope.run_id), 1 if error else 0)
            self.assertEqual(owned.exists(), bool(error))
            self.assertEqual(json.loads(output.getvalue())["status"], "fail" if error else "pass")
            self.assertNotIn("SECRET_MARKER", output.getvalue())

    def test_each_caller_requires_issuance_after_its_observed_expiry(self):
        events = self.directory / "events.jsonl"
        actor = {"directory": self.directory}
        records = [
            {"profile": "debugger", "issued_at": 100, "expires_at": 700},
            {"profile": "debugger", "issued_at": 699, "expires_at": 1299},
        ]
        events.write_text("\n".join(json.dumps(r) for r in records))
        with self.assertRaises(SafeError):
            scenario.assert_caller_refresh(actor, ["debugger"])
        records[1]["issued_at"] = 701
        events.write_text("\n".join(json.dumps(r) for r in records))
        scenario.assert_caller_refresh(actor, ["debugger"])
        with self.assertRaises(SafeError):
            scenario.assert_caller_refresh(actor, ["debugger", "report-publisher"])

    def test_lifetime_cannot_pass_when_watch_reconnection_fails(self):
        actor = {"directory": self.directory}
        actor["audit_configs"] = {str(self.directory): {"observer": self.directory / "selected-observer"}}
        diagnostics = {}

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
            scenario.lifetime_outage(self.directory, actor, diagnostics=diagnostics)
        self.assertEqual(calls, ["watch", "watch"])
        self.assertEqual(diagnostics["caller_stage"], "reconnect-callers")

    def test_scope_selection_requires_explicit_operator_context_and_run(self):
        with patch.dict("os.environ", {}, clear=True), self.assertRaises(SafeError):
            scenario.run_inputs()

    def test_new_acceptance_refuses_an_unrecovered_run_before_prompting(self):
        pending = self.directory / "agent-prior"
        pending.mkdir(mode=0o700)
        (pending / "operator.json").write_text("{}")
        output = io.StringIO()
        with (
            patch.object(scenario, "run_inputs", return_value=(self.directory / "config", self.directory)),
            patch.object(scenario.workstation, "target", return_value=self.approved),
            patch.object(scenario, "private_prompt", side_effect=AssertionError("must not prompt")),
            redirect_stdout(output),
        ):
            self.assertEqual(scenario.main(), 1)
        result = json.loads(output.getvalue())
        self.assertIs(result["recovery_required"], True)
        self.assertEqual(result["cleanup"], "not-required")

    def test_cleanup_error_does_not_replace_original_caller_failure(self):
        scope = Mock()
        scope.cleanup.side_effect = SafeError("source-mismatch")
        output = io.StringIO()

        @contextmanager
        def session(*args, **kwargs):
            yield "SYNTHETIC"

        with (
            patch.object(scenario, "run_inputs", return_value=(
                Path("/synthetic/operator"), self.directory,
            )),
            patch.object(scenario.workstation, "target", return_value=self.approved),
            patch.dict("os.environ", {"AGENT_CREDENTIALS_CONFIRM":
                f"agent-credentials:openbao:{'a' * 40}:{self.directory.name}"}),
            patch.object(scenario, "install_interrupt_handlers"),
            patch.object(scenario.workstation, "ensure_private_directory"),
            patch.object(scenario.tempfile, "mkdtemp", return_value=str(self.directory)),
            patch.object(scenario, "OperatorClient"),
            patch.object(scenario, "private_prompt", return_value="SYNTHETIC"),
            patch.object(scenario, "operator_password_session", side_effect=session),
            patch.object(scenario, "lease", side_effect=session),
            patch.object(scenario, "BrokerScope", return_value=scope),
            patch.object(scenario.apply, "verify_configuration", return_value={"differences": []}),
            patch.object(scenario.workstation, "cluster_metadata", return_value={}),
            patch.object(scenario.access, "prepare_profile_check", return_value=Path("/synthetic/coordinator")),
            patch.object(scenario.access, "remove_invocation"),
            patch.object(scenario, "prepare_actor_profiles"),
            patch.object(scenario, "fixtures", return_value=(self.directory, self.directory)),
            patch.object(scenario, "permissions"),
            patch.object(scenario, "kubectl"),
            patch.object(scenario, "lifetime_outage", side_effect=SafeError("timeout")),
            redirect_stdout(output),
        ):
            self.assertEqual(scenario.main(), 1)
        result = json.loads(output.getvalue())
        self.assertEqual(result["classification"], "timeout")
        self.assertEqual(result["cleanup_classification"], "source-mismatch")
        self.assertEqual(result["failure_stage"], "lifetime-outage")
        self.assertEqual(result["cleanup"], "failed")
        self.assertEqual(json.loads(
            (self.directory / "diagnostics/agent-credentials.json").read_text()
        ), result)

    def test_preflight_failure_retains_safe_reason_without_exception_text(self):
        for error, classification in (
            (SafeError("source-mismatch"), "source-mismatch"),
            (RuntimeError("SECRET_MARKER"), "invalid-response"),
        ):
            with self.subTest(classification=classification):
                output = io.StringIO()
                with (
                    patch.object(scenario, "run_inputs", return_value=(
                        Path("/synthetic/operator"), self.directory,
                    )),
                    patch.object(scenario.workstation, "target", side_effect=error),
                    redirect_stdout(output),
                ):
                    self.assertEqual(scenario.main(), 1)
                expected = {"status": "fail", "cleanup": "not-required",
                            "classification": classification}
                self.assertEqual(json.loads(output.getvalue()), expected)
                retained = (self.directory / "diagnostics/agent-credentials.json").read_text()
                self.assertEqual(json.loads(retained), expected)
                self.assertNotIn("SECRET_MARKER", output.getvalue() + retained)


if __name__ == "__main__":
    unittest.main()
