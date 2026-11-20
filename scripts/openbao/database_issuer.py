"""Attended reset of the specification 036 database issuer credential.

The command sets a fresh issuer password in PostgreSQL, writes it to the OpenBao
connection, and has OpenBao rotate it, so that afterwards only OpenBao knows it.
"""

import json
import os
import secrets
import subprocess
from pathlib import Path

from . import apply, guards
from .configuration import SafeError, load_document
from .operator import OperatorClient, lease, operator_password_session, private_prompt

CONNECTION = ("database-connection", "automation-data")
ROTATE = "automation-data/rotate-root/automation-data"
ENABLE = guards.ROOT / "scripts/operations/automation-data-openbao-issuer-enable.sh"


def enable_login(kubeconfig, password):
    """Set the issuer's PostgreSQL password; the value reaches the helper only on stdin."""
    try:
        completed = subprocess.run(
            ["bash", str(ENABLE), str(kubeconfig)],
            input=password.encode(),
            capture_output=True,
            cwd=guards.ROOT,
            timeout=900,
            check=False,
            env={
                **os.environ,
                "AUTOMATION_DATA_OPENBAO_ISSUER_ENABLE_CONFIRM": "enable:automation-data:openbao-issuer",
            },
        )
    except (OSError, subprocess.SubprocessError):
        raise SafeError("source-mismatch") from None
    lines = completed.stdout.decode(errors="replace").splitlines()
    if completed.returncode != 0 or not any(
        line.startswith("openbao_issuer_login=enabled run=") for line in lines
    ):
        raise SafeError("source-mismatch")


def execute(bao, kubeconfig, *, token, confirm, enable=enable_login, desired_path=apply.DESIRED):
    # Every other object must already match; only a missing connection may differ.
    apply.verify_configuration(desired_path, bao, allow_issuer_reset=True)
    _, states = apply.snapshot(desired_path, bao)
    spec = next(
        s for s in load_document(desired_path)["objects"] if (s.kind, s.name) == CONNECTION
    )
    actual = states[CONNECTION][0]
    plan = {
        "source_revision": guards.source_revision(),
        "connection": "create" if actual is None else "replace",
        "before": actual,
    }
    required = f"issuer-reset:automation-data:{guards.digest(plan)}"
    print(
        json.dumps(
            {
                "status": "confirmation-required",
                "confirmation": required,
                "actions": ["set-issuer-password", "write-connection", "rotate-root", "verify"],
            },
            sort_keys=True,
        )
    )
    if confirm() != required:
        return {"status": "confirmation-required"}
    password = secrets.token_hex(32)
    guards.assert_mutation_allowed(kubeconfig)
    enable(kubeconfig, password)
    guards.assert_mutation_allowed(kubeconfig)
    apply._write(spec, actual, bao, token, password)
    del password
    try:
        bao.post(ROTATE, {}, token=token)
    except SafeError:
        # The issuer may hold the written password or a rotated one; rerun the reset.
        return {"status": "fail", "issuer_state": "unknown"}
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
                        confirm=lambda: (
                            os.environ.get("OPENBAO_DATABASE_ISSUER_CONFIRM")
                            or private_prompt("Exact confirmation: ")
                        ),
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
