"""One-shot attended initialization. Failure preserves all server and PVC state."""

import secrets as random
from pathlib import Path

from . import apply, guards, secrets
from .client import AmbiguousWrite
from .configuration import SafeError, canonical_json


def _uninitialized(client, *, absent_allowed=False):
    states = client.states_now()
    if absent_allowed and states == []:
        return
    if (
        not isinstance(states, list)
        or len(states) != 3
        or any(not isinstance(s, dict) or s.get("initialized") is not False for s in states)
    ):
        raise SafeError("source-mismatch")


def run(
    phase: str,
    *,
    client,
    kubeconfig: Path,
    recovery_directory: Path,
    recipient: str,
    journal: list,
    confirm: str = "",
) -> dict:
    if phase not in {"prepare", "initialize"}:
        raise SafeError("invalid-source")
    secrets.preflight_recovery(recovery_directory, recipient)
    target = guards.freeze_target(kubeconfig, phase)
    if target["recipient"] != recipient:
        raise SafeError("source-mismatch")
    target_digest = target["package_digest"] if phase == "prepare" else guards.digest(target)
    required = guards.confirmation(phase, target["source_revision"], target_digest)
    _uninitialized(client, absent_allowed=phase == "prepare")
    if confirm != required:
        return {"status": "confirmation-required", "confirmation": required}
    guards.assert_mutation_allowed(kubeconfig)
    if guards.freeze_target(kubeconfig, phase) != target:
        raise SafeError("source-mismatch")
    secrets.preflight_recovery(recovery_directory, recipient)
    _uninitialized(client, absent_allowed=phase == "prepare")
    if phase == "prepare":
        observed = client.prepare(target)
        # This output is for local attended review, never retained test evidence.
        summary = {key: observed[key] for key in (
            "source_revision", "cluster_uid", "namespace_uid", "statefulset_uid",
            "pod_uids", "pvc_uids",
        )}
        return {"status": "prepared", "target": summary}
    password = random.token_urlsafe(32)
    # The transport never retries POST. A malformed success is also ambiguous.
    journal.append("initialization-requested")
    try:
        response = client.post("sys/init", {"recovery_shares": 1, "recovery_threshold": 1})
    except Exception:  # noqa: BLE001 -- Once sent, any unusable init result is ambiguous.
        raise AmbiguousWrite("ambiguous-write") from None
    if (
        not isinstance(response, dict)
        or not isinstance(response.get("root_token"), str)
        or not response["root_token"]
        or not isinstance(response.get("recovery_keys_base64"), list)
        or len(response["recovery_keys_base64"]) != 1
        or not isinstance(response["recovery_keys_base64"][0], str)
        or not response["recovery_keys_base64"][0]
    ):
        raise AmbiguousWrite("ambiguous-write")
    token = response["root_token"]
    secrets.write_recovery(
        recovery_directory,
        recipient,
        canonical_json(
            {
                "initialization": response,
                "operator_username": "openbao-operator",
                "operator_password": password,
                "target": target,
            }
        ),
    )
    journal.append("recovery-retained")
    client.wait_quorum(token)
    apply.install_initial(client, token, password, kubeconfig, target)
    journal.append("configuration-written")
    return _finish(client, token, password, kubeconfig, target, phase, journal)


def _revoke_checked(client, token):
    try:
        client.post("auth/token/revoke-self", {}, token=token)
    except AmbiguousWrite:
        # Resolve a lost acknowledgement by independent denial, never by retrying POST.
        pass
    try:
        client.read("auth/token/lookup-self", token=token)
    except SafeError as error:
        if str(error) == "read-denied":
            return
        raise
    raise SafeError("authentication-failed")


def _finish(client, token, password, kubeconfig, target, phase, journal):
    guards.assert_mutation_allowed(kubeconfig)
    if guards.freeze_target(kubeconfig, phase) != target:
        raise SafeError("source-mismatch")
    login = client.post("auth/homelab-userpass/login/openbao-operator", {"password": password})
    operator_token = login.get("auth", {}).get("client_token") if isinstance(login, dict) else None
    if not isinstance(operator_token, str) or not operator_token or operator_token == token:
        raise SafeError("authentication-failed")
    try:
        if set(login.get("auth", {}).get("policies", [])) != {"openbao-operator"}:
            raise SafeError("authentication-failed")
        lookup = client.read("auth/token/lookup-self", token=operator_token)
        if set(lookup.get("data", {}).get("policies", [])) != {"openbao-operator"}:
            raise SafeError("authentication-failed")
        client.wait_quorum(operator_token)
        client.set_token(operator_token)
        apply.verify_configuration(apply.DESIRED, client)
        if not apply.audit_state(client):
            raise SafeError("source-mismatch")
        journal.append("operator-login-verified")
        guards.assert_mutation_allowed(kubeconfig)
        if guards.freeze_target(kubeconfig, phase) != target:
            raise SafeError("source-mismatch")
        root = client.read("auth/token/lookup-self", token=token)
        if set(root.get("data", {}).get("policies", [])) != {"root"}:
            raise SafeError("authentication-failed")
        _revoke_checked(client, token)
        journal.append("root-revoked")
        client.wait_quorum(operator_token)
    finally:
        # This session belongs to this run; retire it even when read-back fails.
        guards.assert_mutation_allowed(kubeconfig)
        _revoke_checked(client, operator_token)
        client.set_token(None)
    return {"status": "pass"}


def finalize(*, client, token, kubeconfig, journal, password=None, confirm=""):
    """Finish a retained initialization without initializing or changing configuration."""
    target = guards.freeze_target(kubeconfig, "config-apply")
    client.wait_quorum(token)
    root = client.read("auth/token/lookup-self", token=token)
    if set(root.get("data", {}).get("policies", [])) != {"root"}:
        raise SafeError("authentication-failed")
    apply.verify_configuration(apply.DESIRED, client)
    if not apply.audit_state(client):
        raise SafeError("source-mismatch")
    required = guards.confirmation("finalize", target["source_revision"], guards.digest(target))
    if confirm != required:
        return {"status": "confirmation-required", "confirmation": required,
                "actions": ["verify-operator-login", "revoke-supplied-root-token"]}
    if not isinstance(password, str) or not password:
        raise SafeError("authentication-failed")
    return _finish(client, token, password, kubeconfig, target, "config-apply", journal)
