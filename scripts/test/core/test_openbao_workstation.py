"""Private workstation lifecycle, with independent identity/SecretID state."""

import copy
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import workstation
from scripts.openbao.configuration import SafeError


class IdentityClient:
    def __init__(self):
        self.role_id = "synthetic-role-id"
        self.accessor = "synthetic-mount"
        self.entity = None
        self.secrets = {}
        self.calls = []
        self.incomplete = False
        self.fail_destroy = False
        self.fail_login = False
        self.extra_policy = False
        self.serial = 0
        self.foreign_alias = False

    def read(self, path, *, token=None, list_request=False):
        self.calls.append(("read", path))
        if path == "sys/auth":
            return {"data": {"homelab-approle/": {"accessor": self.accessor}}}
        if path.endswith("/role-id"):
            return {"data": {"role_id": self.role_id}}
        if path.endswith("/secret-id"):
            if self.incomplete:
                return {"data": {"keys": list(self.secrets), "next_page": "synthetic-next"}}
            return {"data": {"keys": list(self.secrets)}}
        if path.startswith("identity/entity/"):
            if self.entity is None:
                from scripts.openbao.client import NotFound

                raise NotFound()
            return {"data": copy.deepcopy(self.entity)}
        raise AssertionError(path)

    def post(self, path, payload, *, token=None):
        if path == "identity/lookup/entity":
            self.calls.append(("lookup", path))
            if self.foreign_alias:
                return {"data": {"id": "foreign-entity"}}
            return {
                "data": copy.deepcopy(self.entity)
                if self.entity and self.entity["aliases"]
                else None
            }
        self.calls.append(("post", path, copy.deepcopy(payload)))
        if path == "identity/entity":
            self.entity = {
                "id": "synthetic-entity",
                "name": "agent-workstation",
                "disabled": False,
                "policies": [],
                "direct_group_ids": [],
                "inherited_group_ids": [],
                "group_ids": [],
                "aliases": [],
            }
            return {"data": {"id": self.entity["id"]}}
        if path == "identity/entity-alias":
            self.entity["aliases"] = [
                {
                    "name": payload["name"],
                    "mount_accessor": payload["mount_accessor"],
                    "canonical_id": payload["canonical_id"],
                }
            ]
            return {}
        if path.startswith("identity/entity/id/"):
            self.entity["disabled"] = payload["disabled"]
            return {}
        if path.endswith("/secret-id-accessor/destroy"):
            if self.fail_destroy:
                raise SafeError("ambiguous-write")
            self.secrets.pop(payload["secret_id_accessor"])
            return {}
        if path.endswith("/secret-id"):
            self.serial += 1
            key = f"synthetic-accessor-{self.serial}"
            value = f"SECRET_MARKER_{self.serial}"
            self.secrets[key] = value
            return {
                "data": {
                    "secret_id": value,
                    "secret_id_accessor": key,
                    "secret_id_ttl": 7776000,
                    "secret_id_num_uses": 0,
                }
            }
        if path == "auth/homelab-approle/login":
            if (
                self.fail_login
                or self.entity["disabled"]
                or payload["secret_id"] not in self.secrets.values()
            ):
                raise SafeError("authentication-failed")
            return {
                "auth": {
                    "client_token": "SESSION_MARKER",
                    "entity_id": self.entity["id"],
                    "policies": ["agent-profiles"],
                    "token_policies": ["agent-profiles"],
                    "identity_policies": ["unapproved"] if self.extra_policy else [],
                    "lease_duration": 60,
                    "token_type": "service",
                }
            }
        if path == "auth/token/revoke-self":
            return {}
        raise AssertionError(path)


class WorkstationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve() / "private"
        self.client = IdentityClient()
        self.now = 1000
        for target, value in (
            (
                "scripts.openbao.workstation.target",
                {"source_revision": "a" * 40, "cluster_uid": "synthetic-cluster"},
            ),
            ("scripts.openbao.apply.verify_configuration", {"differences": []}),
            ("scripts.openbao.guards.assert_mutation_allowed", None),
            (
                "scripts.openbao.workstation.cluster_metadata",
                {
                    "schema_version": 1,
                    "server": "https://cluster.example.test:6443",
                    "certificate_authority_data": "synthetic-ca",
                    "openbao_server": "https://openbao.lab.supermorphic.com",
                    "profiles": ["observer", "diagnostic", "publisher", "campaign-coordinator"],
                },
            ),
        ):
            p = patch(target, return_value=value)
            p.start()
            self.addCleanup(p.stop)

    def run_action(self, action, confirm=None):
        args = {
            "directory": self.directory,
            "client": self.client,
            "kubeconfig": Path("/operator"),
            "now": self.now,
        }
        plan = workstation.run(action, "agent-workstation", confirm="", **args)
        self.assertNotIn("SECRET_MARKER", str(plan))
        if confirm is False:
            return plan
        return workstation.run(action, "agent-workstation", confirm=plan["confirmation"], **args)

    def test_enroll_then_rotate_installs_validated_replacement(self):
        self.assertEqual(self.run_action("enroll")["status"], "pass")
        old = workstation.read_private(self.directory / "workstation.json")["secret_id"]
        self.assertEqual(len(self.client.secrets), 1)
        self.assertEqual(self.run_action("rotate")["status"], "pass")
        new = workstation.read_private(self.directory / "workstation.json")["secret_id"]
        self.assertNotEqual(old, new)
        self.assertNotIn(old, self.client.secrets.values())
        self.assertIn(new, self.client.secrets.values())
        self.assertEqual((self.directory.stat().st_mode & 0o777), 0o700)
        for p in self.directory.iterdir():
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_rotation_hands_creation_index_to_public_route_before_login(self):
        self.run_action("enroll")
        self.client.consistency_index = "synthetic-secret-index"
        client = self.client

        class PublicRoute:
            required_index = None

            def require_consistency(self, index):
                self.required_index = index

            def post(self, path, payload, *, token=None):
                if path == workstation.LOGIN_PATH and self.required_index != client.consistency_index:
                    raise SafeError("stale-state")
                return client.post(path, payload, token=token)

        self.client.workstation_client = PublicRoute()
        self.assertEqual(self.run_action("rotate")["status"], "pass")
        self.assertEqual(len(self.client.secrets), 1)

    def test_existing_foreign_role_alias_cannot_be_adopted(self):
        self.client.foreign_alias = True
        with self.assertRaises(SafeError):
            self.run_action("enroll")
        self.assertIsNone(self.client.entity)
        self.assertEqual(self.client.secrets, {})

    def test_confirmation_does_not_mutate_and_role_is_fixed(self):
        self.run_action("enroll", confirm=False)
        self.assertIsNone(self.client.entity)
        with self.assertRaises(SafeError):
            workstation.run(
                "enroll",
                "arbitrary",
                directory=self.directory,
                client=self.client,
                kubeconfig=Path("/operator"),
                confirm="",
            )

    def test_revocation_barrier_precedes_all_secret_destruction(self):
        self.run_action("enroll")
        self.client.calls.clear()
        self.assertEqual(self.run_action("revoke")["status"], "pass")
        self.assertTrue(self.client.entity["disabled"])
        self.assertEqual(self.client.secrets, {})
        self.assertFalse((self.directory / "workstation.json").exists())
        paths = [call[1] for call in self.client.calls if call[0] == "post"]
        self.assertLess(
            paths.index("identity/entity/id/synthetic-entity"),
            paths.index(workstation.ROLE_PATH + "/secret-id-accessor/destroy"),
        )

    def test_incomplete_list_or_destroy_never_reports_success(self):
        self.run_action("enroll")
        self.client.fail_destroy = True
        with self.assertRaises(SafeError):
            self.run_action("revoke")
        self.assertTrue(self.client.entity["disabled"])
        self.client.fail_destroy = False
        self.client.incomplete = True
        with self.assertRaises(SafeError):
            self.run_action("revoke")
        self.assertTrue(self.client.entity["disabled"])

    def test_failed_replacement_keeps_old_credential_and_recoverable_accessors(self):
        self.run_action("enroll")
        old = (self.directory / "workstation.json").read_bytes()
        self.client.extra_policy = True
        with self.assertRaises(SafeError):
            self.run_action("rotate")
        self.assertEqual((self.directory / "workstation.json").read_bytes(), old)
        self.assertEqual(
            len(workstation.read_private(self.directory / "operator.json")["accessors"]), 2
        )

    def test_entity_drift_and_wrong_alias_stop_before_mutation(self):
        self.run_action("enroll")
        for field, value in (
            ("policies", ["root"]),
            ("direct_group_ids", ["extra"]),
            ("aliases", [{"name": "wrong"}]),
        ):
            saved = copy.deepcopy(self.client.entity)
            self.client.entity[field] = value
            before = len([c for c in self.client.calls if c[0] == "post"])
            with self.assertRaises(SafeError):
                self.run_action("rotate")
            self.assertEqual(len([c for c in self.client.calls if c[0] == "post"]), before)
            self.client.entity = saved

    def test_private_files_reject_symlink_permissions_and_wrong_owner(self):
        workstation.ensure_private_directory(self.directory)
        p = self.directory / "state.json"
        workstation.write_private(p, {"secret": "SYNTHETIC"})
        p.chmod(0o644)
        with self.assertRaises(SafeError):
            workstation.read_private(p)
        p.chmod(0o600)
        with (
            patch("scripts.openbao.workstation.os.getuid", return_value=os.getuid() + 1),
            self.assertRaises(SafeError),
        ):
            workstation.read_private(p)
        link = self.directory / "link.json"
        link.symlink_to(p)
        with self.assertRaises(SafeError):
            workstation.read_private(link)
        with self.assertRaises(SafeError):
            workstation.write_private(link, {})

    def test_atomic_replacement_failure_preserves_old_file(self):
        workstation.ensure_private_directory(self.directory)
        p = self.directory / "state.json"
        workstation.write_private(p, {"secret": "OLD_SYNTHETIC"})
        with (
            patch("scripts.openbao.workstation.os.replace", side_effect=OSError("SECRET_MARKER")),
            self.assertRaises(SafeError) as caught,
        ):
            workstation.write_private(p, {"secret": "NEW_SYNTHETIC"})
        self.assertNotIn("SECRET_MARKER", str(caught.exception))
        self.assertEqual(workstation.read_private(p), {"secret": "OLD_SYNTHETIC"})

    def test_reenrollment_cannot_reenable_old_sessions(self):
        self.run_action("enroll")
        self.run_action("revoke")
        with self.assertRaises(SafeError):
            self.run_action("enroll")
        self.assertTrue(self.client.entity["disabled"])
        self.now += 91
        self.assertEqual(self.run_action("enroll")["status"], "pass")
        self.assertFalse(self.client.entity["disabled"])

    def test_lock_refuses_concurrent_lifecycle(self):
        workstation.ensure_private_directory(self.directory)
        with workstation.lifecycle_lock(self.directory), self.assertRaises(SafeError):
            self.run_action("enroll")


if __name__ == "__main__":
    unittest.main()
