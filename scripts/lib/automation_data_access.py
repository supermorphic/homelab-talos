"""Fixed private inventory transport and non-secret workstation profile inspection."""

from __future__ import annotations

import http.client
import json
import os
import re
import ssl
import stat
import time
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path

from automation_data_client import (
    PrivateFileError,
    validate_private_directory,
    validate_private_file,
)
from automation_data_inventory import (
    DEADLINE_SECONDS,
    DOMAIN,
    MAX_RESPONSE_BYTES,
    SMALL_NAME,
    DiscoveryRequest,
    InventoryError,
    SourceObservation,
    build_inventory,
    lifecycle_evidence,
    resolve,
    timestamp,
    validate_observation,
    validate_request,
)

INVENTORY_HOST = "n8n.lab.supermorphic.com"
INVENTORY_PATH = "/webhook/automation-data-credential-inventory"


@dataclass(frozen=True)
class AccessConfig:
    inventory_auth_file: Path
    application_profile_root: Path
    migrator_profile_root: Path


@dataclass(frozen=True)
class ProfileMetadata:
    status: str
    service_file: Path | None = None
    service: str | None = None
    local_port: int | None = None
    binding: dict | None = None
    file_signature: tuple | None = None
    automatic: bool = False


def file_signature(paths: list[Path]) -> tuple:
    """Remember file identity and changes without opening credential contents."""
    result = []
    for path in paths:
        info = safe_path(path).stat()
        result.append((str(path), info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns))
    return tuple(result)


def safe_path(path: Path | str, *, directory: bool = False) -> Path:
    """Reject checkout paths and symlinks in any ancestor; require a private selected path."""
    selected = Path(path)
    if not selected.is_absolute() or ".." in selected.parts:
        raise PrivateFileError("unsafe_private_path")
    try:
        for parent in (
            [*reversed(selected.parents), selected] if directory else reversed(selected.parents)
        ):
            info = parent.lstat()
            if (
                not stat.S_ISDIR(info.st_mode)
                or (parent / ".git").exists()
                or (parent / ".git").is_symlink()
            ):
                raise PrivateFileError("unsafe_private_path")
            if info.st_mode & 0o022 and not (info.st_mode & stat.S_ISVTX):
                raise PrivateFileError("unsafe_private_path")
        if directory:
            return validate_private_directory(selected)
        validate_private_directory(selected.parent)
        return validate_private_file(selected)
    except OSError:
        raise PrivateFileError("unsafe_private_path") from None


def load_access_config() -> AccessConfig:
    raw = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    selected = Path(raw) / "homelab" / "automation-data" / "access.json"
    if not Path(raw).is_absolute():
        raise PrivateFileError("invalid_access_configuration")
    if not selected.exists() and not selected.is_symlink():
        raise PrivateFileError("access_setup_required")
    try:
        path = safe_path(selected)
        if path.stat().st_size > 16384:
            raise PrivateFileError("invalid_access_configuration")
        data = json.loads(path.read_text())
        if (
            not isinstance(data, dict)
            or set(data)
            != {
                "schemaVersion",
                "inventoryAuthFile",
                "applicationProfileRoot",
                "migratorProfileRoot",
            }
            or type(data["schemaVersion"]) is not int
            or data["schemaVersion"] != 1
        ):
            raise PrivateFileError("invalid_access_configuration")
        if any(not isinstance(data[key], str) for key in data if key != "schemaVersion"):
            raise PrivateFileError("invalid_access_configuration")
        auth = Path(data["inventoryAuthFile"])
        # Missing auth is an enrollment prerequisite. Validate its owned parent without opening it.
        safe_path(auth.parent, directory=True)
        if auth.exists() or auth.is_symlink():
            safe_path(auth)
        return AccessConfig(
            auth,
            safe_path(data["applicationProfileRoot"], directory=True),
            safe_path(data["migratorProfileRoot"], directory=True),
        )
    except (KeyError, ValueError, TypeError, OSError):
        raise PrivateFileError("invalid_access_configuration") from None


def fetch_observations(config: AccessConfig, request: DiscoveryRequest) -> list[SourceObservation]:
    """Read one inventory-only token into a fixed TLS header. Never follow redirects."""
    deadline = time.monotonic() + DEADLINE_SECONDS
    connection = None
    try:
        if not config.inventory_auth_file.exists():
            raise InventoryError("authentication_required")
        path = safe_path(config.inventory_auth_file)
        if path.stat().st_size > 1024:
            raise InventoryError("authentication_failed")
        token = path.read_text().strip()
        if not token or any(
            not (character.isascii() and (character.isalnum() or character in "._-"))
            for character in token
        ):
            raise InventoryError("authentication_failed")
        body = {"action": request.action}
        for field, key in [
            ("domain", "domain"),
            ("purpose", "purpose"),
            ("application", "application"),
            ("pair", "pair"),
            ("access_kind", "accessKind"),
        ]:
            value = getattr(request, field)
            if value is not None:
                body[key] = value
        connection = http.client.HTTPSConnection(
            INVENTORY_HOST, timeout=DEADLINE_SECONDS, context=ssl.create_default_context()
        )
        connection.request(
            "POST",
            INVENTORY_PATH,
            json.dumps(body).encode(),
            {"Content-Type": "application/json", "X-Automation-Data-Inventory": token},
        )
        del token
        if connection.sock is not None:
            connection.sock.settimeout(max(0.001, deadline - time.monotonic()))
        response = connection.getresponse()
        if response.status in {401, 403}:
            raise InventoryError("authentication_failed")
        if response.status != 200:
            raise InventoryError("source_unavailable")
        length = response.getheader("Content-Length")
        if length and (not length.isdigit() or int(length) > MAX_RESPONSE_BYTES):
            raise InventoryError("limit_exceeded")
        chunks = []
        total = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise InventoryError("source_unavailable")
            if connection.sock is not None:
                connection.sock.settimeout(remaining)
            chunk = response.read1(min(65536, MAX_RESPONSE_BYTES - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_RESPONSE_BYTES:
                raise InventoryError("limit_exceeded")
            chunks.append(chunk)
        data = json.loads(b"".join(chunks))
        if (
            not isinstance(data, dict)
            or set(data) != {"schemaVersion", "sources"}
            or type(data["schemaVersion"]) is not int
            or data["schemaVersion"] != 1
            or not isinstance(data["sources"], list)
            or len(data["sources"]) != 3
        ):
            raise InventoryError("invalid_response")
        observed = {}
        received = datetime.now(UTC).isoformat()
        for raw in data["sources"]:
            if not isinstance(raw, dict) or raw.get("source") in observed:
                raise InventoryError("invalid_response")
            source = raw.get("source")
            observed[source] = validate_observation(raw, source)
            observed[source].received_at = received
        if set(observed) != {"platform", "nocodb", "n8n"}:
            raise InventoryError("invalid_response")
        return list(observed.values())
    except InventoryError:
        raise
    except Exception:  # noqa: BLE001 - never return remote exceptions or credential material
        raise InventoryError("source_unavailable") from None
    finally:
        if connection is not None:
            connection.close()


def inspect_profile(config: AccessConfig, identity: dict) -> ProfileMetadata:
    """Inspect allowlisted binding metadata and file status; do not open service/password files."""
    try:
        domain = identity["domain"]
        if not isinstance(domain, str) or not DOMAIN.fullmatch(domain):
            return ProfileMetadata("unbound")
        application = identity.get("application")
        if identity["family"] == "application":
            if not isinstance(application, str) or not SMALL_NAME.fullmatch(application):
                return ProfileMetadata("unbound")
            directory = config.application_profile_root / domain / application
            if not directory.parent.exists() and not directory.parent.is_symlink():
                return ProfileMetadata("missing")
            safe_path(directory.parent, directory=True)
        elif identity["family"] == "migration":
            directory = config.migrator_profile_root / domain
        else:
            return ProfileMetadata("unbound")
        if not directory.exists() and not directory.is_symlink():
            return ProfileMetadata("missing")
        safe_path(directory, directory=True)
        pending = directory / "pending"
        if pending.exists() or pending.is_symlink():
            safe_path(pending, directory=True)
            if (pending / "operation.json").exists() or (pending / "operation.json").is_symlink():
                return ProfileMetadata("pending")
        binding_file = directory / "binding.json"
        if not binding_file.exists() and not binding_file.is_symlink():
            return ProfileMetadata("unbound")
        safe_path(binding_file)
        if binding_file.stat().st_size > 16384:
            return ProfileMetadata("unsafe")
        binding = json.loads(binding_file.read_text())
        allowed = {
            "family",
            "domain",
            "database",
            "application",
            "schema",
            "role",
            "credentialGeneration",
            "operationId",
            "localPort",
            "service",
            "credentialId",
            "credentialUpdatedAt",
        }
        if (
            not isinstance(binding, dict)
            or set(binding) - allowed
            or any(binding.get(k) != identity.get(k) for k in ["domain", "role"])
            or binding.get("database") != domain
        ):
            return ProfileMetadata("unbound")
        port = binding.get("localPort")
        if type(port) is not int or not 1024 <= port <= 65535:
            return ProfileMetadata("unbound")
        if identity["family"] == "application":
            if binding.get("application") != application or binding.get("schema") != identity.get(
                "schema"
            ):
                return ProfileMetadata("unbound")
            generation = identity.get("credentialGeneration")
            if (
                type(generation) is not int
                or generation < 1
                or type(binding.get("credentialGeneration")) is not int
                or binding["credentialGeneration"] != generation
            ):
                return ProfileMetadata("stale")
            generation_path = safe_path(directory / f"generation-{generation}", directory=True)
            passfile = safe_path(generation_path / "credential.pgpass")
            service = f"automation_data_{domain}_{identity['role']}"
        else:
            if (
                not identity.get("credentialId")
                or not identity.get("credentialUpdatedAt")
                or binding.get("credentialId") != identity["credentialId"]
                or timestamp(binding.get("credentialUpdatedAt"))
                != timestamp(identity["credentialUpdatedAt"])
            ):
                return ProfileMetadata("stale")
            service = binding.get("service")
            if not isinstance(service, str) or not re.fullmatch(
                r"[A-Za-z][A-Za-z0-9_-]{0,127}", service
            ):
                return ProfileMetadata("unbound")
            passfile = safe_path(directory / "credential.pgpass")
        service_file = safe_path(directory / "service.conf")
        return ProfileMetadata(
            "ready",
            service_file,
            service,
            port,
            binding,
            file_signature([binding_file, service_file, passfile]),
        )
    except FileNotFoundError:
        return ProfileMetadata("missing")
    except (PrivateFileError, InventoryError, KeyError, ValueError, TypeError, OSError):
        return ProfileMetadata("unsafe")


def connection_request(domain: str, identity: str) -> DiscoveryRequest:
    request = DiscoveryRequest(
        "resolve",
        domain,
        "migration" if identity == "migrator" else "application",
        application=identity[12:] if identity.startswith("application/") else None,
    )
    validate_request(request)
    return request


def select_connection_profile(domain: str, identity: str) -> ProfileMetadata:
    """Select metadata only. Consumer secrets remain private to the connection helper."""
    request = connection_request(domain, identity)
    raw_file = os.environ.get("AUTOMATION_DATA_SERVICE_FILE")
    service = os.environ.get("AUTOMATION_DATA_SERVICE")
    if raw_file is not None or service is not None:
        if (
            not raw_file
            or not service
            or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,127}", service)
        ):
            raise PrivateFileError("partial_or_invalid_service_override")
        # Preserve the existing explicit-profile validation contract.
        return ProfileMetadata("ready", validate_private_file(Path(raw_file)), service)
    config = load_access_config()
    inventory = build_inventory(fetch_observations(config, request))
    preliminary = resolve(request, inventory)
    if preliminary.identity is None:
        raise PrivateFileError("automatic_profile_unavailable")
    profile = inspect_profile(config, preliminary.identity)
    if resolve(request, inventory, profile).decision != "ready":
        raise PrivateFileError("automatic_profile_not_ready")
    return replace(profile, automatic=True)


def revalidate_connection_profile(domain: str, identity: str, selected: ProfileMetadata) -> None:
    """Repeat fresh observation and metadata-only file checks immediately before use."""
    if selected.automatic and select_connection_profile(domain, identity) != selected:
        raise PrivateFileError("connection_profile_changed")


def assert_profile_unchanged(selected: ProfileMetadata) -> None:
    if selected.automatic:
        pending = selected.service_file.parent / "pending"
        if pending.exists() or pending.is_symlink():
            raise PrivateFileError("connection_profile_changed")
        if (
            selected.file_signature is None
            or file_signature([Path(signature[0]) for signature in selected.file_signature])
            != selected.file_signature
        ):
            raise PrivateFileError("connection_profile_changed")


def lifecycle_readback(mutation: dict) -> dict:
    """Best-effort observational evidence; failure must never erase successful mutation."""
    try:
        request = DiscoveryRequest("list", domain=mutation["domain"])
        config = load_access_config()
        return lifecycle_evidence(mutation, build_inventory(fetch_observations(config, request)))
    except Exception:  # noqa: BLE001 - return only a fixed evidence status
        return {"status": "unavailable", "observedAt": None, "errorCode": "source_unavailable"}
