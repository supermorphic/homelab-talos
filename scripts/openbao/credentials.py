"""Standard Kubernetes exec credentials and checkout-local connection config."""

import base64
import json
import os
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

PROFILES = {
    "observer": "homelab-observer",
    "diagnostic": "homelab-diagnostic",
    "publisher": "homelab-report-publisher",
    "campaign-coordinator": "homelab-campaign-coordinator",
}
API_VERSION = "client.authentication.k8s.io/v1"
LAUNCHER = Path("scripts/repository/kubernetes-credential.sh")


def _cluster(cluster):
    if (
        not isinstance(cluster, dict)
        or set(cluster)
        != {"schema_version", "server", "certificate_authority_data", "openbao_server", "profiles"}
        or cluster["schema_version"] != 1
        or cluster["server"] != issuance.AUDIENCE
        or cluster["openbao_server"] != workstation.ENDPOINT
        or cluster["profiles"] != list(PROFILES)
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
    if profile not in PROFILES:
        raise SafeError("invalid-source")
    _cluster(workstation_state.get("cluster"))
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
            or data.get("service_account_name") != PROFILES[profile]
            or data.get("service_account_namespace") != "kube-system"
            or not isinstance(data.get("service_account_token"), str)
        ):
            raise SafeError("invalid-response")
        clock = type("Clock", (), {"time": staticmethod(lambda: now)})()
        try:
            expires = issuance.token_claims(
                data["service_account_token"],
                clock,
                identity="system:serviceaccount:kube-system:" + PROFILES[profile],
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
        if create and not directory.exists():
            directory.mkdir(mode=0o700)
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            os.close(fd)
            raise SafeError("invalid-source")
        return fd
    except OSError:
        raise SafeError("invalid-source") from None


def _read_config(fd):
    try:
        out = os.open("config", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
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
            for account in PROFILES.values()
        ],
        "current-context": PROFILES[profile],
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
            for name, account in PROFILES.items()
        ],
    }


def _validate_config(config, repo_root, *, legacy=False):
    try:
        cluster = config["clusters"][0]["cluster"]
        metadata = {
            "schema_version": 1,
            "server": cluster["server"],
            "certificate_authority_data": cluster["certificate-authority-data"],
            "openbao_server": workstation.ENDPOINT,
            "profiles": list(PROFILES),
        }
        _cluster(metadata)
        context = config["current-context"]
        profile = next(name for name, account in PROFILES.items() if account == context)
        expected = _config(repo_root, metadata, profile)
        if config == expected:
            return
        if legacy and context in set(PROFILES.values()) - {"homelab-campaign-coordinator"}:
            expected["contexts"] = expected["contexts"][:3]
            users = config["users"]
            if len(users) != 3:
                raise SafeError("invalid-source")
            for user, account in zip(users, list(PROFILES.values())[:3], strict=True):
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
    if path != repo_root / ".kube/config":
        raise SafeError("invalid-source")
    fd = _config_directory(repo_root)
    try:
        _validate_config(_read_config(fd), repo_root)
    finally:
        os.close(fd)


def install_kubeconfig(repo_root, directory, profile="observer"):
    if profile not in PROFILES:
        raise SafeError("invalid-source")
    local = load_workstation(directory)
    fd = _config_directory(repo_root, create=True)
    temporary = ".config-" + secrets.token_hex(16)
    try:
        try:
            os.stat("config", dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _validate_config(_read_config(fd), repo_root, legacy=True)
        out = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd
        )
        with os.fdopen(out, "wb") as stream:
            stream.write(canonical_json(_config(repo_root, local["cluster"], profile)) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, "config", src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    except OSError:
        raise SafeError("invalid-response") from None
    finally:
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass
        os.close(fd)
    return repo_root / ".kube/config"


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
        if len(argv) != 2 or argv[1] not in PROFILES:
            raise SafeError("invalid-source")
        info = json.loads(os.environ.get("KUBERNETES_EXEC_INFO", "{}"))
        if (
            info.get("apiVersion") != API_VERSION
            or info.get("kind") != "ExecCredential"
            or info.get("spec", {}).get("interactive") is not False
        ):
            raise SafeError("invalid-source")
        validate_scoped_kubeconfig(root / ".kube/config", root)
        local = load_workstation(workstation.DIRECTORY)
        output = issue_exec_credential(
            argv[1], local, client=BaoClient(workstation.ENDPOINT), now=time.time()
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
