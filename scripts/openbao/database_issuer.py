"""Attended reset of the specification 036 database issuer credential.

The command generates an issuer password, sets only its SCRAM verifier in
PostgreSQL, writes the password to the OpenBao connection, and has OpenBao rotate
it, so that afterwards only OpenBao knows it.
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import signal
import subprocess
from pathlib import Path

from . import apply, guards
from .configuration import SafeError, load_document
from .drift import sanitize
from .operator import OperatorClient, lease, operator_password_session, private_prompt

CONNECTION = ("database-connection", "automation-data")
ROTATE = "automation-data/rotate-root/automation-data"
HELPER = ["bash", str(guards.ROOT / "scripts/operations/automation-data-openbao-issuer-enable.sh")]


class EnableFailed(Exception):
    """The PostgreSQL step failed after it may have changed the issuer password."""

    def __init__(self, cleanup):
        super().__init__("enable-failed")
        self.cleanup = cleanup


def scram_verifier(password):
    """PostgreSQL SCRAM-SHA-256 verifier (RFC 7677), so plaintext never leaves this process."""
    salt, iterations = secrets.token_bytes(16), 4096
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", "sha256").digest()
    server_key = hmac.new(salted, b"Server Key", "sha256").digest()

    def encode(value):
        return base64.b64encode(value).decode()

    stored_key = hashlib.sha256(client_key).digest()
    return f"SCRAM-SHA-256${iterations}:{encode(salt)}${encode(stored_key)}:{encode(server_key)}"


def enable_login(kubeconfig, verifier):
    """Set the issuer's verifier through the helper Job; it arrives on stdin only."""
    process = subprocess.Popen(
        [*HELPER, str(kubeconfig)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        cwd=guards.ROOT,
        # Its own session, so an interrupt here reaches the helper only through the
        # SIGTERM below, which lets its cleanup delete the Job, Secret and Lease.
        start_new_session=True,
        env={
            **os.environ,
            "AUTOMATION_DATA_OPENBAO_ISSUER_ENABLE_CONFIRM": "enable:automation-data:openbao-issuer",
        },
    )
    try:
        stdout, _ = process.communicate(verifier.encode(), timeout=900)
    except BaseException:  # noqa: BLE001 -- Interrupts and timeouts must still clean up.
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, _ = process.communicate(timeout=180)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, _ = process.communicate()
        lines = stdout.decode(errors="replace").splitlines()
        raise EnableFailed(_cleanup(lines)) from None
    lines = stdout.decode(errors="replace").splitlines()
    if process.returncode != 0 or not any(
        line.startswith("openbao_issuer_login=enabled run=") for line in lines
    ):
        raise EnableFailed(_cleanup(lines))


def _cleanup(lines):
    return (
        "passed"
        if any(line.startswith("openbao_issuer_cleanup=passed run=") for line in lines)
        else "failed"
    )


def _verify_except_connection(desired_path, bao):
    """Every other object must match; the reset rewrites the whole connection."""
    _, states = apply.snapshot(desired_path, bao)
    differences = [
        finding
        for key, (_, findings) in states.items()
        if key != CONNECTION
        for finding in findings
    ]
    if sanitize(differences, source=desired_path)["differences"]:
        raise SafeError("source-mismatch")
    return states[CONNECTION]


def execute(bao, kubeconfig, *, token, confirm, enable=enable_login, desired_path=apply.DESIRED):
    actual, differences = _verify_except_connection(desired_path, bao)
    spec = next(
        s for s in load_document(desired_path)["objects"] if (s.kind, s.name) == CONNECTION
    )
    plan = {
        "source_revision": guards.source_revision(),
        "connection": "create" if actual is None else "replace",
        "before": actual,
        "differences": sorted(d.field or "" for d in differences),
        # A confirmation is valid for one run only.
        "run": secrets.token_hex(8),
    }
    required = f"issuer-reset:automation-data:{guards.digest(plan)}"
    print(
        json.dumps(
            {
                "status": "confirmation-required",
                "confirmation": required,
                "actions": ["set-issuer-verifier", "write-connection", "rotate-root", "verify"],
            },
            sort_keys=True,
        )
    )
    if confirm(required) != required:
        return {"status": "confirmation-required"}
    password = secrets.token_hex(32)
    guards.assert_mutation_allowed(kubeconfig)
    try:
        enable(kubeconfig, scram_verifier(password))
    except EnableFailed as error:
        return {"status": "fail", "issuer_state": "unknown", "cleanup": error.cleanup}
    # From here PostgreSQL holds the new password; any failure leaves the state unknown.
    try:
        guards.assert_mutation_allowed(kubeconfig)
        apply._write(spec, actual, bao, token, password)
        del password
        guards.assert_mutation_allowed(kubeconfig)
        bao.post(ROTATE, {}, token=token)
    except SafeError:
        return {"status": "fail", "issuer_state": "unknown", "cleanup": "passed"}
    apply.verify_configuration(desired_path, bao)
    return {
        "status": "pass",
        "connection": "created" if actual is None else "replaced",
        "issuer": "rotated",
    }


def main():
    result = {"status": "fail", "stage": "operator-input"}
    bao = None
    try:
        selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
        if not selected or not Path(selected).is_absolute() or not Path(selected).is_file():
            raise SafeError("source-mismatch")
        kubeconfig = Path(selected)
        result["stage"] = "source-preflight"
        guards.require_deployed_revision(kubeconfig, guards.source_revision())
        bao = OperatorClient(kubeconfig)
        result["stage"] = "operator-login"
        with operator_password_session(
            bao, private_prompt("Retained OpenBao operator password: ")
        ) as token:
            bao.set_token(token)
            with lease(kubeconfig):
                result["stage"] = "issuer-reset"
                result.update(
                    execute(
                        bao,
                        kubeconfig,
                        token=token,
                        confirm=lambda _required: private_prompt("Exact confirmation: "),
                    )
                )
    except SafeError as error:
        result.update(status="fail", classification=str(error))
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        result["status"] = "fail"
    finally:
        if bao:
            bao.close()
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
