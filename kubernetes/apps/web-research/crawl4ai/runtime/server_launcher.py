"""Run the native Crawl4AI server from a coherent projected Secret snapshot."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import yaml

MAX_CREDENTIAL_BYTES = 4096
NATIVE_ENVIRONMENT = {
    "CRAWL4AI_JWT_ENABLED": "true",
    "CRAWL4AI_HOOKS_ENABLED": "false",
    "CRAWL4AI_EXECUTE_JS_ENABLED": "false",
    "CRAWL4AI_ALLOW_INSECURE_TLS": "false",
    "CRAWL4AI_ALLOW_INTERNAL_URLS": "false",
    "GUNICORN_BIND": "0.0.0.0:11235",
    "HOME": "/home/appuser",
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "PYTHON_ENV": "production",
    "PYTHONFAULTHANDLER": "1",
    "PYTHONHASHSEED": "random",
    "PYTHONUNBUFFERED": "1",
    "PYTHONDONTWRITEBYTECODE": "1",
    "REDIS_HOST": "127.0.0.1",
    "REDIS_PORT": "6379",
}
CHILD_ENVIRONMENT_ALLOWLIST = {
    "C4AI_VERSION",
    "DYLD_LIBRARY_PATH",
    "LANG",
    "LANGUAGE",
    "LC_ALL",
    "LC_CTYPE",
    "LD_LIBRARY_PATH",
    "PLAYWRIGHT_BROWSERS_PATH",
    "REQUESTS_CA_BUNDLE",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "TZ",
    "XDG_CACHE_HOME",
}


class BootstrapInvalid(Exception):
    """The projected bootstrap bundle is absent or unsafe to consume."""


@dataclass(frozen=True)
class Bootstrap:
    api_token: str
    signing_key: str


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_time: str


@dataclass(frozen=True)
class ProcessRecord:
    parent_pid: int
    start_time: str
    state: str


def _read_credential(directory_fd: int, name: str) -> str:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, dir_fd=directory_fd)
    except OSError as error:
        raise BootstrapInvalid from error
    try:
        details = os.fstat(fd)
        if not stat.S_ISREG(details.st_mode) or details.st_size > MAX_CREDENTIAL_BYTES:
            raise BootstrapInvalid
        value = os.read(fd, MAX_CREDENTIAL_BYTES + 1)
        if len(value) > MAX_CREDENTIAL_BYTES:
            raise BootstrapInvalid
    finally:
        os.close(fd)
    try:
        text = value.decode("ascii")
    except UnicodeDecodeError as error:
        raise BootstrapInvalid from error
    if len(text) < 32 or "\r" in text or "\n" in text:
        raise BootstrapInvalid
    if any(ord(character) < 32 or ord(character) > 126 for character in text):
        raise BootstrapInvalid
    return text


def read_bootstrap(bootstrap_dir: Path) -> Bootstrap:
    """Read both credentials from the one directory selected by ``..data``."""
    try:
        bootstrap_dir = bootstrap_dir.resolve(strict=True)
        version_dir = (bootstrap_dir / "..data").resolve(strict=True)
        version_dir.relative_to(bootstrap_dir)
        directory_fd = os.open(version_dir, os.O_RDONLY | os.O_DIRECTORY)
    except (OSError, ValueError) as error:
        raise BootstrapInvalid from error
    try:
        api_token = _read_credential(directory_fd, "api_token")
        signing_key = _read_credential(directory_fd, "signing_key")
    finally:
        os.close(directory_fd)
    return Bootstrap(api_token=api_token, signing_key=signing_key)


def _atomic_write(path: Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
        os.chmod(path, mode)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        temporary_path.unlink(missing_ok=True)
        raise


def _write_health(runtime_dir: Path, ready: bool, reason: str) -> None:
    content = json.dumps({"ready": ready, "reason": reason}, separators=(",", ":")) + "\n"
    _atomic_write(runtime_dir / "launcher-health.json", content, 0o644)


def _link_native_sources(source_dir: Path, runtime_dir: Path) -> None:
    runtime_dir.mkdir(parents=True, exist_ok=True)
    sources = sorted(source_dir.glob("*.py"))
    static = source_dir / "static"
    if static.is_dir():
        sources.append(static)
    for source in sources:
        destination = runtime_dir / source.name
        if destination.is_symlink() and destination.resolve() == source.resolve():
            continue
        if destination.exists() or destination.is_symlink():
            raise RuntimeError("runtime_path_conflict")
        temporary = runtime_dir / f".{source.name}.link"
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(source.resolve(), target_is_directory=source.is_dir())
        os.replace(temporary, destination)


def _render_config(template_dir: Path, runtime_dir: Path, bootstrap: Bootstrap) -> str:
    try:
        document = yaml.safe_load((template_dir / "config.yml").read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise TypeError
        security = document["security"]
        redis = document["redis"]
        if not isinstance(security, dict) or not isinstance(redis, dict):
            raise TypeError
    except (OSError, KeyError, TypeError, yaml.YAMLError) as error:
        raise RuntimeError("template_invalid") from error
    redis_password = secrets.token_urlsafe(32)
    security["api_token"] = bootstrap.api_token
    redis["password"] = redis_password
    _atomic_write(runtime_dir / "config.yml", yaml.safe_dump(document, sort_keys=False), 0o600)
    return redis_password


def _enable_linux_subreaper() -> bool:
    if not sys.platform.startswith("linux"):
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            raise OSError(ctypes.get_errno(), "prctl")
    except (AttributeError, OSError):
        print("server-launcher: subreaper_unavailable", file=sys.stderr, flush=True)
        return False
    return True


def _linux_process_table() -> dict[int, ProcessRecord]:
    table = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "stat").read_text(encoding="ascii")
            fields = raw[raw.rfind(")") + 2 :].split()
            table[int(entry.name)] = ProcessRecord(
                parent_pid=int(fields[1]), start_time=fields[19], state=fields[0]
            )
        except (FileNotFoundError, IndexError, OSError, ValueError):
            continue
    return table


def _portable_process_table() -> dict[int, ProcessRecord]:
    scanner = subprocess.Popen(
        ["ps", "-axo", "pid=,ppid=,state=,lstart="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    stdout, _ = scanner.communicate()
    if scanner.returncode:
        raise subprocess.SubprocessError("process_scan_failed")
    table = {}
    for line in stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        try:
            table[int(fields[0])] = ProcessRecord(
                parent_pid=int(fields[1]), state=fields[2], start_time=fields[3]
            )
        except ValueError:
            continue
    table.pop(scanner.pid, None)
    return table


def _process_table() -> dict[int, ProcessRecord]:
    if sys.platform.startswith("linux"):
        table = _linux_process_table()
    else:
        table = _portable_process_table()
    if os.getpid() not in table:
        raise OSError("process_scan_incomplete")
    return table


def _descendant_identities(root_pid: int, table: dict[int, ProcessRecord]) -> set[ProcessIdentity]:
    descendants = set()
    parent_pids = {root_pid}
    while parent_pids:
        children = {
            pid
            for pid, record in table.items()
            if record.parent_pid in parent_pids and pid != root_pid
        }
        children -= {identity.pid for identity in descendants}
        if not children:
            break
        descendants.update(ProcessIdentity(pid, table[pid].start_time) for pid in children)
        parent_pids = children
    return descendants


def _living_identities(
    identities: set[ProcessIdentity], table: dict[int, ProcessRecord]
) -> set[ProcessIdentity]:
    return {
        identity
        for identity in identities
        if (record := table.get(identity.pid)) is not None
        and record.start_time == identity.start_time
        and not record.state.startswith("Z")
    }


def _signal_identities(
    identities: set[ProcessIdentity], table: dict[int, ProcessRecord], signum: int
) -> None:
    for identity in _living_identities(identities, table):
        try:
            os.kill(identity.pid, signum)
        except (PermissionError, ProcessLookupError):
            pass


def _signal_group(process: subprocess.Popen[bytes], signum: int) -> None:
    try:
        os.killpg(process.pid, signum)
    except (PermissionError, ProcessLookupError):
        pass


def _reap_children() -> None:
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return


def _stop_child(
    process: subprocess.Popen[bytes],
    timeout: float,
    owned: set[ProcessIdentity] | None = None,
) -> bool:
    tracked = set(owned or ())
    scan_succeeded = True

    def refresh() -> dict[int, ProcessRecord]:
        table = _process_table()
        tracked.update(_descendant_identities(os.getpid(), table))
        return table

    try:
        table = refresh()
    except (OSError, subprocess.SubprocessError):
        scan_succeeded = False
        table = {}
    _signal_group(process, signal.SIGTERM)
    _signal_identities(tracked, table, signal.SIGTERM)

    deadline = time.monotonic() + timeout
    living = _living_identities(tracked, table)
    while living and time.monotonic() < deadline:
        process.poll()
        _reap_children()
        time.sleep(0.01)
        try:
            table = refresh()
        except (OSError, subprocess.SubprocessError):
            scan_succeeded = False
            break
        _signal_identities(living, table, signal.SIGTERM)
        living = _living_identities(tracked, table)

    if living:
        _signal_group(process, signal.SIGKILL)
        _signal_identities(living, table, signal.SIGKILL)
        kill_deadline = time.monotonic() + min(1.0, timeout)
        while living and time.monotonic() < kill_deadline:
            process.poll()
            _reap_children()
            time.sleep(0.01)
            try:
                table = refresh()
            except (OSError, subprocess.SubprocessError):
                scan_succeeded = False
                break
            _signal_identities(living, table, signal.SIGKILL)
            living = _living_identities(tracked, table)

    process.poll()
    _reap_children()
    try:
        final_table = refresh()
    except (OSError, subprocess.SubprocessError):
        return False
    return scan_succeeded and not _living_identities(tracked, final_table)


class Launcher:
    def __init__(
        self,
        *,
        bootstrap_dir: Path,
        runtime_dir: Path,
        template_dir: Path,
        source_dir: Path,
        command: Sequence[str],
        poll_interval: float,
        restart_initial: float,
        restart_maximum: float,
        stop_timeout: float,
    ) -> None:
        self.bootstrap_dir = bootstrap_dir
        self.runtime_dir = runtime_dir
        self.template_dir = template_dir
        self.source_dir = source_dir
        self.command = list(command)
        self.poll_interval = poll_interval
        self.restart_initial = restart_initial
        self.restart_maximum = restart_maximum
        self.stop_timeout = stop_timeout
        self.stopping = threading.Event()
        self.child: subprocess.Popen[bytes] | None = None
        self.active_bootstrap: Bootstrap | None = None
        self.redis_password: str | None = None
        self.restart_delay = restart_initial
        self.restart_at = 0.0
        self.health: tuple[bool, str] | None = None
        self.owned_processes: set[ProcessIdentity] = set()

    def request_stop(self, _signum: int, _frame: object) -> None:
        self.stopping.set()

    def _set_health(self, ready: bool, reason: str) -> None:
        health = (ready, reason)
        if health != self.health:
            _write_health(self.runtime_dir, ready, reason)
            self.health = health

    def _start_child(self, bootstrap: Bootstrap) -> None:
        environment = {
            name: os.environ[name] for name in CHILD_ENVIRONMENT_ALLOWLIST if name in os.environ
        }
        environment.update(NATIVE_ENVIRONMENT)
        environment.update(
            {
                "SECRET_KEY": bootstrap.signing_key,
                "CRAWL4AI_API_TOKEN": bootstrap.api_token,
                "REDIS_PASSWORD": self.redis_password or "",
                "CRAWL4AI_RUNTIME_DIR": str(self.runtime_dir),
            }
        )
        self.child = subprocess.Popen(
            self.command,
            cwd=self.runtime_dir,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            table = _process_table()
            self.owned_processes = _descendant_identities(os.getpid(), table)
        except (OSError, subprocess.SubprocessError):
            self.owned_processes = set()
        self._set_health(True, "ready")
        print("server-launcher: child_started", file=sys.stderr, flush=True)

    def _replace(self, bootstrap: Bootstrap) -> bool:
        if self.child is not None:
            self._set_health(False, "reloading")
            if not _stop_child(self.child, self.stop_timeout, self.owned_processes):
                self._set_health(False, "cleanup_incomplete")
                print("server-launcher: cleanup_incomplete", file=sys.stderr, flush=True)
                return False
            self.child = None
            self.owned_processes.clear()
        self.redis_password = _render_config(self.template_dir, self.runtime_dir, bootstrap)
        self.active_bootstrap = bootstrap
        self.restart_delay = self.restart_initial
        self.restart_at = 0.0
        self._start_child(bootstrap)
        return True

    def _refresh_owned_processes(self) -> None:
        if self.child is None:
            return
        try:
            table = _process_table()
        except (OSError, subprocess.SubprocessError):
            return
        self.owned_processes.update(_descendant_identities(os.getpid(), table))

    def run(self) -> int:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        if not _enable_linux_subreaper():
            self._set_health(False, "cleanup_unavailable")
            return 1
        _link_native_sources(self.source_dir, self.runtime_dir)
        self._set_health(False, "bootstrap_unavailable")
        signal.signal(signal.SIGTERM, self.request_stop)
        signal.signal(signal.SIGINT, self.request_stop)
        try:
            while not self.stopping.is_set():
                self._refresh_owned_processes()
                try:
                    candidate = read_bootstrap(self.bootstrap_dir)
                except BootstrapInvalid:
                    self._set_health(False, "bootstrap_invalid")
                    self.stopping.wait(self.poll_interval)
                    continue

                if self.active_bootstrap != candidate:
                    self._replace(candidate)
                elif self.child is not None and self.child.poll() is not None:
                    if not _stop_child(self.child, self.stop_timeout, self.owned_processes):
                        self._set_health(False, "cleanup_incomplete")
                        self.stopping.wait(self.poll_interval)
                        continue
                    self.child = None
                    self.owned_processes.clear()
                    self._set_health(False, "child_exited")
                    self.restart_at = time.monotonic() + self.restart_delay
                    self.restart_delay = min(self.restart_delay * 2, self.restart_maximum)
                    print("server-launcher: child_exited", file=sys.stderr, flush=True)
                elif self.child is None and time.monotonic() >= self.restart_at:
                    self._start_child(candidate)
                elif self.child is not None:
                    self._set_health(True, "ready")

                self.stopping.wait(self.poll_interval)
        finally:
            self._set_health(False, "stopping")
            if self.child is not None:
                if not _stop_child(self.child, self.stop_timeout, self.owned_processes):
                    print("server-launcher: cleanup_incomplete", file=sys.stderr, flush=True)
                self.child = None
                self.owned_processes.clear()
            print("server-launcher: stopped", file=sys.stderr, flush=True)
        return 0


def _positive_bounded(value: str, maximum: float) -> float:
    parsed = float(value)
    if parsed <= 0 or parsed > maximum:
        raise argparse.ArgumentTypeError(f"must be greater than zero and at most {maximum}")
    return parsed


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap-dir", type=Path, default=Path("/run/bootstrap"))
    parser.add_argument("--runtime-dir", type=Path, default=Path("/run/crawl4ai"))
    parser.add_argument("--template-dir", type=Path, default=Path("/opt/platform"))
    parser.add_argument("--source-dir", type=Path, default=Path("/app"))
    parser.add_argument("--poll-interval", type=lambda v: _positive_bounded(v, 60), default=1.0)
    parser.add_argument("--restart-initial", type=lambda v: _positive_bounded(v, 60), default=1.0)
    parser.add_argument(
        "--restart-maximum", type=lambda v: _positive_bounded(v, 300), default=30.0
    )
    parser.add_argument("--stop-timeout", type=lambda v: _positive_bounded(v, 60), default=12.0)
    parser.add_argument("--command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.restart_initial > args.restart_maximum:
        parser.error("--restart-initial must not exceed --restart-maximum")
    if not args.command:
        args.command = [
            "/usr/bin/supervisord",
            "-c",
            str(args.template_dir / "supervisord.conf"),
            "--pidfile",
            str(args.runtime_dir / "supervisord.pid"),
        ]
    return args


def main(argv: Sequence[str] | None = None) -> int:
    for name in ("SECRET_KEY", "CRAWL4AI_API_TOKEN", "REDIS_PASSWORD"):
        os.environ.pop(name, None)
    args = parse_args(argv)
    launcher = Launcher(
        bootstrap_dir=args.bootstrap_dir,
        runtime_dir=args.runtime_dir,
        template_dir=args.template_dir,
        source_dir=args.source_dir,
        command=args.command,
        poll_interval=args.poll_interval,
        restart_initial=args.restart_initial,
        restart_maximum=args.restart_maximum,
        stop_timeout=args.stop_timeout,
    )
    try:
        return launcher.run()
    # This process boundary must not print exception values that could contain input.
    except Exception:  # noqa: BLE001
        print("server-launcher: fatal_error", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
