#!/usr/bin/env python3
"""Register, validate, and install one protected application login credential."""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from automation_data_access import (
    fetch_observations,
    file_signature,
    lifecycle_readback,
    load_access_config,
    safe_path,
)
from automation_data_client import (
    PrivateFileError,
    authenticate_candidate,
    fsync_directory,
    private_database_tunnel,
    validate_private_directory,
    validate_private_file,
    validate_service_profile,
    write_private_file_exclusive,
)
from automation_data_inventory import DiscoveryRequest, build_inventory, resolve

WEBHOOK = "https://n8n.lab.supermorphic.com/webhook/automation-data-provision"
DOMAIN = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
APPLICATION = re.compile(r"^[a-z][a-z0-9_]{0,23}$")
SCHEMA = re.compile(r"^[a-z][a-z0-9_]{0,47}$")


class RequestError(RuntimeError):
    """The bounded private webhook request did not complete as expected."""


class PendingMaterialMissing(PrivateFileError):
    """A retained operation is incomplete and cannot be retried as-is."""


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Keep the credential-bearing request at its exact configured destination."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


WEBHOOK_OPENER = urllib.request.build_opener(RejectRedirects())


def send_request(payload: dict) -> dict:
    """Call only the fixed private webhook with verified TLS and bounded output."""
    token = os.environ.get("AUTOMATION_DATA_PROVISIONING_TOKEN", "")
    configured_url = os.environ.get("AUTOMATION_DATA_PROVISIONING_URL", WEBHOOK)
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,}", token) or configured_url != WEBHOOK:
        raise RequestError("request_configuration_invalid")
    body = json.dumps(payload, separators=(",", ":")).encode()
    request = urllib.request.Request(WEBHOOK, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "X-Automation-Data-Provisioning": token,
    })
    try:
        # Successful mutations can include up to 30 seconds of optional inventory
        # readback. Preserve their response within the original 20-second operation
        # budget plus readback and margin; observational validation stays shorter.
        timeout = 60 if payload.get("operation") in {
            "login-register", "login-activate", "login-rotate", "login-complete"
        } else 20
        with WEBHOOK_OPENER.open(request, timeout=timeout) as response:
            content = response.read(65537)
        if len(content) > 65536:
            raise RequestError("response_too_large")
        result = json.loads(content)
    except (OSError, ValueError, urllib.error.URLError) as exc:
        raise RequestError("request_failed") from exc
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise RequestError("request_rejected")
    return result


def require_response(result: dict, domain: str, application: str) -> dict:
    role = "app_" + hashlib.md5(
        f"{domain}:{application}".encode(), usedforsecurity=False).hexdigest() + "_integration"
    if result.get("domain") != domain or result.get("application") != application or \
            result.get("database") != domain or result.get("role") != role or \
            not isinstance(result.get("schema"), str) or \
            result.get("state") not in {"awaiting_grants", "activating", "ready", "rotating", "error"} or \
            type(result.get("credentialGeneration")) is not int or \
            result["credentialGeneration"] < 0 or \
            any(key in result for key in ("password", "credential", "headers", "apiKey")):
        raise RequestError("response_invalid")
    return result


def private_root() -> Path:
    raw = os.environ.get("AUTOMATION_DATA_LOGIN_DIRECTORY", "")
    if not raw:
        raise PrivateFileError("private_directory_required")
    root = validate_private_directory(Path(raw))
    repository = Path(__file__).resolve().parents[2]
    resolved = root.resolve(strict=True)
    if resolved == repository or repository in resolved.parents:
        raise PrivateFileError("private_directory_inside_checkout")
    return root


def operation_directory(root: Path, domain: str, application: str) -> Path:
    domain_dir = validate_private_directory(root / domain, create=True)
    return validate_private_directory(domain_dir / application, create=True)


@contextlib.contextmanager
def operation_lock(directory: Path):
    lock = directory / ".lock"
    try:
        write_private_file_exclusive(lock, b"")
    except PrivateFileError:
        validate_private_file(lock)
    with lock.open("rb") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def read_pending(directory: Path) -> tuple[dict, str] | None:
    pending = directory / "pending"
    if not pending.exists() and not pending.is_symlink():
        return None
    validate_private_directory(pending)
    for name in ("operation.json", "candidate.pgpass"):
        selected = pending / name
        if not selected.exists() and not selected.is_symlink():
            raise PendingMaterialMissing("pending_material_missing")
    operation = json.loads(validate_private_file(pending / "operation.json").read_text())
    candidate = validate_private_file(pending / "candidate.pgpass").read_text()
    if not candidate.endswith("\n") or candidate.count(":") != 4:
        raise PrivateFileError("candidate_format_invalid")
    password = candidate.rstrip("\n").rsplit(":", 1)[1]
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", password):
        raise PrivateFileError("candidate_format_invalid")
    return operation, password


def archive_pending(directory: Path) -> None:
    pending = validate_private_directory(directory / "pending")
    destination = directory / f"recovery-{uuid.uuid4().hex}"
    pending.rename(destination)
    fsync_directory(directory)


def create_pending(directory: Path, action: str, domain: str, application: str,
                   role: str, expected_generation: int, port: int) -> tuple[dict, str]:
    pending = validate_private_directory(directory / "pending", create=True)
    operation = {"domain": domain, "application": application, "operation": action,
                 "role": role, "operationId": str(uuid.uuid4()),
                 "expectedGeneration": expected_generation, "localPort": port,
                 "localPhase": "prepared"}
    password = secrets.token_urlsafe(48)
    passline = f"127.0.0.1:{port}:{domain}:{role}:{password}\n".encode()
    write_private_file_exclusive(pending / "candidate.pgpass", passline)
    write_private_file_exclusive(pending / "operation.json",
                                 (json.dumps(operation, sort_keys=True) + "\n").encode())
    fsync_directory(pending)
    fsync_directory(directory)
    return operation, password


def update_phase(directory: Path, operation: dict, phase: str) -> None:
    pending = validate_private_directory(directory / "pending")
    current = pending / "operation.json"
    validate_private_file(current)
    operation["localPhase"] = phase
    temporary = pending / f".operation-{uuid.uuid4().hex}.tmp"
    write_private_file_exclusive(temporary,
                                 (json.dumps(operation, sort_keys=True) + "\n").encode())
    os.replace(temporary, current)
    fsync_directory(pending)


def install_profile(directory: Path, domain: str, application: str, schema: str,
                    role: str, generation: int, operation_id: str, port: int) -> None:
    pending = validate_private_directory(directory / "pending")
    source = validate_private_file(pending / "candidate.pgpass")
    version = directory / f"generation-{generation}"
    version = validate_private_directory(version, create=True)
    passfile = version / "credential.pgpass"
    if passfile.exists() or passfile.is_symlink():
        validate_private_file(passfile)
        if passfile.read_bytes() != source.read_bytes():
            raise PrivateFileError("generation_collision")
    else:
        write_private_file_exclusive(passfile, source.read_bytes())
    service = (f"[automation_data_{domain}_{role}]\n"
               f"host=127.0.0.1\nport={port}\ndbname={domain}\nuser={role}\n"
               f"passfile={passfile}\nsslmode=disable\n").encode()
    versioned_service = version / "service.conf"
    if versioned_service.exists() or versioned_service.is_symlink():
        validate_private_file(versioned_service)
        if versioned_service.read_bytes() != service:
            raise PrivateFileError("generation_collision")
    else:
        write_private_file_exclusive(versioned_service, service)
    binding = (json.dumps({"domain": domain, "application": application,
                           "database": domain, "schema": schema, "role": role,
                           "credentialGeneration": generation, "operationId": operation_id,
                           "localPort": port}, sort_keys=True) + "\n").encode()
    versioned_binding = version / "binding.json"
    if versioned_binding.exists() or versioned_binding.is_symlink():
        validate_private_file(versioned_binding)
        if versioned_binding.read_bytes() != binding:
            raise PrivateFileError("generation_collision")
    else:
        write_private_file_exclusive(versioned_binding, binding)
    selected = directory / "service.conf"
    if selected.exists() or selected.is_symlink():
        validate_private_file(selected)
    temporary = directory / f".service-{uuid.uuid4().hex}.tmp"
    write_private_file_exclusive(temporary, service)
    os.replace(temporary, selected)
    selected_binding = directory / "binding.json"
    if selected_binding.exists() or selected_binding.is_symlink():
        validate_private_file(selected_binding)
    temporary_binding = directory / f".binding-{uuid.uuid4().hex}.tmp"
    write_private_file_exclusive(temporary_binding, binding)
    os.replace(temporary_binding, selected_binding)
    fsync_directory(directory)


def clear_completed_pending(directory: Path) -> None:
    pending = validate_private_directory(directory / "pending")
    for name in ("candidate.pgpass", "operation.json"):
        validate_private_file(pending / name).unlink()
    pending.rmdir()
    fsync_directory(directory)


def local_port() -> int:
    value = os.environ.get("AUTOMATION_DATA_LOCAL_PORT", "15432")
    if not value.isdigit() or not 1024 <= int(value) <= 65535:
        raise ValueError("invalid_local_port")
    return int(value)


def confirmation(action: str, domain: str, application: str, schema: str | None = None) -> None:
    suffix = f":{schema}" if schema is not None else ""
    expected = f"{action}:automation-data:{domain}:{application}{suffix}"
    name = f"AUTOMATION_DATA_LOGIN_{action.upper()}_CONFIRM"
    if os.environ.get(name) != expected:
        raise ValueError("confirmation_required")


def require_deployed_login_sources() -> None:
    repository = Path(__file__).resolve().parents[2]
    script = ("source scripts/lib/rollout.sh; require_deployed_source "
              "'automation-data application login' "
              "scripts/operations/automation-data-login.py "
              "scripts/lib/automation_data_client.py "
              "kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json "
              "kubernetes/apps/automation-data/postgresql/app/scripts/application-login.sql")
    subprocess.run(["bash", "-c", script], cwd=repository, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def require_deployed_enrollment_sources() -> None:
    repository = Path(__file__).resolve().parents[2]
    script = (
        "source scripts/lib/rollout.sh; require_deployed_source "
        "'automation-data migrator enrollment' "
        "scripts/operations/automation-data-login.py "
        "scripts/lib/automation_data_access.py scripts/lib/automation_data_inventory.py "
        "scripts/lib/automation_data_client.py "
        "kubernetes/apps/automation/n8n/app/workflows/automation-data-credential-inventory.json"
    )
    subprocess.run(
        ["bash", "-c", script],
        cwd=repository,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def enroll_migrator(domain: str) -> None:
    """Operator-only binding of an already installed private profile; never export from n8n."""
    confirmation("enroll", domain, "migrator")
    require_deployed_enrollment_sources()
    config = load_access_config()
    directory = safe_path(config.migrator_profile_root / domain, directory=True)
    selected_file = os.environ.get("AUTOMATION_DATA_SERVICE_FILE", "")
    section = os.environ.get("AUTOMATION_DATA_SERVICE", "")
    if selected_file != str(directory / "service.conf") or not re.fullmatch(
        r"[A-Za-z][A-Za-z0-9_-]{0,127}", section
    ):
        raise PrivateFileError("installed_migrator_profile_required")
    service_file = safe_path(selected_file)
    passfile = safe_path(directory / "credential.pgpass")
    if (directory / "pending").exists() or (directory / "pending").is_symlink():
        raise PrivateFileError("pending_profile_operation")
    request = DiscoveryRequest("resolve", domain, "migration")

    def current_binding():
        resolution = resolve(request, build_inventory(fetch_observations(config, request)))
        if (
            resolution.decision != "setup_required"
            or resolution.identity is None
            or resolution.prerequisites[-1]
            != {"name": "protected_current_profile", "status": "missing"}
        ):
            raise PrivateFileError("migrator_metadata_not_ready")
        item = resolution.identity
        return {
            "domain": domain,
            "database": domain,
            "role": item["role"],
            "credentialId": item["credentialId"],
            "credentialUpdatedAt": item["credentialUpdatedAt"],
            "service": section,
            "localPort": local_port(),
        }

    with operation_lock(directory):
        binding = current_binding()
        signature = file_signature([service_file, passfile])
        kubeconfig = os.environ.get("AUTOMATION_DATA_KUBECONFIG")
        with private_database_tunnel(
            Path(kubeconfig) if kubeconfig else None, local_port()
        ) as port:
            if (
                current_binding() != binding
                or file_signature([service_file, passfile]) != signature
            ):
                raise PrivateFileError("enrollment_profile_changed")
            profile = validate_service_profile(
                service_file, section, domain, binding["role"], port
            )
            if profile["passfile"] != str(passfile):
                raise PrivateFileError("migrator_passfile_mismatch")
            authenticate_candidate(port, domain, binding["role"], profile["password"])
            if (
                current_binding() != binding
                or file_signature([service_file, passfile]) != signature
            ):
                raise PrivateFileError("enrollment_profile_changed")
            selected = directory / "binding.json"
            if selected.exists() or selected.is_symlink():
                safe_path(selected)
                if selected.stat().st_size > 16384:
                    raise PrivateFileError("invalid_existing_binding")
                old_binding = json.loads(selected.read_text())
                if any(
                    old_binding.get(key) != binding[key]
                    for key in ["domain", "database", "role", "service", "localPort"]
                ):
                    raise PrivateFileError("existing_binding_target_mismatch")
            temporary = directory / f".binding-{uuid.uuid4().hex}.tmp"
            write_private_file_exclusive(
                temporary, (json.dumps(binding, sort_keys=True) + "\n").encode()
            )
            os.replace(temporary, selected)
            fsync_directory(directory)
    print(
        json.dumps(
            {
                "domain": domain,
                "role": binding["role"],
                "enrolled": True,
                "credentialId": binding["credentialId"],
                "serviceFile": str(service_file),
            }
        )
    )


def execute(action: str, domain: str, application: str, schema: str | None = None) -> None:
    if action == "register":
        confirmation(action, domain, application, schema)
        require_deployed_login_sources()
        result = require_response(send_request({"domain": domain, "operation": "login-register",
                                                "application": application, "schema": schema}),
                                  domain, application)
        print(json.dumps({"domain": domain, "application": application,
                          "role": result["role"], "state": result["state"],
                          "inventoryReadback": lifecycle_readback({**result, "operation": "login-register"})}))
        return
    if action == "validate":
        result = require_response(send_request({"domain": domain, "operation": "login-validate",
                                                "application": application}), domain, application)
        print(json.dumps({key: result[key] for key in ("domain", "application", "role", "state",
                                                        "credentialGeneration", "valid") if key in result}))
        return
    confirmation(action, domain, application)
    require_deployed_login_sources()
    root = private_root()
    directory = operation_directory(root, domain, application)
    with operation_lock(directory):
        state = require_response(send_request({"domain": domain, "operation": "login-validate",
                                               "application": application}), domain, application)
        try:
            pending = read_pending(directory)
        except PendingMaterialMissing:
            if action != "rotate" or state.get("valid") is not True or \
                    state["credentialGeneration"] < 1:
                raise
            archive_pending(directory)
            pending = None
        if pending is not None and pending[0].get("operation") != action and \
                action == "rotate" and state.get("valid") is True and \
                state["credentialGeneration"] >= 1:
            archive_pending(directory)
            pending = None
        if pending is None:
            if state.get("valid") is not True or \
                    (action == "activate" and (state["state"] != "awaiting_grants" or
                                                state["credentialGeneration"] != 0)) or \
                    (action == "rotate" and (state["state"] not in
                                             {"ready", "activating", "rotating"} or
                                             state["credentialGeneration"] < 1)):
                raise ValueError("login_not_eligible")
            operation, password = create_pending(directory, action, domain, application,
                                                 state["role"], state["credentialGeneration"],
                                                 local_port())
        else:
            operation, password = pending
            if any((operation.get("domain") != domain,
                    operation.get("application") != application,
                    operation.get("operation") != action,
                    operation.get("role") != state["role"],
                    operation.get("localPort") != local_port())):
                raise ValueError("pending_target_mismatch")
            if state["credentialGeneration"] not in {operation["expectedGeneration"],
                                                      operation["expectedGeneration"] + 1}:
                raise ValueError("pending_generation_mismatch")
            if state["credentialGeneration"] == operation["expectedGeneration"] + 1 and \
                    state.get("operationId") != operation["operationId"]:
                raise ValueError("pending_operation_mismatch")
        kubeconfig = os.environ.get("AUTOMATION_DATA_KUBECONFIG")
        with private_database_tunnel(Path(kubeconfig) if kubeconfig else None,
                                     local_port()) as port:
            payload = {"domain": domain, "application": application,
                       "operation": "login-activate" if action == "activate" else "login-rotate",
                       "operationId": operation["operationId"],
                       "expectedGeneration": operation["expectedGeneration"],
                       "password": password}
            result = require_response(send_request(payload), domain, application)
            if result["operationId"] != operation["operationId"] or \
                    result["credentialGeneration"] != operation["expectedGeneration"] + 1:
                raise RequestError("operation_response_mismatch")
            update_phase(directory, operation, "submitted")
            authenticate_candidate(port, domain, state["role"], password)
            result = require_response(send_request({"domain": domain,
                                                    "application": application,
                                                    "operation": "login-complete",
                                                    "operationId": operation["operationId"],
                                                    "credentialGeneration": result[
                                                        "credentialGeneration"]}),
                                      domain, application)
            if result["state"] != "ready":
                raise RequestError("completion_response_invalid")
            update_phase(directory, operation, "acknowledged")
            install_profile(directory, domain, application, state["schema"], state["role"],
                            result["credentialGeneration"], operation["operationId"], port)
            clear_completed_pending(directory)
            print(json.dumps({"domain": domain, "application": application,
                              "role": state["role"], "credentialGeneration": result[
                                  "credentialGeneration"], "serviceFile": str(directory / "service.conf"),
                              "inventoryReadback": lifecycle_readback({**result, "operation": "login-complete"})}))


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 2 and argv[0] == "enroll-migrator":
            domain = argv[1]
            if not DOMAIN.fullmatch(domain) or domain in {
                "postgres",
                "template0",
                "template1",
                "automation_data_control",
            }:
                raise ValueError("invalid_domain")
            enroll_migrator(domain)
            return 0
        if len(argv) not in (3, 4):
            raise ValueError("invalid_arguments")
        action, domain, application = argv[:3]
        schema = argv[3] if len(argv) == 4 else None
        if (
            action not in {"register", "activate", "validate", "rotate"}
            or (action == "register") != (schema is not None)
            or not DOMAIN.fullmatch(domain)
            or domain in {"postgres", "template0", "template1", "automation_data_control"}
            or not APPLICATION.fullmatch(application)
            or (
                schema is not None
                and (
                    not SCHEMA.fullmatch(schema)
                    or schema.startswith("pg_")
                    or schema in {"public", "information_schema"}
                )
            )
        ):
            raise ValueError("invalid_arguments")
        execute(action, domain, application, schema)
        return 0
    except Exception:  # noqa: BLE001 - never print a response body, token, or candidate
        print(
            "Automation-data login operation failed; retained candidate if present.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
