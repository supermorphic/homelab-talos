"""Exec credentials and checkout-local installation with synthetic authentication."""

import base64
import copy
import io
import json
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.openbao import credentials, guards, issuance, workstation
from scripts.openbao.client import AmbiguousWrite
from scripts.openbao.configuration import SafeError

NOW = 2000000000
ACCOUNTS = {
    "observer": "homelab-observer",
    "diagnostic": "homelab-diagnostic",
    "publisher": "homelab-report-publisher",
    "campaign-coordinator": "homelab-campaign-coordinator",
}


def jwt(account="homelab-observer", **changes):
    claims = {
        "sub": "system:serviceaccount:kube-system:" + account,
        "aud": [issuance.AUDIENCE],
        "iat": NOW,
        "exp": NOW + 600,
    }
    claims.update(changes)
    return (
        "synthetic."
        + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        + ".synthetic"
    )


def state():
    return {
        "role_id": "synthetic-role",
        "secret_id": "SECRET_MARKER",
        "entity_id": "synthetic-entity",
        "expires_at": NOW + 7776000,
        "cluster": {
            "schema_version": 1,
            "server": issuance.AUDIENCE,
            "certificate_authority_data": base64.b64encode(
                b"-----BEGIN CERTIFICATE-----\nsynthetic\n-----END CERTIFICATE-----"
            ).decode(),
            "openbao_server": workstation.ENDPOINT,
            "profiles": list(ACCOUNTS),
        },
    }


class Broker:
    def __init__(self):
        self.calls = []
        self.bad_auth = None
        self.bad_claims = {}
        self.fail_path = None
        self.extra_data = {}

    def post(self, path, payload, *, token=None):
        self.calls.append((path, copy.deepcopy(payload), token))
        if path == self.fail_path:
            raise AmbiguousWrite()
        if path == workstation.LOGIN_PATH:
            auth = {
                "client_token": "SESSION_MARKER",
                "entity_id": "synthetic-entity",
                "policies": ["agent-profiles"],
                "token_policies": ["agent-profiles"],
                "lease_duration": 60,
                "token_type": "service",
            }
            if self.bad_auth:
                auth.update(self.bad_auth)
            return {"auth": auth}
        if path == "auth/token/revoke-self":
            return {}
        profile = path.split("/")[-1]
        account = ACCOUNTS[profile]
        return {
            "data": {
                "service_account_name": account,
                "service_account_namespace": "kube-system",
                "service_account_token": jwt(account, **self.bad_claims),
                **self.extra_data,
            }
        }


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.broker = Broker()

    def issue(self, profile="observer"):
        return credentials.issue_exec_credential(profile, state(), client=self.broker, now=NOW)

    def test_all_profiles_use_one_session_then_return_actual_expiry(self):
        for profile, account in ACCOUNTS.items():
            self.broker = Broker()
            output = self.issue(profile)
            self.assertEqual(output["apiVersion"], "client.authentication.k8s.io/v1")
            self.assertEqual(output["kind"], "ExecCredential")
            self.assertEqual(output["status"]["expirationTimestamp"], "2033-05-18T03:43:20Z")
            self.assertEqual(output["status"]["token"], jwt(account))
            self.assertEqual(
                [c[0] for c in self.broker.calls],
                [workstation.LOGIN_PATH, "kubernetes/creds/" + profile, "auth/token/revoke-self"],
            )
            self.assertEqual(
                self.broker.calls[1][1], {"kubernetes_namespace": "kube-system", "ttl": 600}
            )

    def test_cli_failure_has_no_stdout_or_ambient_token_fallback(self):
        output, errors = io.StringIO(), io.StringIO()
        with (
            patch.dict(
                "os.environ", {"BAO_TOKEN": "SECRET_MARKER", "VAULT_TOKEN": "SECRET_MARKER"}
            ),
            patch("scripts.openbao.credentials.BaoClient") as client,
            redirect_stdout(output),
            redirect_stderr(errors),
        ):
            self.assertEqual(credentials.main(["credentials", "admin"]), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn("SECRET_MARKER", errors.getvalue())
        client.assert_not_called()

    def test_unknown_profile_never_authenticates(self):
        with self.assertRaises(SafeError):
            self.issue("admin")
        self.assertEqual(self.broker.calls, [])

    def test_unexpected_entity_policy_or_session_lifetime_is_cleaned_up(self):
        for changed in (
            {"entity_id": "wrong"},
            {"policies": ["root"]},
            {"identity_policies": ["root"]},
            {"lease_duration": 61},
            {"lease_duration": True},
        ):
            self.broker = Broker()
            self.broker.bad_auth = changed
            with self.assertRaises(SafeError):
                self.issue()
            self.assertEqual(
                [c[0] for c in self.broker.calls],
                [workstation.LOGIN_PATH, "auth/token/revoke-self"],
            )

    def test_wrong_token_account_audience_lifetime_or_expiry_is_rejected(self):
        for changed in (
            {"sub": "system:serviceaccount:kube-system:admin"},
            {"aud": ["wrong"]},
            {"exp": NOW + 601},
            {"exp": NOW},
            {"iat": NOW - 31},
        ):
            self.broker = Broker()
            self.broker.bad_claims = changed
            with self.assertRaises(SafeError):
                self.issue()
            self.assertEqual(self.broker.calls[-1][0], "auth/token/revoke-self")
        self.broker = Broker()
        self.broker.extra_data = {"service_account_name": "admin"}
        with self.assertRaises(SafeError):
            self.issue()

    def test_ambiguous_issuance_is_not_retried_and_cleanup_failure_returns_no_credential(self):
        for path in ("kubernetes/creds/observer", "auth/token/revoke-self"):
            self.broker = Broker()
            self.broker.fail_path = path
            with self.assertRaises(SafeError):
                self.issue()
            self.assertEqual(sum(c[0] == path for c in self.broker.calls), 1)

    def test_parallel_requests_have_no_shared_session_or_output_state(self):
        def invoke(_):
            broker = Broker()
            result = credentials.issue_exec_credential("observer", state(), client=broker, now=NOW)
            return result, broker.calls

        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(invoke, range(8)))
        self.assertTrue(all(len(calls) == 3 for _, calls in results))


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.auth = self.base / "auth"
        workstation.ensure_private_directory(self.auth)
        local = state()
        workstation.write_private(self.auth / "cluster.json", local["cluster"])
        auth = {k: v for k, v in local.items() if k != "cluster"}
        auth.update(schema_version=1, cluster_digest=guards.digest(local["cluster"]))
        workstation.write_private(self.auth / "workstation.json", auth)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        launcher = self.repo / "scripts/repository/kubernetes-credential.sh"
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/usr/bin/env bash\nexit 0\n")
        launcher.chmod(0o755)
        self.launcher = launcher
        self.clock = patch("scripts.openbao.credentials.time.time", return_value=NOW)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        directory = patch("scripts.openbao.workstation.DIRECTORY", self.auth)
        directory.start()
        self.addCleanup(directory.stop)

    def install(self, repo=None):
        return credentials.install_kubeconfig(repo or self.repo, self.auth)

    def test_installs_four_exec_contexts_without_reading_other_checkouts(self):
        path = self.install()
        config = yaml.safe_load(path.read_text())
        self.assertEqual(config["current-context"], "homelab-observer")
        self.assertEqual({c["name"] for c in config["contexts"]}, set(ACCOUNTS.values()))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        for user in config["users"]:
            self.assertEqual(set(user["user"]), {"exec"})
            spec = user["user"]["exec"]
            self.assertEqual(spec["command"], str(self.launcher))
            self.assertEqual(spec["interactiveMode"], "Never")
            self.assertNotIn("env", spec)
        credentials.validate_scoped_kubeconfig(path, self.repo)
        self.assertNotIn("SECRET_MARKER", path.read_text())
        self.assertNotIn("synthetic-role", path.read_text())

    def test_changed_kubeconfig_ca_fails_before_authentication(self):
        path = self.install()
        config = yaml.safe_load(path.read_text())
        config["clusters"][0]["cluster"]["certificate-authority-data"] = base64.b64encode(
            b"-----BEGIN CERTIFICATE-----\nstale-ca\n-----END CERTIFICATE-----"
        ).decode()
        path.write_text(json.dumps(config))
        output = io.StringIO()
        with (
            patch(
                "scripts.openbao.credentials.__file__",
                str(self.repo / "scripts/openbao/credentials.py"),
            ),
            patch.dict(
                "os.environ",
                {
                    "KUBERNETES_EXEC_INFO": json.dumps(
                        {
                            "apiVersion": credentials.API_VERSION,
                            "kind": "ExecCredential",
                            "spec": {"interactive": False},
                        }
                    )
                },
            ),
            patch("scripts.openbao.credentials.BaoClient") as broker,
            redirect_stdout(output),
            redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(credentials.main(["exec", "observer"]), 1)
        broker.assert_not_called()
        self.assertEqual(output.getvalue(), "")

    def test_primary_and_linked_checkout_have_independent_configs(self):
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "-c",
                "user.name=Synthetic",
                "-c",
                "user.email=synthetic@example.test",
                "commit",
                "--allow-empty",
                "-qm",
                "fixture",
            ],
            check=True,
        )
        linked = self.base / "linked"
        subprocess.run(
            ["git", "-C", str(self.repo), "worktree", "add", "-qb", "fixture", str(linked)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        launcher = linked / "scripts/repository/kubernetes-credential.sh"
        launcher.parent.mkdir(parents=True)
        launcher.write_bytes(self.launcher.read_bytes())
        launcher.chmod(0o755)
        paths = [self.install(), self.install(linked)]
        self.assertNotEqual(paths[0].read_bytes(), paths[1].read_bytes())
        for path, repo in zip(paths, (self.repo, linked), strict=True):
            credentials.validate_scoped_kubeconfig(path, repo)

    def test_recognized_legacy_config_can_be_replaced_without_token_backup(self):
        p = self.install()
        config = yaml.safe_load(p.read_text())
        config["contexts"] = config["contexts"][:3]
        config["users"] = [
            {"name": account, "user": {"token": jwt(account)}}
            for account in list(ACCOUNTS.values())[:3]
        ]
        p.write_text(yaml.safe_dump(config))
        self.install()
        credentials.validate_scoped_kubeconfig(p, self.repo)
        self.assertEqual([f.name for f in p.parent.iterdir()], ["config"])

    def test_admin_or_unknown_config_is_never_overwritten(self):
        directory = self.repo / ".kube"
        directory.mkdir(mode=0o700)
        p = directory / "config"
        p.write_text(
            json.dumps(
                {
                    "apiVersion": "v1",
                    "kind": "Config",
                    "users": [{"name": "admin", "user": {"client-key-data": "SYNTHETIC"}}],
                }
            )
        )
        p.chmod(0o600)
        before = p.read_bytes()
        with self.assertRaises(SafeError):
            self.install()
        self.assertEqual(p.read_bytes(), before)

    def test_config_and_directory_symlinks_are_rejected(self):
        p = self.install()
        saved = self.base / "saved"
        p.rename(saved)
        p.symlink_to(saved)
        with self.assertRaises(SafeError):
            self.install()
        p.unlink()
        (self.repo / ".kube").rmdir()
        (self.repo / ".kube").symlink_to(self.auth, target_is_directory=True)
        with self.assertRaises(SafeError):
            self.install()

    def test_moved_launcher_or_altered_exec_fails_closed(self):
        p = self.install()
        self.launcher.unlink()
        with self.assertRaises(SafeError):
            credentials.validate_scoped_kubeconfig(p, self.repo)
        self.launcher.write_text("#!/usr/bin/env bash\nexit 0\n")
        self.launcher.chmod(0o755)
        config = yaml.safe_load(p.read_text())
        config["users"][0]["user"]["exec"]["args"] += ["admin"]
        p.write_text(yaml.safe_dump(config))
        with self.assertRaises(SafeError):
            credentials.validate_scoped_kubeconfig(p, self.repo)

    def test_interrupted_install_preserves_previous_config(self):
        p = self.install()
        old = p.read_bytes()
        with (
            patch("scripts.openbao.credentials.os.replace", side_effect=OSError("SECRET_MARKER")),
            self.assertRaises(SafeError) as caught,
        ):
            self.install()
        self.assertNotIn("SECRET_MARKER", str(caught.exception))
        self.assertEqual(p.read_bytes(), old)

    def test_local_auth_rejects_expired_material_and_cluster_substitution(self):
        local = workstation.read_private(self.auth / "workstation.json")
        local["expires_at"] = NOW - 1
        workstation.write_private(self.auth / "workstation.json", local)
        with self.assertRaises(SafeError):
            credentials.load_workstation(self.auth)
        local["expires_at"] = NOW + 7776000
        workstation.write_private(self.auth / "workstation.json", local)
        cluster = workstation.read_private(self.auth / "cluster.json")
        cluster["openbao_server"] = "https://untrusted.example.test"
        workstation.write_private(self.auth / "cluster.json", cluster)
        with self.assertRaises(SafeError):
            credentials.load_workstation(self.auth)


if __name__ == "__main__":
    unittest.main()
