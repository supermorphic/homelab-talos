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
        client.prepare()
        return {"status": "prepared"}
    password = random.token_urlsafe(32)
    # The transport never retries POST. A malformed success is also ambiguous.
    journal.append("initialization-requested")
    response = client.post("sys/init", {"recovery_shares": 1, "recovery_threshold": 1})
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
    guards.assert_mutation_allowed(kubeconfig)
    if guards.freeze_target(kubeconfig, phase) != target:
        raise SafeError("source-mismatch")
    login = client.post("auth/homelab-userpass/login/openbao-operator", {"password": password})
    operator_token = login.get("auth", {}).get("client_token") if isinstance(login, dict) else None
    if (
        not isinstance(operator_token, str)
        or not operator_token
        or operator_token == token
        or set(login.get("auth", {}).get("policies", [])) != {"openbao-operator"}
    ):
        raise SafeError("authentication-failed")
    lookup = client.read("auth/token/lookup-self", token=operator_token)
    if set(lookup.get("data", {}).get("policies", [])) != {"openbao-operator"}:
        raise SafeError("authentication-failed")
    journal.append("operator-login-verified")
    guards.assert_mutation_allowed(kubeconfig)
    if guards.freeze_target(kubeconfig, phase) != target:
        raise SafeError("source-mismatch")
    client.post("auth/token/revoke-self", {}, token=token)
    try:
        client.read("auth/token/lookup-self", token=token)
    except SafeError as error:
        if str(error) != "read-denied":
            raise
    else:
        raise SafeError("authentication-failed")
    journal.append("root-revoked")
    client.wait_quorum(operator_token)
    # API read-back was proved before revocation; reauthenticate the reader with the
    # independent operator identity for final verification in the runtime adapter.
    if hasattr(client, "set_token"):
        client.set_token(operator_token)
        apply.verify_configuration(apply.DESIRED, client)
        if not apply.audit_state(client):
            raise SafeError("source-mismatch")
    client.post("auth/token/revoke-self", {}, token=operator_token)
    return {"status": "pass"}
