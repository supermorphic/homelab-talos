"""Protected local files and fixed PostgreSQL identity checks for automation-data CLI."""

from __future__ import annotations

import contextlib
import os
import stat
from collections.abc import Iterator
from pathlib import Path

import psycopg


class PrivateFileError(ValueError):
    """A local credential path is not an owned private regular file."""


class PrivateTunnelUnavailable(RuntimeError):
    """The scoped Kubernetes tunnel is not yet available."""


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
    """Task 7 supplies the scoped fixed-pod implementation."""
    del kubeconfig, local_port
    raise PrivateTunnelUnavailable("scoped_private_tunnel_unavailable")
    yield 0  # pragma: no cover
