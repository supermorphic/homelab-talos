"""Standard Kubernetes exec credentials and checkout-local connection config."""

import base64
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import yaml

from . import guards, issuance, workstation
from .client import BaoClient
from .configuration import SafeError, canonical_json

LEGACY_PROFILES = {
    "observer": "homelab-observer",
    "diagnostic": "homelab-diagnostic",
    "publisher": "homelab-report-publisher",
    "campaign-coordinator": "homelab-campaign-coordinator",
}
SUITE_PROFILE_BINDINGS = {
    "test-flux-restart": ("test.flux-restart",),
    "test-cilium-connectivity": ("test.cilium-connectivity",),
    "test-node-reschedule": ("chainsaw.resilience.plex-cross-node-reschedule",),
    "test-conformance": ("conformance.quick", "conformance.certified"),
    "test-openbao-issuance": ("test.openbao-issuance",),
    "test-openbao-ha": ("test.openbao-ha",),
    "test-openbao-restore": ("test.openbao-restore-drill",),
    "test-openbao-lifecycle": ("test.agent-credentials",),
}
BASE_PROFILES = {
    "observer": "homelab-observer",
    "debugger": "homelab-diagnostic",
    "test-runner": "homelab-test-runner",
    "report-publisher": "homelab-report-publisher",
    "campaign-coordinator": "homelab-campaign-coordinator",
}
PROFILES = {
    **BASE_PROFILES,
    **{profile: "homelab-" + profile for profile in SUITE_PROFILE_BINDINGS},
}
API_VERSION = "client.authentication.k8s.io/v1"
LAUNCHER = Path("scripts/repository/kubernetes-credential.sh")


def _cluster(cluster):
    if (
        not isinstance(cluster, dict)
        or set(cluster)
        != {"schema_version", "server", "certificate_authority_data", "openbao_server", "profiles"}
        or type(cluster["schema_version"]) is not int
        or cluster["schema_version"] not in {1, 2}
        or cluster["server"] != issuance.AUDIENCE
        or cluster["openbao_server"] != workstation.ENDPOINT
        or cluster["profiles"]
        != list(LEGACY_PROFILES if cluster["schema_version"] == 1 else PROFILES)
        or not isinstance(cluster["certificate_authority_data"], str)
    ):
        raise SafeError("invalid-source")
    try:
        if b"-----BEGIN CERTIFICATE-----" not in base64.b64decode(
            cluster["certificate_authority_data"], validate=True
        ):
            raise SafeError("invalid-source")
    except ValueError:
        raise SafeError("invalid-source") from None


def load_workstation(directory):
    state = workstation.read_private(directory / "workstation.json")
    cluster = workstation.read_private(directory / "cluster.json")
    _cluster(cluster)
    if (
        set(state)
        != {"schema_version", "role_id", "secret_id", "entity_id", "expires_at", "cluster_digest"}
        or state["schema_version"] != 1
        or state["cluster_digest"] != guards.digest(cluster)
        or any(
            not isinstance(state[k], str) or not state[k]
            for k in ("role_id", "secret_id", "entity_id")
        )
        or type(state["expires_at"]) not in (int, float)
        or state["expires_at"] <= time.time()
    ):
        raise SafeError("authentication-failed")
    return {**state, "cluster": cluster}


def issue_exec_credential(profile, workstation_state, *, client, now):
    _cluster(workstation_state.get("cluster"))
    accounts = LEGACY_PROFILES if workstation_state["cluster"]["schema_version"] == 1 else PROFILES
    if profile not in accounts:
        raise SafeError("invalid-source")
    if (
        type(now) not in (int, float)
        or workstation_state.get("expires_at", 0) <= now
        or any(
            not isinstance(workstation_state.get(k), str) or not workstation_state[k]
            for k in ("role_id", "secret_id", "entity_id")
        )
    ):
        raise SafeError("authentication-failed")
    response = client.post(
        workstation.LOGIN_PATH,
        {"role_id": workstation_state["role_id"], "secret_id": workstation_state["secret_id"]},
    )
    auth = response.get("auth") if isinstance(response, dict) else None
    session = auth.get("client_token") if isinstance(auth, dict) else None
    try:
        workstation.validate_session(auth, workstation_state["entity_id"])
        result = client.post(
            "kubernetes/creds/" + profile,
            {"kubernetes_namespace": "kube-system", "ttl": 600},
            token=session,
        )
        data = result.get("data") if isinstance(result, dict) else None
        if (
            not isinstance(data, dict)
            or data.get("service_account_name") != accounts[profile]
            or data.get("service_account_namespace") != "kube-system"
            or not isinstance(data.get("service_account_token"), str)
        ):
            raise SafeError("invalid-response")
        clock = type("Clock", (), {"time": staticmethod(lambda: now)})()
        try:
            expires = issuance.token_claims(
                data["service_account_token"],
                clock,
                identity="system:serviceaccount:kube-system:" + accounts[profile],
            )
        except issuance.AcceptanceError:
            raise SafeError("invalid-response") from None
        output = {
            "apiVersion": API_VERSION,
            "kind": "ExecCredential",
            "status": {
                "token": data["service_account_token"],
                "expirationTimestamp": datetime.fromtimestamp(expires, UTC)
                .isoformat()
                .replace("+00:00", "Z"),
            },
        }
    finally:
        # One cleanup request, including on malformed/denied issuance. No output
        # follows an ambiguous cleanup; the hard session bound remains 60 seconds.
        if isinstance(session, str) and session:
            client.post("auth/token/revoke-self", {}, token=session)
    return output


def _root(repo_root):
    if not repo_root.is_absolute() or repo_root.resolve() != repo_root:
        raise SafeError("invalid-source")
    try:
        top = (
            subprocess.check_output(
                ["git", "-C", str(repo_root), "rev-parse", "--show-toplevel"],
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            .decode()
            .strip()
        )
        launcher = repo_root / LAUNCHER
        info = launcher.stat()
        if (
            top != str(repo_root)
            or launcher.resolve() != launcher
            or not stat.S_ISREG(info.st_mode)
            or not info.st_mode & 0o111
            or info.st_mode & 0o022
        ):
            raise SafeError("invalid-source")
    except (OSError, subprocess.SubprocessError):
        raise SafeError("invalid-source") from None


def _config_directory(repo_root, *, create=False):
    _root(repo_root)
    directory = repo_root / ".kube"
    try:
        if create:
            try:
                directory.mkdir(mode=0o700)
            except FileExistsError:
                pass
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            os.close(fd)
            raise SafeError("invalid-source")
        return fd
    except OSError:
        raise SafeError("invalid-source") from None


def _read_config(fd, name="config"):
    try:
        out = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        with os.fdopen(out, "rb") as stream:
            workstation._private_info(os.fstat(stream.fileno()))
            data = stream.read(1048577)
            if len(data) > 1048576:
                raise SafeError("invalid-source")
            value = yaml.safe_load(data)
            if not isinstance(value, dict):
                raise SafeError("invalid-source")
            return value
    except (OSError, yaml.YAMLError):
        raise SafeError("invalid-source") from None


def _config(repo_root, cluster, profile):
    accounts = LEGACY_PROFILES if cluster["schema_version"] == 1 else {profile: PROFILES[profile]}
    return {
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [
            {
                "name": "homelab",
                "cluster": {
                    "server": cluster["server"],
                    "certificate-authority-data": cluster["certificate_authority_data"],
                },
            }
        ],
        "contexts": [
            {"name": account, "context": {"cluster": "homelab", "user": account}}
            for account in accounts.values()
        ],
        "current-context": accounts[profile],
        "users": [
            {
                "name": account,
                "user": {
                    "exec": {
                        "apiVersion": API_VERSION,
                        "command": str(repo_root / LAUNCHER),
                        "args": [name],
                        "interactiveMode": "Never",
                    }
                },
            }
            for name, account in accounts.items()
        ],
    }


def _validate_config(config, repo_root, metadata, *, legacy=False):
    _cluster(metadata)
    if legacy and metadata["schema_version"] == 2:
        old_metadata = {**metadata, "schema_version": 1, "profiles": list(LEGACY_PROFILES)}
        try:
            _validate_config(config, repo_root, old_metadata, legacy=True)
            return
        except SafeError:
            pass
    try:
        context = config["current-context"]
        accounts = LEGACY_PROFILES if metadata["schema_version"] == 1 else PROFILES
        profile = next(name for name, account in accounts.items() if account == context)
        expected = _config(repo_root, metadata, profile)
        if config == expected:
            return
        if (
            legacy
            and metadata["schema_version"] == 1
            and context in set(LEGACY_PROFILES.values()) - {"homelab-campaign-coordinator"}
        ):
            expected["contexts"] = expected["contexts"][:3]
            users = config["users"]
            if len(users) != 3:
                raise SafeError("invalid-source")
            for user, account in zip(users, list(LEGACY_PROFILES.values())[:3], strict=True):
                if user["name"] != account or set(user["user"]) != {"token"}:
                    raise SafeError("invalid-source")
                token = user["user"]["token"]
                parts = token.split(".")
                if len(parts) != 3 or len(token) > 32768:
                    raise SafeError("invalid-source")
                claims = json.loads(
                    base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
                )
                if claims.get(
                    "sub"
                ) != "system:serviceaccount:kube-system:" + account or claims.get("aud") != [
                    issuance.AUDIENCE
                ]:
                    raise SafeError("invalid-source")
            expected["users"] = users
            if config == expected:
                return
        raise SafeError("invalid-source")
    except (KeyError, TypeError, ValueError, IndexError, StopIteration):
        raise SafeError("invalid-source") from None


def validate_scoped_kubeconfig(path, repo_root):
    if path.parent != repo_root / ".kube" or path.name not in {
        "config",
        *(p + ".config" for p in BASE_PROFILES),
    }:
        raise SafeError("invalid-source")
    fd = _config_directory(repo_root)
    try:
        _validate_config(
            _read_config(fd, path.name),
            repo_root,
            workstation.read_private(workstation.DIRECTORY / "cluster.json"),
        )
    finally:
        os.close(fd)


def install_kubeconfig(repo_root, directory, profile="observer"):
    if profile not in BASE_PROFILES | LEGACY_PROFILES.keys():
        raise SafeError("invalid-source")
    local = load_workstation(directory)
    accounts = LEGACY_PROFILES if local["cluster"]["schema_version"] == 1 else BASE_PROFILES
    if profile not in accounts:
        raise SafeError("invalid-source")
    name = (
        "config"
        if local["cluster"]["schema_version"] == 1 or profile == "observer"
        else profile + ".config"
    )
    fd = _config_directory(repo_root, create=True)
    temporary = ".config-" + secrets.token_hex(16)
    try:
        try:
            os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _validate_config(_read_config(fd, name), repo_root, local["cluster"], legacy=True)
        out = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd
        )
        with os.fdopen(out, "wb") as stream:
            stream.write(canonical_json(_config(repo_root, local["cluster"], profile)) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    except OSError:
        raise SafeError("invalid-response") from None
    finally:
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass
        os.close(fd)
    return repo_root / ".kube" / name


def _private_directory_at(parent, name, *, create=False):
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent)
        except FileExistsError:
            pass
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        os.close(fd)
        raise SafeError("invalid-source")
    return fd


def _invocation_parent(repo_root, config_path):
    try:
        relative = config_path.relative_to(repo_root / ".kube/invocations")
        if (
            len(relative.parts) != 2
            or relative.parts[1] != "config"
            or not re.fullmatch(r"[0-9a-f]{32}", relative.parts[0])
        ):
            raise SafeError("invalid-source")
    except ValueError:
        raise SafeError("invalid-source") from None
    fd = _config_directory(repo_root)
    try:
        return _private_directory_at(fd, "invocations"), relative.parts[0]
    finally:
        os.close(fd)


def _read_binding(fd):
    from .configuration import strict_json

    out = os.open("binding.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    with os.fdopen(out, "rb") as stream:
        workstation._private_info(os.fstat(stream.fileno()))
        data = stream.read(65537)
        if len(data) > 65536:
            raise SafeError("invalid-source")
        value = strict_json(data)
        if not isinstance(value, dict):
            raise SafeError("invalid-source")
        return value


def _invocation_config(repo_root, cluster, binding, config_path):
    config = _config(repo_root, cluster, binding["profile"])
    config["users"][0]["user"]["exec"]["args"] = ["invocation", str(config_path)]
    config["extensions"] = [
        {"name": "homelab-invocation", "extension": {"binding_digest": guards.digest(binding)}}
    ]
    return config


def install_invocation_kubeconfig(repo_root: Path, directory: Path, binding: dict) -> Path:
    from scripts.test.access import expected_invocation_binding

    if binding != expected_invocation_binding(repo_root, binding):
        raise SafeError("invalid-source")
    local = load_workstation(directory)
    if local["cluster"]["schema_version"] != 2 or binding["profile"] not in PROFILES:
        raise SafeError("invalid-source")
    root_fd = _config_directory(repo_root, create=True)
    parent = None
    fd = None
    name = secrets.token_hex(16)
    path = repo_root / ".kube/invocations" / name / "config"
    try:
        parent = _private_directory_at(root_fd, "invocations", create=True)
        os.mkdir(name, mode=0o700, dir_fd=parent)
        fd = _private_directory_at(parent, name)
        documents = {
            "binding.json": binding,
            "config": _invocation_config(repo_root, local["cluster"], binding, path),
        }
        for file_name, document in documents.items():
            out = os.open(
                file_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd
            )
            with os.fdopen(out, "wb") as stream:
                stream.write(canonical_json(document) + b"\n")
                stream.flush()
                os.fsync(stream.fileno())
        os.fsync(fd)
        return path
    except Exception:  # noqa: BLE001 -- Remove partial private files and redact failures.
        if fd is not None:
            for file_name in ("config", "binding.json"):
                try:
                    os.unlink(file_name, dir_fd=fd)
                except FileNotFoundError:
                    pass
            os.rmdir(name, dir_fd=parent)
        raise SafeError("invalid-source") from None
    finally:
        if fd is not None:
            os.close(fd)
        if parent is not None:
            os.close(parent)
        os.close(root_fd)


def read_invocation(repo_root: Path, config_path: Path) -> tuple[dict, dict]:
    parent = None
    fd = None
    try:
        parent, name = _invocation_parent(repo_root, config_path)
        fd = _private_directory_at(parent, name)
        return _read_binding(fd), _read_config(fd)
    except OSError:
        raise SafeError("invalid-source") from None
    finally:
        if fd is not None:
            os.close(fd)
        if parent is not None:
            os.close(parent)


def remove_invocation_files(repo_root: Path, config_path: Path) -> None:
    parent = None
    fd = None
    try:
        parent, name = _invocation_parent(repo_root, config_path)
        try:
            fd = _private_directory_at(parent, name)
        except FileNotFoundError:
            return
        names = os.listdir(fd)
        if set(names) - {"config", "binding.json"}:
            raise SafeError("invalid-source")
        for file_name in names:
            workstation._private_info(os.stat(file_name, dir_fd=fd, follow_symlinks=False))
        for file_name in names:
            os.unlink(file_name, dir_fd=fd)
        os.rmdir(name, dir_fd=parent)
    except OSError:
        raise SafeError("invalid-source") from None
    finally:
        if fd is not None:
            os.close(fd)
        if parent is not None:
            os.close(parent)


def main(argv):
    root = Path(__file__).resolve().parents[2]
    try:
        if len(argv) == 3 and argv[1] == "install":
            path = install_kubeconfig(root, workstation.DIRECTORY, argv[2])
            print(f"Installed scoped Kubernetes contexts at {path}")
            return 0
        if len(argv) == 3 and argv[1] == "validate":
            validate_scoped_kubeconfig(Path(argv[2]), root)
            return 0
        invocation = len(argv) == 3 and argv[1] == "invocation"
        if not invocation and (
            len(argv) != 2 or argv[1] not in BASE_PROFILES | LEGACY_PROFILES.keys()
        ):
            raise SafeError("invalid-source")
        info = json.loads(os.environ.get("KUBERNETES_EXEC_INFO", "{}"))
        if (
            info.get("apiVersion") != API_VERSION
            or info.get("kind") != "ExecCredential"
            or info.get("spec", {}).get("interactive") is not False
        ):
            raise SafeError("invalid-source")
        local = load_workstation(workstation.DIRECTORY)
        if invocation:
            from scripts.test.access import validate_invocation

            profile = validate_invocation(root, Path(argv[2]))["profile"]
        else:
            profile = argv[1]
            name = (
                "config"
                if local["cluster"]["schema_version"] == 1 or profile == "observer"
                else profile + ".config"
            )
            validate_scoped_kubeconfig(root / ".kube" / name, root)
        output = issue_exec_credential(
            profile, local, client=BaoClient(workstation.ENDPOINT), now=time.time()
        )
        # stdout is exclusively the Kubernetes credential protocol.
        print(json.dumps(output))
        return 0
    except Exception:  # noqa: BLE001 -- Never render credential-bearing exception text.
        error = sys.exc_info()[1]
        print(
            "Kubernetes credential unavailable: "
            + (str(error) if isinstance(error, SafeError) else "invalid-response")
            + ". Run mise exec -- just kube kubeconfig after enrollment.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
