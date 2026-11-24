"""Specification 036 session runner: one command, one short-lived database login."""

import contextlib
import io
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from scripts.openbao import database_session as session
from scripts.openbao.client import AmbiguousWrite, ReadFailure

ENTITY = "entity-1"
PASSWORD = "synthetic-pass:wo\\rd-sentinel"
USERNAME = "v-career-ops-read-abcdefghij0123456789"
CAP_ROLE = "cap_" + __import__("hashlib").md5(b"career_ops:read").hexdigest() + "_access"


class FakeBao:
    def __init__(self, test):
        self.test = test
        self.calls = []
        self.token_entity = ENTITY
        self.lease_failure = False
        self.revoke_failure = set()
        self.token_lease = 600
        self.lease = 600
        self.login_status = None
        self.signal_on_revoke = set()

    def post(self, path, payload, *, token=None):
        self.calls.append(("POST", path, payload, token))
        if path == "auth/homelab-approle/login" and self.login_status:
            raise AmbiguousWrite(http_status=self.login_status)
        if path == "auth/homelab-approle/login":
            return {
                "auth": {
                    "client_token": "login-token",
                    "entity_id": ENTITY,
                    "policies": ["agent-profiles"],
                    "token_policies": ["agent-profiles"],
                    "identity_policies": None,
                    "lease_duration": 60,
                    "token_type": "service",
                }
            }
        if path == "auth/token/create/db-career-ops-read-agent-workstation":
            self.test.assertEqual(token, "login-token")
            self.test.assertEqual(payload, {"entity_alias": "agent-workstation"})
            return {
                "auth": {
                    "client_token": "session-token",
                    "entity_id": self.token_entity,
                    "policies": ["db-career-ops-read"],
                    "token_policies": ["db-career-ops-read"],
                    "identity_policies": None,
                    "lease_duration": self.token_lease,
                    "renewable": False,
                    "orphan": True,
                    "token_type": "service",
                }
            }
        if path == "auth/token/revoke-self":
            if token in self.signal_on_revoke:
                self.signal_on_revoke.discard(token)
                os.kill(os.getpid(), signal.SIGTERM)
            if token in self.revoke_failure:
                raise AmbiguousWrite()
            return {}
        raise AssertionError(path)

    def read(self, path, *, token=None):
        self.calls.append(("GET", path, None, token))
        self.test.assertEqual(path, "automation-data/creds/career-ops-read")
        self.test.assertEqual(token, "session-token")
        if self.lease_failure:
            raise ReadFailure("invalid-response")
        return {
            "lease_id": "automation-data/creds/career-ops-read/lease-1",
            "lease_duration": self.lease,
            "renewable": True,
            "data": {"username": USERNAME, "password": PASSWORD},
        }

    def revoked(self):
        return [c[3] for c in self.calls if c[1] == "auth/token/revoke-self"]


class FakeTunnel:
    def __init__(self, runtime):
        self.runtime = runtime
        self.port = 54321
        self.pid = 4001
        self.lost_at = None
        self.closed = False

    def alive(self):
        return self.lost_at is None or self.runtime.now < self.lost_at

    def close(self):
        if self.runtime.tunnel_close_failure:
            raise OSError("synthetic")
        self.closed = True


class FakeChild:
    def __init__(self, runtime, command, env):
        self.runtime = runtime
        self.command = command
        self.env = env
        self.pid = 5001
        self.returncode = None
        self.exit_at = runtime.child_exit_at
        self.code = runtime.child_code

    def poll(self):
        if (
            self.returncode is None
            and self.exit_at is not None
            and self.runtime.now >= self.exit_at
        ):
            self.returncode = self.code
        return self.returncode

    def wait(self, timeout=None):
        if self.poll() is not None:
            return self.returncode
        if self.runtime.on_wait:
            self.runtime.on_wait()
        self.runtime.now += timeout
        if self.poll() is not None:
            return self.returncode
        raise subprocess.TimeoutExpired(self.command, timeout)


class FakeRuntime(session.Runtime):
    def __init__(self, test, root):
        self.test = test
        self.session_root = root / "sessions"
        self.repo_root = root / "repo"
        self.now = 1000.0
        self.wall = 1_800_000_000.0
        self.bao = FakeBao(test)
        self.enrollment_failure = False
        self.identity_failure = None
        self.tunnel_failure = False
        self.tunnel_close_failure = False
        self.child_exit_at = 1010.0
        self.child_code = 3
        self.on_wait = None
        self.tunnel_obj = None
        self.child = None
        self.stopped = []
        self.identity_checks = []
        self.removed_kubeconfigs = []
        self.files_at_spawn = None

    def monotonic(self):
        return self.now

    def time(self):
        return self.wall + (self.now - 1000.0)

    def load_workstation(self):
        if self.enrollment_failure:
            raise session.SafeError("authentication-failed")
        return {"role_id": "role", "secret_id": "secret", "entity_id": ENTITY}

    def client(self):
        return self.bao

    def kubeconfig(self, run_id):
        path = self.repo_root / ".kube/invocations" / ("0" * 32) / "config"
        return path

    def remove_kubeconfig(self, path):
        self.removed_kubeconfigs.append(path)

    def tunnel(self, kubeconfig):
        if self.tunnel_failure:
            raise session.SessionError("connection_unavailable")
        self.tunnel_obj = FakeTunnel(self)
        return self.tunnel_obj

    def check_identity(self, port, capability, username, password):
        self.identity_checks.append((port, capability.domain, username, password))
        if self.identity_failure:
            raise session.SessionError(self.identity_failure)

    def spawn(self, command, env):
        directory = Path(env["PGSERVICEFILE"]).parent
        self.files_at_spawn = {
            p.name: (stat.S_IMODE(p.lstat().st_mode), p.read_text()) for p in directory.iterdir()
        }
        self.child = FakeChild(self, command, env)
        return self.child

    def start_time(self, pid):
        return "start-" + str(pid)

    def stop_group(self, process):
        self.stopped.append(process.pid)
        process.returncode = -15


def run(runtime, argv):
    err = io.StringIO()
    out = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
        code = session.run(argv, runtime)
    return code, err.getvalue() + out.getvalue()


ARGV = ["career_ops", "read", "--", "tool", "two words", "", "$HOME;`x`"]


class ArgumentTests(unittest.TestCase):
    def test_command_arguments_keep_their_boundaries(self):
        request = session.parse(["career_ops", "read", "--timeout", "60", "--", "a b", "", "--"])
        self.assertEqual(request.command, ["a b", "", "--"])
        self.assertEqual(request.timeout, 60)

    def test_refuses_malformed_requests(self):
        for argv in (
            [],
            ["career_ops", "read"],
            ["career_ops", "read", "--"],
            ["career_ops", "read", "tool"],
            ["Career", "read", "--", "x"],
            ["career_ops", "read;", "--", "x"],
            ["career_ops", "read", "--timeout", "0", "--", "x"],
            ["career_ops", "read", "--timeout", "601", "--", "x"],
            ["career_ops", "read", "--timeout", "1e2", "--", "x"],
            ["career_ops", "read", "--other", "--", "x"],
        ):
            with self.subTest(argv=argv), self.assertRaises(session.SessionError):
                session.parse(argv)

    def test_catalog_accepts_only_pairs_matching_the_openbao_roles(self):
        catalog = session.catalog()
        self.assertEqual(set(catalog), {("career_ops", "read")})
        entry = catalog[("career_ops", "read")]
        self.assertEqual(entry.database_role, "career-ops-read")
        self.assertEqual(entry.token_role, "db-career-ops-read-agent-workstation")
        self.assertEqual(entry.policy, "db-career-ops-read")
        self.assertEqual(entry.capability_role, CAP_ROLE)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.runtime = FakeRuntime(self, self.root)

    def assertNoSecret(self, output):
        for secret in (PASSWORD, "session-token", "login-token", "secret"):
            self.assertNotIn(secret, output)

    def test_child_runs_with_a_private_profile_and_scrubbed_environment(self):
        inherited = {
            "PGPASSWORD": "x",
            "PGHOST": "x",
            "PGSYSCONFDIR": "x",
            "KUBECONFIG": "x",
            "BAO_TOKEN": "x",
            "VAULT_TOKEN": "x",
            "KEEP_ME": "kept",
        }
        old = dict(os.environ)
        os.environ.update(inherited)
        try:
            code, output = run(self.runtime, ARGV)
        finally:
            os.environ.clear()
            os.environ.update(old)
        self.assertEqual(code, 3)
        child = self.runtime.child
        self.assertEqual(child.command, ["tool", "two words", "", "$HOME;`x`"])
        env = child.env
        self.assertEqual(env["KEEP_ME"], "kept")
        for name in (
            "PGPASSWORD",
            "PGHOST",
            "PGSYSCONFDIR",
            "KUBECONFIG",
            "BAO_TOKEN",
            "VAULT_TOKEN",
        ):
            self.assertNotIn(name, env)
        self.assertEqual(env["PGSERVICE"], "automation-data-session")
        self.assertEqual(env["AUTOMATION_DATA_SESSION_USER"], USERNAME)
        self.assertEqual(env["AUTOMATION_DATA_SESSION_EXPIRES_AT"], "2027-01-15T08:08:00Z")
        files = self.runtime.files_at_spawn
        self.assertEqual(
            {k: v[0] for k, v in files.items()},
            {"session.json": 0o600, "pg_service.conf": 0o600, "credential.pgpass": 0o600},
        )
        directory = Path(env["PGSERVICEFILE"]).parent
        self.assertEqual(directory.parent, self.runtime.session_root)
        self.assertEqual(
            files["pg_service.conf"][1],
            (
                "[automation-data-session]\nhost=127.0.0.1\nport=54321\ndbname=career_ops\n"
                f"user={USERNAME}\npassfile={directory / 'credential.pgpass'}\nconnect_timeout=10\n"
                "application_name=automation-data-session\nsslmode=disable\n"
            ),
        )
        self.assertEqual(
            files["credential.pgpass"][1],
            f"127.0.0.1:54321:career_ops:{USERNAME}:synthetic-pass\\:wo\\\\rd-sentinel\n",
        )
        record = json.loads(files["session.json"][1])
        self.assertEqual(record["username"], USERNAME)
        self.assertEqual(record["child"], None)
        self.assertEqual(record["tunnel"], {"pid": 4001, "start": "start-4001"})
        self.assertEqual(self.runtime.identity_checks, [(54321, "career_ops", USERNAME, PASSWORD)])
        # Cleanup: child already exited, tunnel closed, token revoked, files removed.
        self.assertTrue(self.runtime.tunnel_obj.closed)
        self.assertEqual(self.runtime.bao.revoked(), ["login-token", "session-token"])
        self.assertFalse(directory.exists())
        self.assertEqual(len(self.runtime.removed_kubeconfigs), 1)
        self.assertIn(f"user={USERNAME}", output)
        self.assertIn(
            "child_exit=3 child=exited tunnel=closed token=revoked kubeconfig=removed "
            "directory=removed",
            output,
        )
        self.assertNoSecret(output)

    def test_login_token_is_revoked_before_the_login_is_read(self):
        run(self.runtime, ARGV)
        paths = [(c[1], c[3]) for c in self.runtime.bao.calls]
        self.assertLess(
            paths.index(("auth/token/revoke-self", "login-token")),
            paths.index(("automation-data/creds/career-ops-read", "session-token")),
        )

    def test_deadline_stops_the_child_before_the_credential_expires(self):
        self.runtime.child_exit_at = None
        self.runtime.bao.lease = 400
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 124)
        self.assertEqual(self.runtime.stopped, [5001])
        # The lease, read after the token, ends first; the margin is 120 seconds.
        self.assertGreaterEqual(self.runtime.now, 1000 + 400 - 120)
        self.assertLess(self.runtime.now, 1000 + 400 - 120 + 2)
        self.assertIn("result=deadline", output)

    def test_timeout_only_shortens_the_deadline(self):
        self.runtime.child_exit_at = None
        code, _ = run(self.runtime, ["career_ops", "read", "--timeout", "30", "--", "tool"])
        self.assertEqual(code, 124)
        self.assertLess(self.runtime.now, 1000 + 32)
        runtime = FakeRuntime(self, self.root)
        runtime.child_exit_at = None
        code, _ = run(runtime, ["career_ops", "read", "--timeout", "600", "--", "tool"])
        self.assertEqual(code, 124)
        self.assertLess(runtime.now, 1000 + 600 - 120 + 2)

    def test_lost_tunnel_stops_the_child_without_reconnecting(self):
        self.runtime.child_exit_at = None
        self.runtime.on_wait = lambda: setattr(self.runtime.tunnel_obj, "lost_at", 1005.0)
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 69)
        self.assertEqual(self.runtime.stopped, [5001])
        self.assertIn("result=connection_lost", output)

    def test_identity_mismatch_revokes_tokens_and_fails_setup(self):
        self.runtime.bao.token_entity = "other-entity"
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 70)
        self.assertIsNone(self.runtime.tunnel_obj)
        self.assertEqual(self.runtime.bao.revoked(), ["login-token", "session-token"])
        self.assertIn("result=session_identity_mismatch", output)
        self.assertIn("token=revoked", output)
        self.assertEqual(list(self.runtime.session_root.iterdir()), [])

    def test_failed_login_read_revokes_the_session_token(self):
        self.runtime.bao.lease_failure = True
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 70)
        self.assertEqual(self.runtime.bao.revoked(), ["login-token", "session-token"])
        self.assertIn("result=issuance_unavailable", output)

    def test_missing_enrollment_fails_before_any_request(self):
        self.runtime.enrollment_failure = True
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 70)
        self.assertEqual(self.runtime.bao.calls, [])
        self.assertIn("result=enrollment_unavailable", output)
        self.assertIn("just kube openbao-workstation enroll", output)

    def test_refused_login_reports_the_reenrollment_prerequisite(self):
        for status, expected in (
            (400, "enrollment_unavailable"),
            (403, "enrollment_unavailable"),
            (503, "issuance_unavailable"),
            (None, "issuance_unavailable"),
        ):
            with self.subTest(status=status):
                runtime = FakeRuntime(self, self.root)
                runtime.bao.login_status = status or 599
                if status is None:
                    runtime.bao.login_status = None
                    runtime.bao.post = lambda *a, **k: (_ for _ in ()).throw(AmbiguousWrite())
                code, output = run(runtime, ARGV)
                self.assertEqual(code, 70)
                self.assertIn(f"result={expected}", output)
                self.assertIsNone(runtime.tunnel_obj)

    def test_failed_login_token_revocation_also_revokes_the_session_token(self):
        self.runtime.bao.revoke_failure = {"login-token"}
        code, output = run(self.runtime, ARGV)
        # Cleanup retries the login token, revokes the session token, and reports
        # the login token it could not revoke.
        self.assertEqual(code, 75)
        self.assertEqual(
            self.runtime.bao.revoked(), ["login-token", "login-token", "session-token"]
        )
        self.assertIn("result=issuance_unavailable", output)
        self.assertIn("token=failed", output)

    def test_signal_during_login_token_revocation_still_revokes_the_session_token(self):
        self.runtime.bao.signal_on_revoke = {"login-token"}
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 143)
        self.assertIn("session-token", self.runtime.bao.revoked())
        self.assertIn("result=interrupted", output)
        self.assertIn("token=revoked", output)

    def test_database_identity_check_failure_cleans_up(self):
        self.runtime.identity_failure = "identity_mismatch"
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 70)
        self.assertIsNone(self.runtime.child)
        self.assertTrue(self.runtime.tunnel_obj.closed)
        self.assertEqual(self.runtime.bao.revoked(), ["login-token", "session-token"])
        self.assertIn("result=identity_mismatch", output)

    def test_unknown_pair_fails_before_any_request(self):
        code, output = run(self.runtime, ["career_ops", "write", "--", "tool"])
        self.assertEqual(code, 70)
        self.assertEqual(self.runtime.bao.calls, [])
        self.assertIn("result=unknown_capability", output)

    def test_incomplete_cleanup_replaces_the_exit_code_and_runs_every_step(self):
        self.runtime.tunnel_close_failure = True
        self.runtime.bao.revoke_failure = {"session-token"}
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 75)
        self.assertIn("tunnel=failed token=failed kubeconfig=removed directory=kept", output)
        # The record stays for the tunnel process; the credential files do not.
        directory = Path(self.runtime.child.env["PGSERVICEFILE"]).parent
        self.assertEqual([p.name for p in directory.iterdir()], ["session.json"])
        # The login stays valid until its own expiry, after the runner's deadline.
        self.assertIn("revoke_failed=login expires by 2027-01-15T08:10:00Z", output)
        self.assertNoSecret(output)

    def test_signal_ends_the_session_with_cleanup(self):
        self.runtime.child_exit_at = None
        self.runtime.on_wait = lambda: os.kill(os.getpid(), signal.SIGTERM)
        previous = signal.getsignal(signal.SIGTERM)
        code, output = run(self.runtime, ARGV)
        self.assertEqual(code, 143)
        self.assertEqual(self.runtime.stopped, [5001])
        self.assertEqual(self.runtime.bao.revoked(), ["login-token", "session-token"])
        self.assertIn("result=interrupted", output)
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)


class StaleCleanupTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.runtime = session.Runtime()
        self.runtime.session_root = self.root / "sessions"
        self.runtime.session_root.mkdir(mode=0o700)
        (self.root / "repo").mkdir()
        self.removed = []
        self.runtime.remove_kubeconfig = lambda path, repo_root=None: self.removed.append(
            (path, repo_root)
        )
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()

    def sleeper(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True
        )
        self.processes.append(process)
        time.sleep(0.2)
        return process

    def dead_pid(self):
        process = subprocess.Popen([sys.executable, "-c", "pass"])
        process.wait()
        return process.pid

    def record(self, name, **changes):
        directory = self.runtime.session_root / name
        directory.mkdir(mode=0o700)
        value = {
            "schema_version": 1,
            "runner": {"pid": self.dead_pid(), "start": "Thu Jan  1 00:00:00 1970"},
            "repo_root": str(self.root / "repo"),
            "expires_at": time.time() - 1,
            "username": USERNAME,
            "kubeconfig": str(self.root / "repo/.kube/invocations" / ("a" * 32) / "config"),
            "tunnel": None,
            "child": None,
            **changes,
        }
        session.workstation.write_private(directory / "session.json", value)
        (directory / "credential.pgpass").write_text("x")
        os.chmod(directory / "credential.pgpass", 0o600)
        return directory

    def alive(self, process):
        return process.poll() is None

    def test_expired_session_of_an_exited_runner_is_stopped_and_removed(self):
        child, tunnel = self.sleeper(), self.sleeper()
        directory = self.record(
            "session-old",
            child={"pid": child.pid, "start": self.runtime.start_time(child.pid)},
            tunnel={"pid": tunnel.pid, "start": self.runtime.start_time(tunnel.pid)},
        )
        result = session.cleanup_stale(self.runtime)
        self.assertEqual(result, {"removed": 1, "kept": 0, "active": 0, "unrecognized": 0})
        child.wait(timeout=5)
        tunnel.wait(timeout=5)
        self.assertFalse(directory.exists())
        self.assertEqual(
            self.removed,
            [(self.root / "repo/.kube/invocations" / ("a" * 32) / "config", self.root / "repo")],
        )

    def test_unexpired_or_running_sessions_are_left_alone(self):
        child = self.sleeper()
        recorded = {"pid": child.pid, "start": self.runtime.start_time(child.pid)}
        self.record("session-fresh", child=recorded, expires_at=time.time() + 60)
        self.record(
            "session-running",
            child=recorded,
            runner={"pid": os.getpid(), "start": self.runtime.start_time(os.getpid())},
        )
        result = session.cleanup_stale(self.runtime)
        self.assertEqual(result, {"removed": 0, "kept": 0, "active": 2, "unrecognized": 0})
        self.assertTrue(self.alive(child))
        self.assertEqual(self.removed, [])

    def test_a_reused_process_id_is_never_signalled(self):
        other = self.sleeper()
        directory = self.record(
            "session-reused", child={"pid": other.pid, "start": "Mon Jan  1 00:00:00 2001"}
        )
        result = session.cleanup_stale(self.runtime)
        self.assertEqual(result["removed"], 1)
        self.assertTrue(self.alive(other))
        self.assertFalse(directory.exists())

    def test_unknown_contents_are_kept_and_reported(self):
        directory = self.record("session-extra")
        (directory / "notes.txt").write_text("x")
        link = self.runtime.session_root / "session-link"
        link.symlink_to(self.root)
        unsafe = self.runtime.session_root / "session-open"
        unsafe.mkdir(mode=0o755)
        result = session.cleanup_stale(self.runtime)
        self.assertEqual(result, {"removed": 0, "kept": 1, "active": 0, "unrecognized": 2})
        self.assertTrue((directory / "notes.txt").exists())
        self.assertFalse((directory / "credential.pgpass").exists())

    def test_cleanup_command_reports_counts(self):
        self.record("session-old")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            original = session.Runtime.session_root
            session.Runtime.session_root = self.runtime.session_root
            original_remove = session.Runtime.remove_kubeconfig
            session.Runtime.remove_kubeconfig = lambda self_, path, repo_root=None: None
            try:
                code = session.main(["cleanup"])
            finally:
                session.Runtime.session_root = original
                session.Runtime.remove_kubeconfig = original_remove
        self.assertEqual(code, 0)
        self.assertEqual(
            err.getvalue().strip(),
            "automation-data-session-cleanup: removed=1 kept=0 active=0 unrecognized=0",
        )


class AssignedForwardTests(unittest.TestCase):
    def forward(self, script):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        kubectl = Path(temp.name) / "kubectl"
        kubectl.write_text("#!/bin/sh\n" + script)
        kubectl.chmod(0o755)
        session._lib()
        import automation_data_client as client

        old = os.environ["PATH"]
        os.environ["PATH"] = temp.name + os.pathsep + old
        try:
            return client, client.start_assigned_forward(Path(temp.name) / "config")
        finally:
            os.environ["PATH"] = old

    def test_reads_the_port_kubectl_assigned_and_keeps_draining_output(self):
        client, (process, port) = self.forward(
            'case "$*" in *" :5432"*) ;; *) exit 9 ;; esac\n'
            'echo "Forwarding from 127.0.0.1:43210 -> 5432"\n'
            'i=0; while [ $i -lt 4000 ]; do echo "Handling connection for 43210"; i=$((i+1)); done\n'
            "echo done >&2; exec sleep 30\n"
        )
        try:
            self.assertEqual(port, 43210)
            time.sleep(0.5)
            self.assertIsNone(process.poll())
        finally:
            client.stop_fixed_forward(process)

    def test_a_signal_during_start_up_is_not_turned_into_a_tunnel_failure(self):
        class Stop(BaseException):
            pass

        def handler(signum, frame):
            raise Stop()

        previous = signal.signal(signal.SIGUSR1, handler)
        timer = __import__("threading").Timer(0.5, os.kill, (os.getpid(), signal.SIGUSR1))
        timer.start()
        try:
            with self.assertRaises(Stop):
                self.forward("exec sleep 30\n")
        finally:
            timer.cancel()
            signal.signal(signal.SIGUSR1, previous)

    def test_refuses_output_without_a_usable_port(self):
        for line in (
            "Forwarding from 127.0.0.1:80 -> 5432",
            "Forwarding from 0.0.0.0:43210 -> 5432",
        ):
            with self.subTest(line=line):
                session._lib()
                import automation_data_client as client

                with self.assertRaises(client.PrivateTunnelUnavailable):
                    self.forward(f'echo "{line}"; sleep 1\n')


class TunnelLivenessTests(unittest.TestCase):
    class Unavailable(Exception):
        pass

    def tunnel(self, outcome):
        test = self

        class Client:
            PrivateTunnelUnavailable = test.Unavailable

            @staticmethod
            def read_fixed_pod(config):
                if isinstance(outcome, str) and outcome.startswith("raise:"):
                    raise test.Unavailable(outcome[6:])
                return outcome

        tunnel = session.Tunnel.__new__(session.Tunnel)
        tunnel._client = Client
        tunnel.config = Path("config")
        tunnel.uid = "uid-1"
        tunnel.process = type("P", (), {"poll": staticmethod(lambda: None)})()
        tunnel._checked = 0
        return tunnel

    def test_only_a_definite_pod_change_ends_the_tunnel(self):
        # A failed check (OpenBao or the API unreachable) is unknown, not lost.
        self.assertTrue(self.tunnel("raise:scoped_kubectl_failed").alive())
        self.assertTrue(self.tunnel("uid-1").alive())
        self.assertFalse(self.tunnel("uid-2").alive())
        self.assertFalse(self.tunnel("raise:fixed_pod_not_ready").alive())


class ProcessGroupTests(unittest.TestCase):
    def test_stop_group_ends_the_child_and_its_descendants(self):
        child = session.Runtime().spawn(
            [
                sys.executable,
                "-c",
                (
                    "import subprocess,sys,time;"
                    "subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']);"
                    "time.sleep(60)"
                ),
            ],
            dict(os.environ),
        )
        time.sleep(0.5)
        self.assertEqual(os.getpgid(child.pid), child.pid)
        session.Runtime().stop_group(child)
        self.assertIsNotNone(child.poll())
        with self.assertRaises(ProcessLookupError):
            os.killpg(child.pid, 0)

    def test_start_time_identifies_a_live_process(self):
        runtime = session.Runtime()
        self.assertTrue(runtime.start_time(os.getpid()))
        self.assertEqual(runtime.start_time(os.getpid()), runtime.start_time(os.getpid()))
        self.assertIsNone(runtime.start_time(2**22 + 12345))


if __name__ == "__main__":
    unittest.main()
