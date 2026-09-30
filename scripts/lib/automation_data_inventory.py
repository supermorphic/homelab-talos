"""Bounded credential metadata contracts; never accepts credential payloads."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime

MAX_OBJECTS = 1000
MAX_SOURCE_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
DEADLINE_SECONDS = 30
FRESH_SECONDS = 60
SCHEMA_REVISIONS = {
    "platform": "automation-data-discovery-v1",
    "nocodb": "nocodb-2026.08.2-v1",
    "n8n": "n8n-2.36.7-v1",
}
ERROR_CODES = {
    "source_unavailable",
    "unsupported_schema",
    "limit_exceeded",
    "unstable",
    "invalid_response",
    "stale",
    "authentication_required",
    "authentication_failed",
}
IDENTIFIER = re.compile(r"^[A-Za-z0-9_:.\-/]{1,128}$")
DOMAIN = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
SMALL_NAME = re.compile(r"^[a-z][a-z0-9_]{0,23}$")
KINDS = {
    "platform": {
        "domain": {
            "domain",
            "database",
            "ownerRole",
            "migratorRole",
            "runtimeRole",
            "state",
            "generation",
            "migratorCredentialId",
            "runtimeCredentialId",
            "migratorUpdatedAt",
            "runtimeUpdatedAt",
            "updatedAt",
        },
        "mapping": {"domain", "pair", "readerSchema", "operatorSchema"},
        "source": {
            "domain",
            "pair",
            "accessKind",
            "role",
            "state",
            "operation",
            "generation",
            "credentialGeneration",
            "baseId",
            "integrationId",
            "sourceId",
            "updatedAt",
            "validatedAt",
            "errorCode",
        },
        "claim": {
            "domain",
            "pair",
            "operationId",
            "phase",
            "operation",
            "accessKind",
            "generation",
        },
        "application": {
            "domain",
            "application",
            "schema",
            "role",
            "state",
            "operation",
            "operationId",
            "credentialGeneration",
            "updatedAt",
            "errorCode",
        },
        "role": {
            "role",
            "login",
            "superuser",
            "createDb",
            "createRole",
            "inherit",
            "replication",
            "bypassRls",
        },
    },
    "nocodb": {
        "workspace": set(),
        "base": {"workspaceId"},
        "integration": {"workspaceId", "type", "subType", "updatedAt"},
        "source": {
            "workspaceId",
            "baseId",
            "integrationId",
            "dataEditAllowed",
            "schemaEditAllowed",
            "enabled",
            "deleted",
            "intrinsic",
            "updatedAt",
        },
        "account": set(),
        "membership": {"accountId", "baseId", "workspaceId", "access"},
        "api_token": {"expiresAt", "updatedAt"},
    },
    "n8n": {
        "credential": {"name", "type", "updatedAt"},
        "workflow": {"published", "versionId"},
        "binding": {"workflowId", "node", "credentialId", "credentialType", "published"},
    },
}
BOOL_FIELDS = {
    "login",
    "superuser",
    "createDb",
    "createRole",
    "inherit",
    "replication",
    "bypassRls",
    "dataEditAllowed",
    "schemaEditAllowed",
    "enabled",
    "deleted",
    "intrinsic",
    "published",
}
GENERATION_FIELDS = {"generation", "credentialGeneration"}
STATES = {
    "awaiting_grants",
    "provisioning",
    "waiting_for_source",
    "activating",
    "ready",
    "rotating",
    "error",
}
FIXED_CREDENTIAL_NAMES = {
    "Automation Data Provisioner",
    "Automation Data n8n API",
    "Automation Data Provisioning Header",
    "NocoDB Operator API",
    "NocoDB Source Provisioning Header",
    "NocoDB Acceptance Header",
    "Platform Canary Header",
    "Automation Data Inventory Reader",
    "NocoDB Inventory Reader",
    "n8n Inventory Reader",
    "Automation Data Inventory Header",
}


class InventoryError(ValueError):
    """A fixed, safe reason code; never include raw input in errors."""


@dataclass
class DiscoveryRequest:
    action: str = "list"
    domain: str | None = None
    purpose: str | None = None
    application: str | None = None
    pair: str | None = None
    access_kind: str | None = None
    format: str = "text"


@dataclass
class SourceObservation:
    source: str
    status: str
    schema_revision: str | None = None
    observed_at: str | None = None
    received_at: str | None = None
    complete: bool = False
    object_count: int = 0
    fingerprint: str | None = None
    objects: list[dict] = field(default_factory=list)
    error_code: str | None = None


@dataclass
class InventoryEnvelope:
    schema_version: int = 1
    observed_at: str | None = None
    sources: list[dict] = field(default_factory=list)
    items: list[dict] = field(default_factory=list)
    discrepancies: list[dict] = field(default_factory=list)


@dataclass
class Resolution:
    decision: str
    prerequisites: list[dict] = field(default_factory=list)
    identity: dict | None = None
    next_action: dict | None = None
    authority_requirements: str = "Apply repository policy and existing task authorization."


def timestamp(value: object) -> datetime:
    if not isinstance(value, str) or len(value) > 40:
        raise InventoryError("invalid_response")
    try:
        result = datetime.fromisoformat(value)
    except ValueError:
        raise InventoryError("invalid_response") from None
    if result.tzinfo is None:
        raise InventoryError("invalid_response")
    return result.astimezone(UTC)


def _validate_object(raw: object, source: str) -> dict:
    if not isinstance(raw, dict) or raw.get("kind") not in KINDS[source]:
        raise InventoryError("invalid_response")
    allowed = KINDS[source][raw["kind"]] | {"kind", "id"}
    if (
        raw.keys() - allowed
        or not isinstance(raw.get("id"), str)
        or not IDENTIFIER.fullmatch(raw["id"])
    ):
        raise InventoryError("invalid_response")
    result = dict(raw)
    for key, value in raw.items():
        if value is None:
            continue
        if key in BOOL_FIELDS:
            if type(value) is not bool:
                raise InventoryError("invalid_response")
        elif key in GENERATION_FIELDS:
            if type(value) is not int or value < 0:
                raise InventoryError("invalid_response")
        elif key.endswith("At"):
            timestamp(value)
        elif key == "name":
            if not isinstance(value, str) or len(value) > 128:
                raise InventoryError("invalid_response")
            if value not in FIXED_CREDENTIAL_NAMES and not re.fullmatch(
                r"automation-data/[a-z][a-z0-9_]{0,47}/(runtime|migrator)", value
            ):
                result["name"] = None
        elif key == "state":
            if value not in STATES:
                raise InventoryError("invalid_response")
        elif key == "errorCode":
            # Error content is not useful evidence of object identity.
            result[key] = "operation_error" if value else None
        elif not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
            raise InventoryError("invalid_response")
    return result


def validate_observation(raw: object, source: str) -> SourceObservation:
    if source not in SCHEMA_REVISIONS:
        raise InventoryError("invalid_response")
    try:
        size = len(json.dumps(raw, ensure_ascii=False).encode())
    except (TypeError, ValueError, RecursionError):
        raise InventoryError("invalid_response") from None
    if size > MAX_SOURCE_BYTES:
        raise InventoryError("limit_exceeded")
    if (
        not isinstance(raw, dict)
        or raw.keys()
        - {
            "source",
            "status",
            "schemaRevision",
            "observedAt",
            "receivedAt",
            "complete",
            "objectCount",
            "fingerprint",
            "objects",
            "errorCode",
        }
        or raw.get("source") != source
        or type(raw.get("complete")) is not bool
    ):
        raise InventoryError("invalid_response")
    if raw.get("status") != "ok" or not raw["complete"]:
        code = raw.get("errorCode")
        if code not in ERROR_CODES:
            code = "source_unavailable"
        return SourceObservation(source=source, status="unavailable", error_code=code)
    if raw.get("schemaRevision") != SCHEMA_REVISIONS[source]:
        raise InventoryError("unsupported_schema")
    timestamp(raw.get("observedAt"))
    objects = raw.get("objects")
    if not isinstance(objects, list):
        raise InventoryError("invalid_response")
    if len(objects) > MAX_OBJECTS:
        raise InventoryError("limit_exceeded")
    clean = [_validate_object(obj, source) for obj in objects]
    keys = [(obj["kind"], obj["id"]) for obj in clean]
    if len(keys) != len(set(keys)) or ("objectCount" in raw and raw["objectCount"] != len(clean)):
        raise InventoryError("invalid_response")
    clean.sort(key=lambda obj: (obj["kind"], obj["id"]))
    body = json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    fingerprint = hashlib.sha256(body).hexdigest()
    return SourceObservation(
        source,
        "ok",
        SCHEMA_REVISIONS[source],
        raw["observedAt"],
        raw.get("receivedAt"),
        True,
        len(clean),
        fingerprint,
        clean,
    )


def to_wire(value: object) -> dict:
    """Use one serializer for the versioned public field names."""
    rename = {
        "schema_version": "schemaVersion",
        "schema_revision": "schemaRevision",
        "observed_at": "observedAt",
        "received_at": "receivedAt",
        "object_count": "objectCount",
        "error_code": "errorCode",
        "next_action": "nextAction",
        "authority_requirements": "authorityRequirements",
    }
    return {rename.get(key, key): item for key, item in asdict(value).items()}
