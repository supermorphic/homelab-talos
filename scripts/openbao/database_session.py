"""Specification 036 session runner: one command, one short-lived database login.

Tokens and the password stay in process memory and in the private session
directory. Output names only the login, its expiry, and each cleanup result.
"""

import contextlib
import hashlib
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from . import credentials, workstation
from .client import AmbiguousWrite, BaoClient
from .configuration import SafeError, load_document

ROOT = Path(__file__).resolve().parents[2]
SESSION_ROOT = Path.home() / ".local/state/homelab-talos/automation-data-sessions"
PURPOSE = "automation-data-session"
SERVICE = "automation-data-session"
MARGIN = 120
STOP_GRACE = 10
POLL = 1
POD_CHECK = 10
# A session directory exists before its login; this bounds its life until then.
PROVISIONAL = 900
DOMAIN = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
CAPABILITY = re.compile(r"^[a-z][a-z0-9_]{0,23}$")
USERNAME = re.compile(r"^v-[a-z0-9-]{1,40}-[a-z0-9]{20}$")
SCRUBBED = ("PG", "KUBECONFIG", "BAO_", "VAULT_")
EXIT_SETUP, EXIT_TUNNEL, EXIT_DEADLINE, EXIT_CLEANUP = 70, 69, 124, 75
ENROLL = "mise exec -- just kube openbao-workstation enroll agent-workstation"


class SessionError(Exception):
    """A sanitized failure code; never carries response or credential text."""


class Interrupted(BaseException):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


@dataclass(frozen=True)
class Request:
    domain: str
    capability: str
    timeout: int | None
    command: list


@dataclass(frozen=True)
class Capability:
    domain: str
    capability: str
    database_role: str
    token_role: str
    policy: str
    capability_role: str


def parse(argv):
    """<domain> <capability> [--timeout SECONDS] -- <command…>"""
    if "--" not in argv:
        raise SessionError("invalid_arguments")
    split = argv.index("--")
    head, command = argv[:split], argv[split + 1 :]
    timeout = None
    if len(head) == 4 and head[2] == "--timeout":
        if not re.fullmatch(r"[1-9][0-9]{0,2}", head[3]) or int(head[3]) > 600:
            raise SessionError("invalid_arguments")
        timeout = int(head[3])
    elif len(head) != 2:
        raise SessionError("invalid_arguments")
    if not DOMAIN.fullmatch(head[0]) or not CAPABILITY.fullmatch(head[1]) or not command:
        raise SessionError("invalid_arguments")
    return Request(head[0], head[1], timeout, list(command))


def catalog(desired=None):
    """Pairs whose database role, token role and policy match in desired.json."""
    from .apply import DESIRED

    objects = {(o.kind, o.name): o for o in load_document(desired or DESIRED)["objects"]}
    pairs = {}
    for (kind, name), obj in objects.items():
        if kind != "database-role":
            continue
        match = re.fullmatch(
            r"SELECT platform_operations\.issue_session_login\('\{\{name\}\}', "
            r"'\{\{password\}\}', '\{\{expiration\}\}', '([a-z][a-z0-9_]{0,47})', "
            r"'([a-z][a-z0-9_]{0,23})'\)",
            "".join(obj.fields.get("creation_statements", [])),
        )
        if not match or name != f"{match[1]}-{match[2]}".replace("_", "-"):
            continue
        token_role = objects.get(("token-role", f"db-{name}-{workstation.ROLE}"))
        if (
            token_role is None
            or token_role.fields.get("allowed_policies") != [f"db-{name}"]
            or token_role.fields.get("allowed_entity_aliases") != [workstation.ROLE]
            or ("policy", f"db-{name}") not in objects
        ):
            continue
        digest = hashlib.md5(f"{match[1]}:{match[2]}".encode(), usedforsecurity=False)
        pairs[(match[1], match[2])] = Capability(
            match[1],
            match[2],
            name,
            token_role.name,
            f"db-{name}",
            "cap_" + digest.hexdigest() + "_access",
        )
    return pairs


class Runtime:
    """Process, clock, OpenBao, Kubernetes and PostgreSQL access; replaced in tests."""

    session_root = SESSION_ROOT
    repo_root = ROOT

    def monotonic(self):
        return time.monotonic()

    def time(self):
        return time.time()

    def load_workstation(self):
        return credentials.load_workstation(workstation.DIRECTORY)

    def client(self):
        return BaoClient(workstation.ENDPOINT)

    def kubeconfig(self, run_id):
        from scripts.test import access

        return access.prepare_purpose_invocation(self.repo_root, PURPOSE, run_id)

    def remove_kubeconfig(self, path, repo_root=None):
        from scripts.test import access

        access.remove_invocation(self.repo_root if repo_root is None else repo_root, path)

    def tunnel(self, kubeconfig):
        return Tunnel(kubeconfig)

    def check_identity(self, port, capability, username, password):
        _lib()
        import psycopg
        from automation_data_client import clear_pg_environment

        try:
            with (
                clear_pg_environment(),
                psycopg.connect(
                    host="127.0.0.1",
                    port=port,
                    dbname=capability.domain,
                    user=username,
                    password=password,
                    connect_timeout=10,
                    sslmode="disable",
                    application_name=SERVICE,
                ) as connection,
                connection.cursor() as cursor,
            ):
                cursor.execute(
                    "SELECT session_user, current_database(), pg_has_role(session_user, %s, 'USAGE'),"
                    " pg_has_role(session_user, %s, 'SET'), current_setting('transaction_read_only')",
                    (capability.capability_role, capability.capability_role),
                )
                row = cursor.fetchone()
        except Exception:  # noqa: BLE001 -- Never render driver text; it can echo inputs.
            raise SessionError("connection_unavailable") from None
        # Every registered capability is read mode until `correct` exists.
        if row != (username, capability.domain, True, False, "on"):
            raise SessionError("identity_mismatch")

    def spawn(self, command, env):
        try:
            return subprocess.Popen(command, env=env, start_new_session=True)
        except OSError:
            raise SessionError("command_unavailable") from None

    def start_time(self, pid):
        """The process start time as ps reports it, or None when it is gone."""
        try:
            value = subprocess.run(
                ["ps", "-o", "lstart=", "-p", str(int(pid))],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
                env={"LC_ALL": "C", "PATH": "/bin:/usr/bin"},
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
        return value or None

    def stop_group(self, process):
        """SIGTERM the child's process group, then SIGKILL after the grace period."""
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=STOP_GRACE)
        except subprocess.TimeoutExpired:
            pass
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=STOP_GRACE)

    def stop_recorded(self, recorded, *, group):
        """Stop a recorded process only while its PID and start time still match."""
        pid, start = recorded["pid"], recorded["start"]

        def running():
            with contextlib.suppress(ChildProcessError):
                os.waitpid(pid, os.WNOHANG)
            return start is not None and self.start_time(pid) == start

        for signum in (signal.SIGTERM, signal.SIGKILL):
            if not running():
                return True
            with contextlib.suppress(ProcessLookupError):
                (os.killpg if group else os.kill)(pid, signum)
            deadline = time.monotonic() + STOP_GRACE
            while time.monotonic() < deadline and running():
                time.sleep(0.1)
        return not running()


def _lib():
    lib = str(ROOT / "scripts/lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)


class Tunnel:
    """kubectl port-forward to the fixed PostgreSQL Pod with the debugger profile."""

    def __init__(self, kubeconfig):
        _lib()
        import automation_data_client as client

        self._client = client
        try:
            self.config = client.scoped_kubeconfig(kubeconfig)
            client.assert_scoped_identity(self.config)
            client.assert_named_forward_allowed(self.config)
            self.uid = client.read_fixed_pod(self.config)
            self.process, self.port = client.start_assigned_forward(self.config)
        except client.PrivateTunnelUnavailable:
            raise SessionError("connection_unavailable") from None
        self.pid = self.process.pid
        self._checked = time.monotonic()

    def alive(self):
        if self.process.poll() is not None:
            return False
        if time.monotonic() - self._checked >= POD_CHECK:
            self._checked = time.monotonic()
            try:
                self._client.assert_pod_unchanged(self.config, self.uid)
            except self._client.PrivateTunnelUnavailable:
                return False
        return True

    def close(self):
        self._client.stop_fixed_forward(self.process)
        if self.process.poll() is None:
            raise SessionError("tunnel_close_failed")


def _iso(epoch):
    return datetime.fromtimestamp(epoch, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _pgpass(value):
    return value.replace("\\", "\\\\").replace(":", "\\:")


def _write(directory, name, text):
    fd = os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())


def _issue(client, state, capability, runtime):
    """Session token through the token role, then one login; returns the expiry."""
    try:
        login = client.post(
            workstation.LOGIN_PATH, {"role_id": state["role_id"], "secret_id": state["secret_id"]}
        )
    except AmbiguousWrite as error:
        # AppRole answers 400 for a destroyed SecretID and 403 for a disabled entity.
        if error.http_status in (400, 403):
            raise SessionError("enrollment_unavailable") from None
        raise SessionError("issuance_unavailable") from None
    except SafeError:
        raise SessionError("issuance_unavailable") from None
    auth = login.get("auth") if isinstance(login, dict) else None
    login_token = auth.get("client_token") if isinstance(auth, dict) else None
    if not isinstance(login_token, str) or not login_token:
        raise SessionError("issuance_unavailable")
    issued = {}
    try:
        try:
            workstation.validate_session(auth, state["entity_id"])
        except SafeError:
            raise SessionError("session_identity_mismatch") from None
        before = runtime.monotonic()
        try:
            created = client.post(
                f"auth/token/create/{capability.token_role}",
                {"entity_alias": workstation.ROLE},
                token=login_token,
            )
        except SafeError:
            raise SessionError("issuance_unavailable") from None
        token = created.get("auth") if isinstance(created, dict) else None
        if isinstance(token, dict) and isinstance(token.get("client_token"), str):
            issued["token"] = token["client_token"]
        if (
            not issued.get("token")
            or token.get("entity_id") != state["entity_id"]
            or token.get("policies") != [capability.policy]
            or token.get("token_policies") != [capability.policy]
            or token.get("identity_policies") not in (None, [])
            or token.get("orphan") is not True
            or token.get("renewable") is not False
            or token.get("token_type") != "service"
            or type(token.get("lease_duration")) is not int
            or not 0 < token["lease_duration"] <= 600
        ):
            if issued.get("token"):
                with contextlib.suppress(SafeError):
                    client.post("auth/token/revoke-self", {}, token=issued.pop("token"))
            raise SessionError("session_identity_mismatch")
        issued["token_expires"] = before + token["lease_duration"]
    finally:
        try:
            client.post("auth/token/revoke-self", {}, token=login_token)
        except SafeError:
            if issued.get("token"):
                with contextlib.suppress(SafeError):
                    client.post("auth/token/revoke-self", {}, token=issued.pop("token"))
            raise SessionError("issuance_unavailable") from None
    return issued


def _read_login(client, issued, capability, runtime):
    before = runtime.monotonic()
    try:
        lease = client.read(
            f"automation-data/creds/{capability.database_role}", token=issued["token"]
        )
    except SafeError:
        raise SessionError("issuance_unavailable") from None
    data = lease.get("data") if isinstance(lease, dict) else None
    if (
        not isinstance(data, dict)
        or not isinstance(lease.get("lease_id"), str)
        or not lease["lease_id"].startswith(f"automation-data/creds/{capability.database_role}/")
        or type(lease.get("lease_duration")) is not int
        or not 0 < lease["lease_duration"] <= 600
        or not isinstance(data.get("username"), str)
        or not USERNAME.fullmatch(data["username"])
        or not isinstance(data.get("password"), str)
        or not data["password"]
        or "\n" in data["password"]
    ):
        raise SessionError("issuance_unavailable")
    expires = min(issued["token_expires"], before + lease["lease_duration"])
    return data["username"], data["password"], expires


def _environment(directory, username, expires_at):
    env = {k: v for k, v in os.environ.items() if not k.startswith(SCRUBBED)}
    env.update(
        PGSERVICEFILE=str(directory / "pg_service.conf"),
        PGSERVICE=SERVICE,
        AUTOMATION_DATA_SESSION_USER=username,
        AUTOMATION_DATA_SESSION_EXPIRES_AT=expires_at,
    )
    return env


class _Signals:
    """Interrupt the session on SIGINT, SIGTERM or SIGHUP; only record them during cleanup."""

    HANDLED = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def __init__(self):
        self.received = None
        self.deferred = False

    def handle(self, signum, _frame):
        if self.deferred:
            self.received = self.received or signum
            return
        self.deferred = True
        raise Interrupted(signum)

    def defer(self):
        self.deferred = True

    def __enter__(self):
        self.previous = {s: signal.signal(s, self.handle) for s in self.HANDLED}
        return self

    def __exit__(self, *_):
        for s, handler in self.previous.items():
            signal.signal(s, handler)


class _Session:
    def __init__(self, runtime):
        self.runtime = runtime
        self.directory = None
        self.record = None
        self.client = None
        self.issued = {}
        self.kubeconfig = None
        self.tunnel = None
        self.child = None
        self.child_exit = None
        self.username = None
        self.expires_at = None

    def save(self, **changes):
        self.record.update(changes)
        workstation.write_private(self.directory / "session.json", self.record)

    def open_directory(self):
        root = self.runtime.session_root
        workstation.ensure_private_directory(root)
        self.directory = Path(tempfile.mkdtemp(prefix="session-", dir=root))
        os.chmod(self.directory, 0o700)
        self.record = {
            "schema_version": 1,
            "runner": {"pid": os.getpid(), "start": self.runtime.start_time(os.getpid())},
            "repo_root": str(self.runtime.repo_root),
            "expires_at": self.runtime.time() + PROVISIONAL,
            "username": None,
            "kubeconfig": None,
            "tunnel": None,
            "child": None,
        }
        self.save()

    def run(self, request, capability, state):
        runtime = self.runtime
        self.open_directory()
        self.client = runtime.client()
        self.issued = _issue(self.client, state, capability, runtime)
        username, password, expires = _read_login(self.client, self.issued, capability, runtime)
        offset = runtime.time() - runtime.monotonic()
        deadline = expires - MARGIN
        self.username = username
        self.expires_at = _iso(deadline + offset)
        self.save(username=username, expires_at=expires + offset)
        self.kubeconfig = runtime.kubeconfig(self.directory.name)
        self.save(kubeconfig=str(self.kubeconfig))
        self.tunnel = runtime.tunnel(self.kubeconfig)
        self.save(tunnel={"pid": self.tunnel.pid, "start": runtime.start_time(self.tunnel.pid)})
        port = self.tunnel.port
        _write(
            self.directory,
            "credential.pgpass",
            ":".join(["127.0.0.1", str(port), capability.domain, username, _pgpass(password)])
            + "\n",
        )
        _write(
            self.directory,
            "pg_service.conf",
            "".join(
                f"{line}\n"
                for line in [
                    f"[{SERVICE}]",
                    "host=127.0.0.1",
                    f"port={port}",
                    f"dbname={capability.domain}",
                    f"user={username}",
                    f"passfile={self.directory / 'credential.pgpass'}",
                    "connect_timeout=10",
                    f"application_name={SERVICE}",
                    "sslmode=disable",
                ]
            ),
        )
        runtime.check_identity(port, capability, username, password)
        del password
        if runtime.monotonic() >= deadline:
            raise SessionError("issuance_unavailable")
        env = _environment(self.directory, username, self.expires_at)
        self.child = runtime.spawn(request.command, env)
        self.save(child={"pid": self.child.pid, "start": runtime.start_time(self.child.pid)})
        if request.timeout is not None:
            deadline = min(deadline, runtime.monotonic() + request.timeout)
        while True:
            remaining = deadline - runtime.monotonic()
            if remaining <= 0:
                return "deadline"
            try:
                self.child_exit = self.child.wait(timeout=min(POLL, remaining))
                return "ok"
            except subprocess.TimeoutExpired:
                pass
            if not self.tunnel.alive():
                return "connection_lost"

    def cleanup(self):
        """Run every step independently and record each result."""
        results = {}
        runtime = self.runtime

        def step(name, action, skip):
            if skip:
                results[name] = "none"
                return
            try:
                results[name] = action() or "done"
            except Exception:  # noqa: BLE001 -- Record the failure, then keep cleaning up.
                results[name] = "failed"

        def child():
            if self.child.poll() is not None:
                if self.child_exit is None:
                    self.child_exit = self.child.returncode
                return "exited"
            runtime.stop_group(self.child)
            return "stopped"

        def tunnel():
            self.tunnel.close()
            return "closed"

        def token():
            try:
                self.client.post("auth/token/revoke-self", {}, token=self.issued["token"])
            except SafeError:
                raise SessionError("revoke_failed") from None
            return "revoked"

        def kubeconfig():
            runtime.remove_kubeconfig(self.kubeconfig)
            return "removed"

        def directory():
            for name in ("credential.pgpass", "pg_service.conf"):
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(self.directory / name)
            # Keep the record while a process it names may still run; the next run
            # or the cleanup command stops it.
            if "failed" in (results["child"], results["tunnel"]):
                return "kept"
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.directory / "session.json")
            os.rmdir(self.directory)
            return "removed"

        step("child", child, self.child is None)
        step("tunnel", tunnel, self.tunnel is None)
        step("token", token, not self.issued.get("token"))
        step("kubeconfig", kubeconfig, self.kubeconfig is None)
        step("directory", directory, self.directory is None)
        return results


def run(argv, runtime=None):
    runtime = runtime or Runtime()
    session = _Session(runtime)
    result, code = "ok", None
    with _Signals() as signals:
        try:
            try:
                request = parse(argv)
                capability = catalog().get((request.domain, request.capability))
                if capability is None:
                    raise SessionError("unknown_capability")
                cleanup_stale(runtime)
                try:
                    state = runtime.load_workstation()
                except SafeError:
                    raise SessionError("enrollment_unavailable") from None
                result = session.run(request, capability, state)
            except SessionError as error:
                result, code = str(error), EXIT_SETUP
            except Exception:  # noqa: BLE001 -- Never render credential-bearing text.
                result, code = "setup_failed", EXIT_SETUP
            finally:
                signals.defer()
        except Interrupted as interrupted:
            result, code = "interrupted", 128 + interrupted.signum
        results = session.cleanup()
        if signals.received and result != "interrupted":
            result, code = "interrupted", 128 + signals.received
    if code is None:
        code = {"deadline": EXIT_DEADLINE, "connection_lost": EXIT_TUNNEL}.get(
            result, session.child_exit
        )
        if code is None or code < 0:
            code = 128 - code if code is not None else EXIT_SETUP
    if "failed" in results.values() or results["directory"] == "kept":
        code = EXIT_CLEANUP
    fields = [
        f"result={result}",
        f"user={session.username or '-'}",
        f"expires_at={session.expires_at or '-'}",
        f"child_exit={'-' if session.child_exit is None else session.child_exit}",
        *(f"{name}={value}" for name, value in results.items()),
    ]
    if results["token"] == "failed":
        fields.append(f"revoke_failed=login expires by {session.expires_at or '-'}")
    if result == "enrollment_unavailable":
        fields.append(f"prerequisite=re-enroll: {ENROLL}")
    print("automation-data-session: " + " ".join(fields), file=sys.stderr, flush=True)
    return code


def _recorded(value):
    return value is None or (
        isinstance(value, dict)
        and set(value) == {"pid", "start"}
        and type(value["pid"]) is int
        and value["pid"] > 1
        and (value["start"] is None or isinstance(value["start"], str))
    )


def _stale(runtime, directory):
    """Return removed, kept, active or unrecognized for one session directory."""
    try:
        info = directory.lstat()
        if (
            not directory.name.startswith("session-")
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            return "unrecognized"
        record = workstation.read_private(directory / "session.json")
    except (OSError, SafeError):
        return "unrecognized"
    if (
        record.get("schema_version") != 1
        or type(record.get("expires_at")) not in (int, float)
        or not all(_recorded(record.get(k)) for k in ("runner", "child", "tunnel"))
        or record.get("runner") is None
        or not isinstance(record.get("repo_root"), str)
        or not (record.get("kubeconfig") is None or isinstance(record["kubeconfig"], str))
    ):
        return "unrecognized"
    runner = record["runner"]
    if record["expires_at"] > runtime.time() or (
        runner["start"] is not None and runtime.start_time(runner["pid"]) == runner["start"]
    ):
        return "active"
    stopped = all(
        runtime.stop_recorded(record[name], group=name == "child")
        for name in ("child", "tunnel")
        if record[name] is not None
    )
    for name in ("credential.pgpass", "pg_service.conf"):
        with contextlib.suppress(FileNotFoundError):
            os.unlink(directory / name)
    if record["kubeconfig"] is not None and Path(record["repo_root"]).is_dir():
        try:
            runtime.remove_kubeconfig(Path(record["kubeconfig"]), Path(record["repo_root"]))
        except Exception:  # noqa: BLE001 -- Keep the record and retry on the next run.
            return "kept"
    if not stopped or set(os.listdir(directory)) - {"session.json"}:
        return "kept"
    os.unlink(directory / "session.json")
    os.rmdir(directory)
    return "removed"


def cleanup_stale(runtime):
    """Stop and remove sessions whose expiry has passed and whose runner has exited."""
    counts = {"removed": 0, "kept": 0, "active": 0, "unrecognized": 0}
    try:
        entries = sorted(runtime.session_root.iterdir())
    except FileNotFoundError:
        return counts
    for directory in entries:
        try:
            counts[_stale(runtime, directory)] += 1
        except Exception:  # noqa: BLE001 -- One damaged entry never blocks the others.
            counts["kept"] += 1
    return counts


def main(argv):
    if argv[:1] == ["run"]:
        return run(argv[1:])
    if argv == ["cleanup"]:
        try:
            counts = cleanup_stale(Runtime())
        except Exception:  # noqa: BLE001 -- Never render credential-bearing text.
            print("automation-data-session-cleanup: failed", file=sys.stderr)
            return 1
        print(
            "automation-data-session-cleanup: " + " ".join(f"{k}={v}" for k, v in counts.items()),
            file=sys.stderr,
        )
        return 0 if counts["kept"] == counts["unrecognized"] == 0 else 1
    print(
        "Usage: database_session run <domain> <capability> [--timeout SECONDS] -- <command…>"
        " | cleanup",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
