"""Protected local files and fixed PostgreSQL identity checks for automation-data CLI."""

from __future__ import annotations

import contextlib
import json
import os
import re
import selectors
import stat
import subprocess
import sys
import threading
import time
from collections.abc import Iterator
from pathlib import Path

import psycopg
import yaml


class PrivateFileError(ValueError):
    """A local credential path is not an owned private regular file."""


class PrivateTunnelUnavailable(RuntimeError):
    """The scoped Kubernetes tunnel is not yet available."""


_ACTIVE_TUNNELS: dict[int, tuple[subprocess.Popen, Path, str]] = {}


def _check_owner_mode(path: Path, *, directory: bool) -> None:
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    expected = 0o700 if directory else 0o600
    if not kind(info.st_mode) or info.st_uid != os.getuid() or \
            stat.S_IMODE(info.st_mode) != expected or (not directory and info.st_nlink != 1):
        raise PrivateFileError("unsafe_private_path")


def validate_private_file(path: Path | str) -> Path:
    """Return an owned 0600 regular file, refusing symlinks and hard links."""
    selected = Path(path)
    try:
        _check_owner_mode(selected, directory=False)
    except (OSError, ValueError) as exc:
        raise PrivateFileError("unsafe_private_file") from exc
    return selected


def validate_private_directory(path: Path | str, *, create: bool = False) -> Path:
    selected = Path(path)
    if not selected.is_absolute():
        raise PrivateFileError("private_directory_must_be_absolute")
    try:
        if create:
            selected.mkdir(mode=0o700)
        _check_owner_mode(selected, directory=True)
    except FileExistsError:
        _check_owner_mode(selected, directory=True)
    except (OSError, ValueError) as exc:
        raise PrivateFileError("unsafe_private_directory") from exc
    return selected


def fsync_directory(path: Path) -> None:
    handle = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(handle)
    finally:
        os.close(handle)


def write_private_file_exclusive(path: Path | str, data: bytes) -> Path:
    """Create an owned 0600 file and make its name and data durable."""
    selected = Path(path)
    validate_private_directory(selected.parent)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        handle = os.open(selected, flags, 0o600)
        try:
            with os.fdopen(handle, "wb", closefd=False) as file:
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
        finally:
            os.close(handle)
        fsync_directory(selected.parent)
    except (OSError, ValueError) as exc:
        raise PrivateFileError("private_file_write_failed") from exc
    return validate_private_file(selected)


@contextlib.contextmanager
def clear_pg_environment() -> Iterator[None]:
    """Prevent libpq PG* environment variables from changing the fixed target."""
    removed = {key: value for key, value in os.environ.items() if key.startswith("PG")}
    for key in removed:
        del os.environ[key]
    try:
        yield
    finally:
        os.environ.update(removed)


def validate_session_identity(connection: psycopg.Connection, database: str, role: str) -> None:
    with connection.cursor() as cursor:
        cursor.execute("SELECT current_database(), session_user, current_user")
        if cursor.fetchone() != (database, role, role):
            raise ValueError("database_identity_mismatch")


def authenticate_candidate(port: int, database: str, role: str, password: str) -> None:
    with clear_pg_environment(), psycopg.connect(host="127.0.0.1", port=port, dbname=database,
                         user=role, password=password, connect_timeout=5,
                         sslmode="disable") as connection:
        validate_session_identity(connection, database, role)


@contextlib.contextmanager
def private_database_tunnel(kubeconfig: Path | None, local_port: int) -> Iterator[int]:
    """Forward only the ready automation-data PostgreSQL Pod through scoped credentials."""
    config = scoped_kubeconfig(kubeconfig)
    assert_scoped_identity(config)
    assert_named_forward_allowed(config)
    if not 1024 <= local_port <= 65535:
        raise PrivateTunnelUnavailable("invalid_local_port")
    uid = read_fixed_pod(config)
    process = start_fixed_forward(config, local_port)
    thread = None
    stop = None
    try:
        assert_pod_unchanged(config, uid)
        thread, stop = start_pod_watcher(config, uid, process)
        _ACTIVE_TUNNELS[local_port] = (process, config, uid)
        yield local_port
        if process.poll() is not None:
            raise PrivateTunnelUnavailable("private_tunnel_ended")
        assert_pod_unchanged(config, uid)
    finally:
        if _ACTIVE_TUNNELS.get(local_port, (None,))[0] is process:
            _ACTIVE_TUNNELS.pop(local_port, None)
        if stop is not None:
            stop.set()
        if thread is not None:
            thread.join(timeout=3)
        stop_fixed_forward(process)


def assert_tunnel_active(port: int) -> None:
    retained = _ACTIVE_TUNNELS.get(port)
    if retained is None or retained[0].poll() is not None:
        raise PrivateTunnelUnavailable("private_tunnel_ended")
    assert_pod_unchanged(retained[1], retained[2])


def scoped_kubeconfig(kubeconfig: Path | None) -> Path:
    """Accept the checked debugger config without changing its selected context."""
    root = Path(__file__).resolve().parents[2]
    # This module is also shipped alone to cluster workloads. Load the local
    # credential helper only for this workstation-only tunnel operation.
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    from scripts.openbao.configuration import SafeError
    from scripts.openbao.credentials import validate_scoped_kubeconfig

    selected = kubeconfig or root / ".kube" / "config"
    try:
        selected = validate_private_file(selected)
        if selected.parent.parent == root / ".kube/invocations":
            from scripts.test.access import validate_invocation

            if validate_invocation(root, selected)["profile"] != "debugger":
                raise ValueError("debugger_profile_required")
        else:
            validate_scoped_kubeconfig(selected, root)
        if yaml.safe_load(selected.read_text()).get("current-context") != "homelab-diagnostic":
            raise ValueError("debugger_context_required")
    except (OSError, KeyError, TypeError, ValueError, yaml.YAMLError, SafeError) as exc:
        raise PrivateTunnelUnavailable("scoped_kubeconfig_required") from exc
    return selected


def _kubectl(config: Path, *arguments: str) -> list[str]:
    return ["kubectl", "--kubeconfig", str(config),
            "--namespace", "automation-data", *arguments]


def _run_kubectl(config: Path, *arguments: str) -> str:
    try:
        completed = subprocess.run(_kubectl(config, *arguments), capture_output=True,
                                   text=True, timeout=8, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        raise PrivateTunnelUnavailable("scoped_kubectl_failed") from exc
    return completed.stdout


def assert_scoped_identity(config: Path) -> None:
    try:
        identity = json.loads(_run_kubectl(config, "auth", "whoami", "-o", "json"))
        if identity["status"]["userInfo"]["username"] != \
                "system:serviceaccount:kube-system:homelab-diagnostic":
            raise ValueError("diagnostic_identity_mismatch")
    except (KeyError, ValueError) as exc:
        raise PrivateTunnelUnavailable("diagnostic_identity_required") from exc


def assert_named_forward_allowed(config: Path) -> None:
    answer = _run_kubectl(config, "auth", "can-i", "create",
                          "pods/automation-data-postgresql-0", "--subresource", "portforward")
    if answer.strip() != "yes":
        raise PrivateTunnelUnavailable("named_forward_denied")


def read_fixed_pod(config: Path) -> str:
    """Check target namespace, owner, phase, readiness, and UID before forwarding."""
    try:
        pod = json.loads(_run_kubectl(config, "get", "pod",
                                      "automation-data-postgresql-0", "-o", "json"))
        metadata = pod["metadata"]
        owners = metadata["ownerReferences"]
        uid = metadata["uid"]
        if metadata["name"] != "automation-data-postgresql-0" or \
                metadata["namespace"] != "automation-data" or \
                not isinstance(uid, str) or not re.fullmatch(r"[0-9a-f-]{36}", uid) or \
                len(owners) != 1 or owners[0].get("kind") != "StatefulSet" or \
                owners[0].get("name") != "automation-data-postgresql" or \
                owners[0].get("controller") is not True or \
                pod["status"]["phase"] != "Running" or \
                not any(item.get("type") == "Ready" and item.get("status") == "True"
                        for item in pod["status"]["conditions"]):
            raise ValueError("fixed_pod_not_ready")
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise PrivateTunnelUnavailable("fixed_pod_not_ready") from exc
    return uid


def assert_pod_unchanged(config: Path, expected_uid: str) -> None:
    if read_fixed_pod(config) != expected_uid:
        raise PrivateTunnelUnavailable("fixed_pod_replaced")


def wait_for_forward(process: subprocess.Popen, port: int) -> None:
    """Require kubectl's own forwarding message, not a pre-existing listener."""
    selector = selectors.DefaultSelector()
    buffers: dict[int, str] = {}
    try:
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                selector.register(stream, selectors.EVENT_READ)
                buffers[stream.fileno()] = ""
        deadline = time.monotonic() + 12
        expected = f"Forwarding from 127.0.0.1:{port} -> 5432"
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise PrivateTunnelUnavailable("private_tunnel_exited")
            for key, _ in selector.select(timeout=0.25):
                handle = key.fileobj.fileno()
                chunk = os.read(handle, 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffers[handle] += chunk.decode("utf-8", errors="replace")
                lines = buffers[handle].split("\n")
                buffers[handle] = lines.pop()[-4096:]
                if any(line.strip() == expected for line in lines):
                    return
        raise PrivateTunnelUnavailable("private_tunnel_start_timeout")
    finally:
        selector.close()


def stop_fixed_forward(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def start_fixed_forward(config: Path, port: int) -> subprocess.Popen:
    argv = _kubectl(config, "port-forward", "--address", "127.0.0.1",
                    "pod/automation-data-postgresql-0", f"{port}:5432")
    try:
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, bufsize=1)
        wait_for_forward(process, port)
        return process
    except BaseException as exc:
        if "process" in locals():
            stop_fixed_forward(process)
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise
        raise PrivateTunnelUnavailable("private_tunnel_start_failed") from exc


def start_pod_watcher(config: Path, uid: str, process: subprocess.Popen) -> tuple[threading.Thread, threading.Event]:
    stop = threading.Event()

    def watch() -> None:
        while not stop.wait(2):
            try:
                assert_pod_unchanged(config, uid)
            except PrivateTunnelUnavailable:
                stop_fixed_forward(process)
                return

    thread = threading.Thread(target=watch, name="automation-data-pod-watch", daemon=True)
    thread.start()
    return thread, stop


def _pgpass_fields(line: str) -> list[str]:
    fields = []
    current = []
    escaped = False
    for char in line:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(char)
    if escaped:
        raise PrivateFileError("passfile_invalid")
    fields.append("".join(current))
    return fields


def validate_service_profile(service_file: Path, section: str, database: str,
                             role: str, port: int) -> dict[str, str]:
    """Parse only one exact local service and pass entry; return its private password."""
    service_file = validate_private_file(service_file)
    lines = service_file.read_text().splitlines()
    if not lines or lines[0] != f"[{section}]" or len(lines) != 7:
        raise PrivateFileError("service_profile_invalid")
    fields: dict[str, str] = {}
    for line in lines[1:]:
        if "=" not in line:
            raise PrivateFileError("service_profile_invalid")
        key, value = line.split("=", 1)
        if key in fields:
            raise PrivateFileError("service_profile_invalid")
        fields[key] = value
    if set(fields) != {"host", "port", "dbname", "user", "passfile", "sslmode"} or \
            fields["host"] != "127.0.0.1" or fields["port"] != str(port) or \
            fields["dbname"] != database or fields["user"] != role or \
            fields["sslmode"] != "disable" or \
            not Path(fields["passfile"]).is_absolute():
        raise PrivateFileError("service_profile_invalid")
    passfile = validate_private_file(Path(fields["passfile"]))
    pass_lines = passfile.read_text().splitlines()
    if len(pass_lines) != 1:
        raise PrivateFileError("passfile_invalid")
    values = _pgpass_fields(pass_lines[0])
    if len(values) != 5 or values[:4] != ["127.0.0.1", str(port), database, role] or \
            not values[4]:
        raise PrivateFileError("passfile_invalid")
    return {"password": values[4], "passfile": str(passfile)}
