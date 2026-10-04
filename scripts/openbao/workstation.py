"""Attended lifecycle for one reviewed workstation AppRole; no secret output."""

import base64
import fcntl
import json
import os
import secrets
import stat
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlsplit

from . import apply, guards
from .client import AmbiguousWrite, BaoClient, NotFound
from .configuration import SafeError, canonical_json, strict_json
from .secrets import directory_fd

ROLE = "agent-workstation"
ROLE_PATH = "auth/homelab-approle/role/" + ROLE
LOGIN_PATH = "auth/homelab-approle/login"
ENDPOINT = "https://openbao.lab.supermorphic.com"
DIRECTORY = Path.home() / ".config/homelab-talos/openbao"
PROFILES = ["observer", "diagnostic", "publisher", "campaign-coordinator"]


def ensure_private_directory(directory):
    try:
        if not directory.is_absolute() or directory.resolve() != directory:
            raise SafeError("invalid-source")
        # Create only missing components; never repair unsafe existing state.
        missing = []
        current = directory
        while not current.exists():
            missing.append(current)
            current = current.parent
        for path in reversed(missing):
            path.mkdir(mode=0o700)
        fd = directory_fd(directory)
        os.close(fd)
    except OSError:
        raise SafeError("invalid-source") from None


def _private_info(info):
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
    ):
        raise SafeError("invalid-source")


def read_private(path):
    fd = directory_fd(path.parent)
    try:
        file_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        with os.fdopen(file_fd, "rb") as stream:
            _private_info(os.fstat(stream.fileno()))
            data = stream.read(65537)
            if len(data) > 65536:
                raise SafeError("invalid-source")
            value = strict_json(data)
            if not isinstance(value, dict):
                raise SafeError("invalid-source")
            return value
    except OSError:
        raise SafeError("invalid-source") from None
    finally:
        os.close(fd)


def write_private(path, value):
    fd = directory_fd(path.parent)
    temporary = ".workstation-" + secrets.token_hex(16)
    try:
        try:
            _private_info(os.stat(path.name, dir_fd=fd, follow_symlinks=False))
        except FileNotFoundError:
            pass
        out = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd
        )
        with os.fdopen(out, "wb") as stream:
            stream.write(canonical_json(value) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path.name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    except OSError:
        raise SafeError("invalid-response") from None
    finally:
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass
        os.close(fd)


@contextmanager
def lifecycle_lock(directory):
    fd = directory_fd(directory)
    lock = None
    try:
        lock = os.open("lifecycle.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        _private_info(os.fstat(lock))
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    except OSError:
        raise SafeError("source-mismatch") from None
    finally:
        if lock is not None:
            os.close(lock)
        os.close(fd)


def target(kubeconfig):
    revision = guards.source_revision()
    guards.require_deployed_revision(kubeconfig, revision)
    cluster = guards.kube(kubeconfig, "get", "namespace", "kube-system", "-o", "json")
    return {"source_revision": revision, "cluster_uid": cluster["metadata"]["uid"]}


def cluster_metadata(kubeconfig):
    from .credentials import PROFILES as current_profiles

    # Read only the selected cluster section from an explicitly authorized file.
    view = guards.kube(kubeconfig, "config", "view", "--minify", "--raw", "-o", "json")
    try:
        cluster = view["clusters"][0]["cluster"]
        server, ca = cluster["server"], cluster["certificate-authority-data"]
        parsed = urlsplit(server)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.path not in ("", "/")
            or parsed.query
            or parsed.fragment
            or cluster.get("insecure-skip-tls-verify")
            or cluster.get("proxy-url")
            or cluster.get("tls-server-name")
            or not isinstance(ca, str)
        ):
            raise SafeError("invalid-source")
        if b"-----BEGIN CERTIFICATE-----" not in base64.b64decode(ca, validate=True):
            raise SafeError("invalid-source")
        return {
            "schema_version": 2,
            "server": server,
            "certificate_authority_data": ca,
            "openbao_server": ENDPOINT,
            "profiles": list(current_profiles),
        }
    except (KeyError, TypeError, ValueError, IndexError):
        raise SafeError("invalid-source") from None


def validate_session(auth, entity_id):
    if (
        not isinstance(auth, dict)
        or not isinstance(auth.get("client_token"), str)
        or not auth["client_token"]
        or auth.get("entity_id") != entity_id
        or auth.get("policies") != ["agent-profiles"]
        or auth.get("token_policies") != ["agent-profiles"]
        or auth.get("identity_policies", []) not in (None, [])
        or type(auth.get("lease_duration")) is not int
        or auth["lease_duration"] != 60
        or auth.get("token_type") != "service"
    ):
        raise SafeError("authentication-failed")


def _entity(entity, role_id, accessor, *, bound=True):
    if (
        not isinstance(entity, dict)
        or entity.get("name") != ROLE
        or not isinstance(entity.get("id"), str)
        or not entity["id"]
        or type(entity.get("disabled")) is not bool
        or any(
            entity.get(field) not in (None, [])
            for field in ("policies", "group_ids", "direct_group_ids", "inherited_group_ids")
        )
    ):
        raise SafeError("authentication-failed")
    aliases = entity.get("aliases", [])
    if not bound and aliases == []:
        return
    if (
        not isinstance(aliases, list)
        or len(aliases) != 1
        or aliases[0].get("name") != role_id
        or aliases[0].get("mount_accessor") != accessor
        or aliases[0].get("canonical_id") != entity["id"]
    ):
        raise SafeError("authentication-failed")


def _accessors(client):
    try:
        data = client.read(
            ROLE_PATH + "/secret-id", token=getattr(client, "token", None), list_request=True
        )["data"]
    except NotFound:
        return []
    if (
        not isinstance(data, dict)
        or set(data) != {"keys"}
        or not isinstance(data["keys"], list)
        or any(not isinstance(k, str) or not k for k in data["keys"])
        or len(data["keys"]) != len(set(data["keys"]))
    ):
        raise SafeError("incomplete-list")
    return sorted(data["keys"])


def run(action, slot, *, directory, client, kubeconfig, confirm, now=None):
    if action not in {"enroll", "rotate", "revoke"} or slot != ROLE:
        raise SafeError("invalid-source")
    clock = time.time if now is None else lambda: now
    now = clock()
    ensure_private_directory(directory)
    with lifecycle_lock(directory):

        def read(path):
            return client.read(path, token=getattr(client, "token", None))

        approved = target(kubeconfig)
        if apply.verify_configuration(apply.DESIRED, client) != {"differences": []}:
            raise SafeError("source-mismatch")
        role_id = read(ROLE_PATH + "/role-id")["data"]["role_id"]
        accessor = read("sys/auth")["data"]["homelab-approle/"]["accessor"]
        if not all(isinstance(s, str) and s for s in (role_id, accessor)):
            raise SafeError("invalid-response")
        record_path = directory / "operator.json"
        record = read_private(record_path) if record_path.exists() else None
        if record and (
            record.get("role_id") != role_id
            or record.get("mount_accessor") != accessor
            or record.get("cluster_uid") != approved["cluster_uid"]
        ):
            raise SafeError("source-mismatch")
        try:
            entity = read("identity/entity/name/" + ROLE)["data"]
        except NotFound:
            entity = None
        # A login would create or adopt an alias. Resolve it before any login.
        try:
            lookup = client.post(
                "identity/lookup/entity",
                {"alias_name": role_id, "alias_mount_accessor": accessor},
                token=getattr(client, "token", None),
            )
        except AmbiguousWrite as error:
            if error.http_status != 404:
                raise
            lookup = {}
        mapped = lookup.get("data") if isinstance(lookup, dict) else "invalid"
        if mapped is not None and (
            not isinstance(mapped, dict) or not entity or mapped.get("id") != entity.get("id")
        ):
            raise SafeError("authentication-failed")
        if entity and mapped is None:
            raise SafeError("authentication-failed")
        ids = _accessors(client)
        if entity:
            _entity(entity, role_id, accessor)
            if not record or record.get("entity_id") != entity["id"]:
                raise SafeError("source-mismatch")
        elif record or ids or action != "enroll":
            raise SafeError("source-mismatch")
        if (
            action == "enroll"
            and entity
            and (
                not entity["disabled"]
                or ids
                or not record.get("revoked_at")
                or now < record["revoked_at"] + 90
                or record.get("session_max_ttl") != 60
            )
        ):
            raise SafeError("authentication-failed")
        if action == "rotate":
            if (
                entity["disabled"]
                or record.get("revoked_at")
                or set(ids) - set(record["accessors"])
            ):
                raise SafeError("authentication-failed")
            read_private(directory / "workstation.json")
        fingerprint = guards.digest(
            {
                "target": approved,
                "role_id": role_id,
                "accessor": accessor,
                "entity": entity,
                "accessors": ids,
                "action": action,
            }
        )
        confirmation = f"{action}:openbao-workstation:{approved['source_revision']}:{fingerprint}"
        if confirm != confirmation:
            return {
                "status": "confirmation-required",
                "action": action,
                "confirmation": confirmation,
            }

        def post(path, payload, **kwargs):
            guards.assert_mutation_allowed(kubeconfig)
            if target(kubeconfig) != approved:
                raise SafeError("source-mismatch")
            return client.post(path, payload, token=getattr(client, "token", None), **kwargs)

        if action == "revoke":
            # First establish and read back the barrier. Never re-enable on error.
            post("identity/entity/id/" + entity["id"], {"disabled": True})
            observed = read("identity/entity/id/" + entity["id"])["data"]
            _entity(observed, role_id, accessor)
            if observed["disabled"] is not True:
                raise SafeError("authentication-failed")
            record["revoked_at"] = clock()
            write_private(record_path, record)
            for secret_accessor in _accessors(client):
                post(
                    ROLE_PATH + "/secret-id-accessor/destroy",
                    {"secret_id_accessor": secret_accessor},
                )
            if _accessors(client):
                raise SafeError("incomplete-list")
            local = directory / "workstation.json"
            if local.exists():
                read_private(local)
                local.unlink()
            record["accessors"] = []
            write_private(record_path, record)
            return {"status": "pass", "action": action}

        metadata = cluster_metadata(kubeconfig)
        if entity is None:
            created = post("identity/entity", {"name": ROLE, "policies": [], "disabled": False})
            entity_id = created["data"]["id"]
            record = {
                "schema_version": 1,
                "role_id": role_id,
                "mount_accessor": accessor,
                "entity_id": entity_id,
                "cluster_uid": approved["cluster_uid"],
                "accessors": [],
                "session_max_ttl": 60,
                "revoked_at": None,
            }
            write_private(record_path, record)
            post(
                "identity/entity-alias",
                {"name": role_id, "mount_accessor": accessor, "canonical_id": entity_id},
            )
        else:
            entity_id = entity["id"]
            if action == "enroll":
                # Old IDs are gone and the recorded hard session bound has elapsed.
                if _accessors(client):
                    raise SafeError("source-mismatch")
                post("identity/entity/id/" + entity_id, {"disabled": False})
        entity = read("identity/entity/id/" + entity_id)["data"]
        _entity(entity, role_id, accessor)
        if entity["disabled"]:
            raise SafeError("authentication-failed")
        secret = post(ROLE_PATH + "/secret-id", {})["data"]
        if (
            secret.get("secret_id_ttl") != 7776000
            or secret.get("secret_id_num_uses") != 0
            or not all(
                isinstance(secret.get(k), str) and secret[k]
                for k in ("secret_id", "secret_id_accessor")
            )
        ):
            raise SafeError("invalid-response")
        old_ids = list(record["accessors"])
        record["accessors"] = sorted(set(old_ids + [secret["secret_id_accessor"]]))
        write_private(record_path, record)
        # Validate through the public route that normal callers will use.
        route = getattr(client, "workstation_client", client)
        index = getattr(client, "consistency_index", None)
        if index is not None:
            route.require_consistency(index)
        response = route.post(
            LOGIN_PATH, {"role_id": role_id, "secret_id": secret["secret_id"]}, token=None
        )
        auth = response.get("auth", {})
        token = auth.get("client_token")
        try:
            validate_session(auth, entity_id)
        finally:
            if isinstance(token, str) and token:
                route.post("auth/token/revoke-self", {}, token=token)
        state = {
            "schema_version": 1,
            "role_id": role_id,
            "secret_id": secret["secret_id"],
            "expires_at": now + 7776000,
            "entity_id": entity_id,
            "cluster_digest": guards.digest(metadata),
        }
        write_private(directory / "cluster.json", metadata)
        write_private(directory / "workstation.json", state)
        record["revoked_at"] = None
        write_private(record_path, record)
        for old in old_ids:
            post(ROLE_PATH + "/secret-id-accessor/destroy", {"secret_id_accessor": old})
        if set(_accessors(client)) != {secret["secret_id_accessor"]}:
            raise SafeError("incomplete-list")
        record["accessors"] = [secret["secret_id_accessor"]]
        write_private(record_path, record)
        return {"status": "pass", "action": action}


def main(argv):
    from .operator import OperatorClient, lease, operator_password_session, private_prompt

    client = None
    try:
        if len(argv) != 3:
            raise SafeError("invalid-source")
        selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
        kubeconfig = Path(selected)
        if not selected or not kubeconfig.is_absolute() or not kubeconfig.is_file():
            print(
                "Set OPENBAO_OPERATOR_KUBECONFIG to an existing absolute operator kubeconfig path. "
                "For agent setup, use: mise exec -- just bootstrap openbao-agent <path> enroll",
                file=sys.stderr,
            )
            raise SafeError("invalid-source")
        target(kubeconfig)
        client = OperatorClient(kubeconfig)
        client.workstation_client = BaoClient(ENDPOINT)
        password = private_prompt("Retained OpenBao operator password: ")
        with operator_password_session(client, password) as token:
            client.set_token(token)
            args = {"directory": DIRECTORY, "client": client, "kubeconfig": kubeconfig}
            plan = run(argv[1], argv[2], confirm="", **args)
            print(json.dumps(plan, sort_keys=True))
            if not sys.stdin.isatty():
                return 2
            confirm = input("Enter exact confirmation: ")
            if confirm != plan["confirmation"]:
                return 2
            with lease(kubeconfig):
                result = run(argv[1], argv[2], confirm=confirm, **args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except Exception:  # noqa: BLE001 -- Never render credential-bearing exception text.
        error = sys.exc_info()[1]
        print(
            json.dumps(
                {
                    "status": "incomplete",
                    "classification": str(error)
                    if isinstance(error, SafeError)
                    else "invalid-response",
                }
            )
        )
        return 1
    finally:
        if client:
            client.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
