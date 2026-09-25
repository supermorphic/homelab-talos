"""Attended application of reviewed objects, followed by independent API reads."""

import copy
from pathlib import Path

from . import guards
from .configuration import SafeError, canonical_json, load_document
from .drift import compare, sanitize
from .verify import INVENTORY_ENDPOINTS, _keys

DESIRED = guards.PACKAGE / "config/desired.json"
SENSITIVE = {"service_account_jwt", "token_reviewer_jwt", "password", "client_secret", "jwt"}
AUDIT = {
    "type": "file",
    "description": "Homelab hashed audit output",
    "options": {"file_path": "stdout", "log_raw": "false", "hmac_accessor": "true"},
    "local": False,
}


def _safe_source(document):
    for spec in document["objects"]:
        prefixes = {
            "auth-method": "sys/auth/",
            "secret-mount": "sys/mounts/",
            "jwt-config": "auth/",
            "jwt-role": "auth/homelab-jwt/role/",
            "userpass-user": "auth/homelab-userpass/users/",
            "policy": "sys/policies/acl/",
            "kubernetes-config": "",
            "issuance-role": "kubernetes/roles/",
        }
        expected = prefixes[spec.kind] + spec.name
        if spec.kind in {"jwt-config", "kubernetes-config"}:
            expected += "/config"
        if spec.path != expected or SENSITIVE & set(spec.fields):
            raise SafeError("invalid-source")


def snapshot(desired_path, client):
    document = load_document(desired_path)
    _safe_source(document)
    inventory = {}
    for kind, endpoint in INVENTORY_ENDPOINTS.items():
        # Role endpoints do not exist until their parent backend is mounted.
        parent = {
            "jwt-role": ("auth-method", "homelab-jwt/"),
            "userpass-user": ("auth-method", "homelab-userpass/"),
            "issuance-role": ("secret-mount", "kubernetes/"),
        }.get(kind)
        if parent and parent[1] not in inventory[parent[0]]:
            inventory[kind] = {"keys": []}
            continue
        response = client.request(
            "GET" if kind in {"auth-method", "secret-mount"} else "LIST", endpoint
        )
        actual = _keys(response, kind)
        allowed = set(document["inventories"][kind]) | set(
            document["builtin_exceptions"].get(kind, [])
        )
        if actual - allowed:
            raise SafeError("invalid-response")
        inventory[kind] = response
    states = {}
    for spec in document["objects"]:
        if spec.kind in {"auth-method", "secret-mount"}:
            actual = inventory[spec.kind].get(spec.name)
        elif (
            spec.kind in inventory
            and spec.name not in _keys(inventory[spec.kind], spec.kind)
            or spec.kind == "jwt-config"
            and "homelab-jwt/" not in inventory["auth-method"]
            or spec.kind == "kubernetes-config"
            and "kubernetes/" not in inventory["secret-mount"]
        ):
            actual = None
        else:
            actual = client.request("GET", spec.path)
        # Some upstream APIs return documented empty credential fields.
        if isinstance(actual, dict) and any(
            actual.get(field) not in ("", None) for field in SENSITIVE & set(actual)
        ):
            raise SafeError("invalid-response")
        differences = compare(spec, actual)
        if any(d.state in {"unexpected", "inaccessible"} for d in differences):
            raise SafeError("invalid-response")
        if (
            spec.kind in {"auth-method", "secret-mount"}
            and actual is not None
            and (
                actual.get("type") != spec.fields["type"]
                or any(
                    actual.get(key, False) != spec.fields.get(key, False)
                    for key in ("local", "seal_wrap")
                )
            )
        ):
            raise SafeError("invalid-response")
        states[(spec.kind, spec.name)] = (actual, differences)
    return document, states


def _changes(document, states):
    return [
        {"kind": s.kind, "name": s.name, "action": "write"}
        for s in document["objects"]
        if states[(s.kind, s.name)][1]
    ]


def _write(spec, actual, client, token, password=None):
    payload = copy.deepcopy(spec.fields)
    path = spec.path
    if spec.kind == "policy":
        payload["policy"] = canonical_json(payload["policy"]).decode()
    if spec.kind == "userpass-user" and password is not None:
        payload["password"] = password
    if spec.kind in {"auth-method", "secret-mount"} and actual is not None:
        path += "tune"
        payload = {**payload["config"], "description": payload["description"]}
    client.post(path, payload, token=token)


def verify_configuration(desired_path, client):
    _, states = snapshot(desired_path, client)
    differences = [d for _, findings in states.values() for d in findings]
    sanitized = sanitize(differences, source=desired_path)
    if sanitized["differences"]:
        raise SafeError("source-mismatch")
    return sanitized


def audit_state(client):
    value = client.request("GET", "sys/audit")
    if not isinstance(value, dict) or set(value) - {"homelab/"}:
        raise SafeError("invalid-response")
    current = value.get("homelab/")
    if current is None:
        return False
    if (
        not isinstance(current, dict)
        or current.get("type") != AUDIT["type"]
        or current.get("options") != AUDIT["options"]
        or current.get("local", False) is not False
    ):
        raise SafeError("source-mismatch")
    return True


def ensure_audit(client, token):
    if not audit_state(client):
        client.post("sys/audit/homelab", copy.deepcopy(AUDIT), token=token)
    if not audit_state(client):
        raise SafeError("source-mismatch")


def install_initial(client, token, password, kubeconfig, expected_target, desired_path=DESIRED):
    if hasattr(client, "set_token"):
        client.set_token(token)
    document, states = snapshot(desired_path, client)
    for spec in document["objects"]:
        actual, differences = states[(spec.kind, spec.name)]
        if differences:
            guards.assert_mutation_allowed(kubeconfig)
            if guards.freeze_target(kubeconfig, "initialize") != expected_target:
                raise SafeError("source-mismatch")
            _write(spec, actual, client, token, password)
    guards.assert_mutation_allowed(kubeconfig)
    if guards.freeze_target(kubeconfig, "initialize") != expected_target:
        raise SafeError("source-mismatch")
    ensure_audit(client, token)
    verify_configuration(desired_path, client)


def run(
    *,
    desired_path: Path = DESIRED,
    client,
    token: str,
    kubeconfig: Path,
    confirm: str = "",
    journal: list,
    operator_password: str | None = None,
):
    target = guards.freeze_target(kubeconfig, "config-apply")
    document, states = snapshot(desired_path, client)
    changes = _changes(document, states)
    audit = audit_state(client)
    if not audit:
        changes.append({"kind": "audit", "name": "homelab/", "action": "enable"})
    plan_digest = guards.digest(
        {
            "target": target,
            "changes": changes,
            "before": {f"{k}/{n}": a for (k, n), (a, _) in states.items()},
        }
    )
    required = guards.confirmation("config-apply", target["source_revision"], plan_digest)
    if confirm != required:
        return {"status": "confirmation-required", "confirmation": required, "changes": changes}
    guards.assert_mutation_allowed(kubeconfig)
    if guards.freeze_target(kubeconfig, "config-apply") != target:
        raise SafeError("source-mismatch")
    _, repeated = snapshot(desired_path, client)
    if repeated != states or audit_state(client) != audit:
        raise SafeError("source-mismatch")
    missing_operator = states[("userpass-user", "openbao-operator")][0] is None
    if missing_operator and (not isinstance(operator_password, str) or not operator_password):
        raise SafeError("authentication-failed")
    for spec in document["objects"]:
        actual, differences = states[(spec.kind, spec.name)]
        if differences:
            guards.assert_mutation_allowed(kubeconfig)
            if guards.freeze_target(kubeconfig, "config-apply") != target:
                raise SafeError("source-mismatch")
            _write(
                spec,
                actual,
                client,
                token,
                operator_password if spec.kind == "userpass-user" and actual is None else None,
            )
            journal.append("configuration-written")
    guards.assert_mutation_allowed(kubeconfig)
    if guards.freeze_target(kubeconfig, "config-apply") != target:
        raise SafeError("source-mismatch")
    ensure_audit(client, token)
    result = verify_configuration(desired_path, client)
    return {"status": "pass", **result}
