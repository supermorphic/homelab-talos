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

# Purpose requires both the fixed identity name and its expected credential type.
PLATFORM_CREDENTIAL_NAMES = {
    "Automation Data Provisioner",
    "Automation Data Inventory Reader",
    "NocoDB Inventory Reader",
    "n8n Inventory Reader",
}
FIXED_CREDENTIAL_FAMILIES = {
    name: ("postgres", "platform")
    if name in PLATFORM_CREDENTIAL_NAMES
    else ("httpHeaderAuth", "api_webhook")
    for name in FIXED_CREDENTIAL_NAMES
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
    families: list[dict] = field(default_factory=list)


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
    if raw.get("receivedAt") is not None:
        timestamp(raw["receivedAt"])
    objects = raw.get("objects")
    if not isinstance(objects, list):
        raise InventoryError("invalid_response")
    if len(objects) > MAX_OBJECTS:
        raise InventoryError("limit_exceeded")
    clean = [_validate_object(obj, source) for obj in objects]
    keys = [(obj["kind"], obj["id"]) for obj in clean]
    if len(keys) != len(set(keys)) or (
        "objectCount" in raw
        and (type(raw["objectCount"]) is not int or raw["objectCount"] != len(clean))
    ):
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


FAMILY_DEFINITIONS = {
    "application": (
        "Consumer reads and reviewed functions",
        "Registered consumer",
        "Application login lifecycle",
        "Protected application profile",
        "026-automation-data-postgresql-platform.md",
    ),
    "migration": (
        "Reviewed domain schema migration",
        "Domain migrator",
        "Domain lifecycle and consumer migration owner",
        "n8n credential and separately retained protected migrator profile",
        "026-automation-data-postgresql-platform.md",
    ),
    "workflow": (
        "Normal domain processing",
        "Published n8n workflows",
        "Domain provisioner",
        "n8n Postgres credential",
        "026-automation-data-postgresql-platform.md",
    ),
    "source": (
        "One NocoDB pair and access kind",
        "NocoDB",
        "Source and pair lifecycle",
        "NocoDB encrypted integration; contents are not observed",
        "028-nocodb-operator-ui.md",
    ),
    "ui": (
        "Human authentication and membership",
        "NocoDB UI users",
        "Operator-managed UI lifecycle",
        "Opaque NocoDB identity metadata",
        "028-nocodb-operator-ui.md",
    ),
    "api_webhook": (
        "Authenticate a fixed API or webhook",
        "Named automation workflow",
        "Workflow/bootstrap owner",
        "Named n8n credential or protected caller material",
        "023-n8n-workflow-automation-platform.md",
    ),
    "platform": (
        "Metadata, provisioning, backup, exporter, and inventory access",
        "Platform components",
        "Platform operator",
        "Existing encrypted configuration or restricted n8n binding",
        "026-automation-data-postgresql-platform.md",
    ),
    "recovery": (
        "Encryption, signing, and retained recovery material",
        "Attended platform recovery",
        "Platform operator",
        "not_observed",
        "023-n8n-workflow-automation-platform.md",
    ),
    "unclassified": (
        "Purpose is not established by metadata",
        "not_observed",
        "Ownership is not established by metadata",
        "Observed opaque identity only",
        "028-nocodb-operator-ui.md",
    ),
}
PLATFORM_ROLES = {
    "postgres",
    "nocodb",
    "automation_data_provisioner",
    "automation_data_backup",
    "automation_data_exporter",
    "automation_data_inventory",
    "automation_data_inventory_projection",
    "nocodb_inventory",
    "nocodb_inventory_projection",
}


def validate_request(request: DiscoveryRequest) -> None:
    if request.action not in {"list", "resolve"} or request.format not in {"text", "json"}:
        raise InventoryError("invalid_arguments")
    if request.domain is not None and (
        not DOMAIN.fullmatch(request.domain)
        or request.domain in {"postgres", "template0", "template1", "automation_data_control"}
    ):
        raise InventoryError("invalid_arguments")
    if request.action == "list":
        if any(
            value is not None
            for value in [request.purpose, request.application, request.pair, request.access_kind]
        ):
            raise InventoryError("invalid_arguments")
        return
    if not request.domain or request.purpose not in {
        "application",
        "migration",
        "workflow",
        "source",
    }:
        raise InventoryError("invalid_arguments")
    if request.purpose == "application":
        if (
            not isinstance(request.application, str)
            or not SMALL_NAME.fullmatch(request.application)
            or request.pair is not None
            or request.access_kind is not None
        ):
            raise InventoryError("invalid_arguments")
    elif request.purpose == "source":
        if (
            request.application is not None
            or not SMALL_NAME.fullmatch(request.pair or "default")
            or request.access_kind not in {"reader", "operator"}
        ):
            raise InventoryError("invalid_arguments")
    elif any(
        value is not None for value in [request.application, request.pair, request.access_kind]
    ):
        raise InventoryError("invalid_arguments")


def _fresh(source: dict) -> bool:
    try:
        age = (datetime.now(UTC) - timestamp(source.get("observedAt"))).total_seconds()
        return (
            source.get("complete") is True
            and source.get("status") == "ok"
            and 0 <= age <= FRESH_SECONDS
        )
    except InventoryError:
        return False


def _item(family: str, identity: str, facts: dict, sources: list[str], available: dict) -> dict:
    purpose, consumer, owner, storage, procedure = FAMILY_DEFINITIONS[family]
    return {
        "family": family,
        "id": identity,
        "purpose": purpose,
        "consumer": consumer,
        "lifecycleOwner": owner,
        "storageLocator": storage,
        "procedures": {
            stage: "docs/specs/" + procedure
            for stage in ["provision", "rotate", "recover", "decommission"]
        },
        "requiredSources": sources,
        "complete": all(available.get(s, {}).get("complete") is True for s in sources),
        "observationTimes": {s: available.get(s, {}).get("observedAt") for s in sources},
        "classification": "managed",
        "evidence": {},
        "discrepancies": [],
        **facts,
    }


def build_inventory(observations: list[SourceObservation]) -> InventoryEnvelope:
    """Join independently enumerated allowlisted objects by retained identities."""
    available = {}
    rows = {s: [] for s in SCHEMA_REVISIONS}
    for observation in observations:
        source = observation.source
        if source not in SCHEMA_REVISIONS or source in available:
            raise InventoryError("invalid_response")
        try:
            clean = validate_observation(to_wire(observation), source)
        except InventoryError as error:
            clean = SourceObservation(source, "unavailable", error_code=str(error))
        summary = to_wire(clean)
        summary["receivedAt"] = clean.received_at or datetime.now(UTC).isoformat()
        if clean.complete and not _fresh(summary):
            summary.update(
                status="unavailable",
                complete=False,
                errorCode="stale",
                objects=[],
                objectCount=0,
                fingerprint=None,
            )
        available[source] = summary
        if summary["complete"]:
            rows[source] = summary["objects"]
    for source in SCHEMA_REVISIONS:
        if source not in available:
            available[source] = to_wire(
                SourceObservation(source, "unavailable", error_code="source_unavailable")
            )
    by_kind = {s: {} for s in SCHEMA_REVISIONS}
    for source, objects in rows.items():
        for obj in objects:
            by_kind[source].setdefault(obj["kind"], {})[obj["id"]] = obj
    get = lambda source, kind, identity: by_kind[source].get(kind, {}).get(identity)
    items = []
    discrepancies = []
    used_roles = set()
    used_noco = set()
    used_credentials = set()

    def issue(item, code, source, expected=None, observed=None):
        discrepancy = {
            "identity": item["id"],
            "code": code,
            "source": source,
            "expected": expected,
            "observed": observed,
        }
        item["discrepancies"].append(discrepancy)
        discrepancies.append(discrepancy)

    def role_evidence(item, role):
        used_roles.add(role)
        observed = get("platform", "role", role)
        item["evidence"]["role"] = observed
        if role is not None and available["platform"]["complete"] and observed is None:
            issue(item, "missing_role", "platform", role, None)

    # Registry intent and PostgreSQL existence are enumerated independently.
    for domain in by_kind["platform"].get("domain", {}).values():
        for family, label in [("migration", "migrator"), ("workflow", "runtime")]:
            name = domain.get("domain")
            role = domain.get(label + "Role")
            credential_id = domain.get(label + "CredentialId")
            item = _item(
                family,
                f"{family}:{domain['id']}",
                {
                    "domain": name,
                    "database": domain.get("database"),
                    "role": role,
                    "state": domain.get("state"),
                    "operationGeneration": domain.get("generation"),
                    "credentialGeneration": None,
                    "credentialId": credential_id,
                    "credentialUpdatedAt": domain.get(label + "UpdatedAt"),
                    "registered": True,
                },
                ["platform", "n8n"],
                available,
            )
            role_evidence(item, role)
            if name and (
                domain["id"] != name or domain.get("database") != name or role != f"{name}_{label}"
            ):
                issue(item, "registered_identity_mismatch", "platform")
            credential = get("n8n", "credential", credential_id)
            item["evidence"]["credential"] = credential
            item["evidence"]["bindings"] = [
                o
                for o in by_kind["n8n"].get("binding", {}).values()
                if o.get("credentialId") == credential_id
                and o.get("published") is True
                and get("n8n", "workflow", o.get("workflowId")) is not None
                and get("n8n", "workflow", o.get("workflowId")).get("published") is True
            ]
            if credential_id:
                used_credentials.add(credential_id)
            if available["n8n"]["complete"] and domain.get("state") == "ready":
                if credential_id is not None and credential is None:
                    issue(item, "missing_credential", "n8n", credential_id, None)
                elif credential is not None and (
                    credential.get("type") != "postgres"
                    or credential.get("name") != f"automation-data/{name}/{label}"
                ):
                    issue(
                        item,
                        "credential_binding_mismatch",
                        "n8n",
                        credential_id,
                        credential.get("id"),
                    )
                elif credential is not None:
                    try:
                        if timestamp(item["credentialUpdatedAt"]) != timestamp(
                            credential.get("updatedAt")
                        ):
                            issue(
                                item,
                                "credential_marker_mismatch",
                                "n8n",
                                item["credentialUpdatedAt"],
                                credential.get("updatedAt"),
                            )
                    except InventoryError:
                        issue(item, "unknown_credential_marker", "n8n")
                matches = [
                    o
                    for o in by_kind["n8n"].get("credential", {}).values()
                    if o.get("name") == f"automation-data/{name}/{label}"
                ]
                if len(matches) > 1:
                    issue(
                        item,
                        "duplicate_credential",
                        "n8n",
                        credential_id,
                        [o["id"] for o in matches],
                    )
            items.append(item)
    for registration in by_kind["platform"].get("application", {}).values():
        item = _item(
            "application",
            "application:" + registration["id"],
            {
                "domain": registration.get("domain"),
                "application": registration.get("application"),
                "database": registration.get("domain"),
                "schema": registration.get("schema"),
                "role": registration.get("role"),
                "state": registration.get("state"),
                "operation": registration.get("operation"),
                "operationId": registration.get("operationId"),
                "credentialGeneration": registration.get("credentialGeneration"),
                "operationGeneration": None,
                "registered": True,
            },
            ["platform"],
            available,
        )
        role_evidence(item, item["role"])
        domain, application = item.get("domain"), item.get("application")
        if domain and application:
            registered_id = f"{domain}:{application}"
            expected_role = (
                "app_"
                + hashlib.md5(registered_id.encode(), usedforsecurity=False).hexdigest()
                + "_integration"
            )
            if registration["id"] != registered_id or item.get("role") != expected_role:
                issue(item, "registered_identity_mismatch", "platform")
        items.append(item)
    source_items = []
    for registration in by_kind["platform"].get("source", {}).values():
        facts = {
            key: value
            for key, value in registration.items()
            if key not in {"kind", "id", "generation"}
        }
        item = _item(
            "source",
            "source:" + registration["id"],
            {**facts, "operationGeneration": registration.get("generation"), "registered": True},
            ["platform", "nocodb"],
            available,
        )
        role_evidence(item, item.get("role"))
        domain, pair, kind = item.get("domain"), item.get("pair"), item.get("accessKind")
        if domain and pair and kind:
            prefix = (
                domain
                if pair == "default"
                else "nocodb_"
                + hashlib.md5(f"{domain}:{pair}".encode(), usedforsecurity=False).hexdigest()
            )
            if (
                registration["id"] != f"{domain}:{pair}:{kind}"
                or item.get("role") != f"{prefix}_{kind}"
            ):
                issue(item, "registered_identity_mismatch", "platform")
        claim = get("platform", "claim", f"{item.get('domain')}:{item.get('pair')}")
        item["evidence"]["claim"] = claim
        mapping = get("platform", "mapping", f"{item.get('domain')}:{item.get('pair')}")
        item["mappingOrigin"] = "registered" if mapping is not None else "not_observed"
        if mapping is None and item.get("pair") == "default":
            # The existing default lifecycle uses these built-in schema names when
            # no custom mapping is registered. This is a procedure-derived expectation,
            # not an observation of source configuration or database grants.
            mapping = {
                "domain": item.get("domain"),
                "pair": "default",
                "readerSchema": "read_model",
                "operatorSchema": "operator",
            }
            item["mappingOrigin"] = "built_in_default"
        item["evidence"]["mapping"] = mapping
        if claim is not None and claim.get("phase") != "complete":
            issue(item, "uncertain_claim", "platform", None, claim.get("operationId"))
        for kind, key in [
            ("source", "sourceId"),
            ("integration", "integrationId"),
            ("base", "baseId"),
        ]:
            identity = item.get(key)
            obj = get("nocodb", kind, identity)
            item["evidence"][kind] = obj
            if identity:
                used_noco.add((kind, identity))
            if (
                identity is not None
                and item.get("state") == "ready"
                and available["nocodb"]["complete"]
                and obj is None
            ):
                issue(item, "missing_" + kind, "nocodb", identity, None)
        observed = item["evidence"]["source"]
        integration = item["evidence"]["integration"]
        base = item["evidence"]["base"]
        if (
            item.get("state") == "ready"
            and observed is not None
            and integration is not None
            and base is not None
        ):
            expected = {
                "baseId": item.get("baseId"),
                "integrationId": item.get("integrationId"),
                "workspaceId": base.get("workspaceId"),
                "dataEditAllowed": item.get("accessKind") == "operator",
                "schemaEditAllowed": False,
                "enabled": True,
                "deleted": False,
                "intrinsic": False,
            }
            if (
                any(
                    type(observed.get(k)) is not type(v) or observed.get(k) != v
                    for k, v in expected.items()
                )
                or integration.get("workspaceId") != base.get("workspaceId")
                or integration.get("type") != "database"
                or integration.get("subType") != "pg"
            ):
                issue(
                    item,
                    "source_binding_mismatch",
                    "nocodb",
                    expected,
                    {k: observed.get(k) for k in expected},
                )
        source_items.append(item)
        items.append(item)
    for key in ["sourceId", "integrationId"]:
        assignments = {}
        for item in source_items:
            if item.get(key):
                assignments.setdefault(item[key], []).append(item)
        for identity, assigned in assignments.items():
            if len(assigned) > 1:
                for item in assigned:
                    issue(item, "duplicate_assignment", "platform", key, identity)
    # Installed-only objects are visible without guessing ownership from a name.
    for role in by_kind["platform"].get("role", {}).values():
        if role["id"] in used_roles:
            continue
        family = "platform" if role["id"] in PLATFORM_ROLES else "unclassified"
        item = _item(
            family,
            "role:" + role["id"],
            {"role": role["id"], "registered": False, "state": None},
            ["platform"],
            available,
        )
        item["classification"] = "platform" if family == "platform" else "unclassified"
        item["evidence"]["role"] = role
        items.append(item)
    for credential in by_kind["n8n"].get("credential", {}).values():
        if credential["id"] in used_credentials:
            continue
        expected = FIXED_CREDENTIAL_FAMILIES.get(credential.get("name"))
        known = expected is not None and credential.get("type") == expected[0]
        item = _item(
            expected[1] if known else "unclassified",
            "credential:" + credential["id"],
            {
                "credentialId": credential["id"],
                "credentialName": credential.get("name"),
                "registered": False,
                "state": None,
            },
            ["n8n"],
            available,
        )
        item["classification"] = "known" if known else "unclassified"
        item["storageLocator"] = "n8n credential/" + credential["id"]
        item["evidence"]["credential"] = credential
        items.append(item)
    for kind, objects in by_kind["nocodb"].items():
        for obj in objects.values():
            if (kind, obj["id"]) in used_noco:
                continue
            family = (
                "ui"
                if kind in {"account", "membership"}
                else "api_webhook"
                if kind == "api_token"
                else "unclassified"
            )
            classification = (
                "intrinsic"
                if kind == "source"
                and obj.get("intrinsic") is True
                and obj.get("integrationId") is None
                else "unclassified"
            )
            item = _item(
                family,
                "nocodb:" + kind + ":" + obj["id"],
                {"registered": False, "state": None, "classification": classification},
                ["nocodb"],
                available,
            )
            item["evidence"][kind] = obj
            items.append(item)
    for binding in by_kind["n8n"].get("binding", {}).values():
        if (
            binding.get("published") is True
            and get("n8n", "credential", binding.get("credentialId")) is None
        ):
            discrepancies.append(
                {
                    "identity": "binding:" + binding["id"],
                    "code": "missing_credential",
                    "source": "n8n",
                    "expected": binding.get("credentialId"),
                    "observed": None,
                }
            )
    assignments = {}
    for binding in by_kind["n8n"].get("binding", {}).values():
        if binding.get("published") is True:
            key = (binding.get("workflowId"), binding.get("node"), binding.get("credentialType"))
            assignments.setdefault(key, []).append(binding)
    for bindings in assignments.values():
        if len(bindings) > 1:
            affected = {binding.get("credentialId") for binding in bindings}
            for item in items:
                if item.get("credentialId") in affected:
                    issue(item, "ambiguous_workflow_binding", "n8n")
    summaries = [
        {k: v for k, v in available[s].items() if k != "objects"} for s in SCHEMA_REVISIONS
    ]
    families = [
        {
            "family": family,
            "purpose": definition[0],
            "consumer": definition[1],
            "lifecycleOwner": definition[2],
            "storageLocator": definition[3],
            "procedure": "docs/specs/" + definition[4],
            "observationStatus": "not_observed" if family == "recovery" else "metadata_only",
            "decommissionStatus": "requires_separately_reviewed_operator_procedure",
        }
        for family, definition in FAMILY_DEFINITIONS.items()
    ]
    envelope = InventoryEnvelope(
        observed_at=datetime.now(UTC).isoformat(),
        sources=summaries,
        items=sorted(items, key=lambda item: item["id"]),
        discrepancies=discrepancies,
        families=families,
    )
    return envelope


def resolve(request: DiscoveryRequest, inventory: InventoryEnvelope, profile=None) -> Resolution:
    """Readiness is observed prerequisites, never task authorization or authentication proof."""
    validate_request(request)
    required = {
        "application": ["platform"],
        "migration": ["platform", "n8n"],
        "workflow": ["platform", "n8n"],
        "source": ["platform", "nocodb"],
    }[request.purpose]
    sources = {source["source"]: source for source in inventory.sources}
    if any(not _fresh(sources.get(source, {})) for source in required):
        return Resolution(
            "unavailable",
            [{"name": "fresh_complete_metadata", "status": "unavailable"}],
            next_action={
                "kind": "procedure",
                "reference": "docs/specs/026-automation-data-postgresql-platform.md#private-credential-discovery-installation",
                "owner": "Platform operator",
            },
        )
    selected = [
        item
        for item in inventory.items
        if item["family"] == request.purpose
        and item.get("domain") == request.domain
        and (request.purpose != "application" or item.get("application") == request.application)
        and (
            request.purpose != "source"
            or (
                item.get("pair") == (request.pair or "default")
                and item.get("accessKind") == request.access_kind
            )
        )
    ]
    if len(selected) != 1:
        return Resolution(
            "inconsistent" if selected else "setup_required",
            [{"name": "registered_identity", "status": "ambiguous" if selected else "missing"}],
            next_action={
                "kind": "procedure",
                "reference": "docs/specs/026-automation-data-postgresql-platform.md",
                "owner": "Lifecycle owner",
            },
        )
    item = selected[0]
    procedure = {
        "kind": "procedure",
        "reference": item["procedures"]["recover"],
        "owner": item["lifecycleOwner"],
    }
    prerequisites = []

    def result(decision, name, status, action=procedure):
        return Resolution(
            decision,
            [*prerequisites, {"name": name, "status": status}],
            item,
            action,
            {
                "application": "Requires authorization for the selected application's routine work and the supported private connection helper.",
                "migration": "Requires authorization for the specific reviewed migration; migrator readiness does not authorize schema changes.",
                "workflow": "Requires authorization for the selected workflow operation; binding metadata does not authorize credential export.",
                "source": "Status inspection uses the approved scoped workflow. Provisioning, rotation, and removal require their separate lifecycle authority.",
            }[request.purpose],
        )

    if item["discrepancies"]:
        return result(
            "recovery_required"
            if all(d["code"] == "uncertain_claim" for d in item["discrepancies"])
            else "inconsistent",
            "consistent_bindings",
            "blocked",
        )
    if item.get("state") != "ready":
        return result(
            "setup_required"
            if item.get("state") in {"awaiting_grants", "provisioning", "activating"}
            else "recovery_required",
            "registered_state",
            item.get("state") or "unknown",
        )
    role = item["evidence"].get("role")
    if role is None or any(
        type(role.get(key)) is not bool
        for key in [
            "login",
            "superuser",
            "createDb",
            "createRole",
            "inherit",
            "replication",
            "bypassRls",
        ]
    ):
        return result("unavailable", "role_attributes", "unknown")
    if role["login"] is not True or any(
        role[key]
        for key in ["superuser", "createDb", "createRole", "inherit", "replication", "bypassRls"]
    ):
        return result("inconsistent", "bounded_login_authority", "blocked")
    prerequisites.append({"name": "registered_ready_login", "status": "observed"})
    if request.purpose in {"migration", "workflow"}:
        if (
            not item.get("credentialId")
            or not item.get("credentialUpdatedAt")
            or not item["evidence"].get("credential")
        ):
            return result("unavailable", "credential_identity_and_marker", "unknown")
        if request.purpose == "workflow":
            bindings = item["evidence"].get("bindings", [])
            if not bindings or any(
                binding.get("credentialType") != "postgres" for binding in bindings
            ):
                return result("setup_required", "published_workflow_binding", "missing")
            return result(
                "ready",
                "published_workflow_binding",
                "observed",
                {
                    "kind": "workflow_binding",
                    "workflowIds": sorted({b["workflowId"] for b in bindings}),
                    "credentialId": item["credentialId"],
                },
            )
    if request.purpose == "source":
        if item["evidence"].get("mapping") is None or any(
            item["evidence"].get(kind) is None for kind in ["source", "integration", "base"]
        ):
            return result("unavailable", "source_binding", "unknown")
        mapping = item["evidence"]["mapping"]
        base = item["evidence"]["base"]
        if not base.get("workspaceId") or not mapping.get(request.access_kind + "Schema"):
            return result("unavailable", "source_workspace_and_schema", "unknown")
        if type(item.get("credentialGeneration")) is not int or item["credentialGeneration"] < 1:
            return result("unavailable", "credential_generation", "unknown")
        action = {
            "kind": "recipe",
            "recipe": "nocodb-source-status"
            if request.pair in {None, "default"}
            else "nocodb-pair-status",
            "arguments": [request.domain]
            if request.pair in {None, "default"}
            else [request.domain, request.pair],
        }
        return result("ready", "registered_source_metadata", "observed", action)
    if request.purpose == "application" and (
        type(item.get("credentialGeneration")) is not int
        or item["credentialGeneration"] < 1
        or not item.get("schema")
    ):
        return result("unavailable", "acknowledged_credential_generation", "unknown")
    if profile is None or profile.status != "ready":
        status = "missing" if profile is None else profile.status
        return result(
            "setup_required" if status == "missing" else "recovery_required",
            "protected_current_profile",
            status,
        )
    identity = (
        "migrator" if request.purpose == "migration" else "application/" + request.application
    )
    return result(
        "ready",
        "protected_current_profile",
        "observed",
        {
            "kind": "recipe",
            "recipe": "automation-data-connect",
            "arguments": [request.domain, identity],
        },
    )


def render_result(result: InventoryEnvelope | Resolution, format: str) -> str:
    wire = {
        "schemaVersion": 1,
        **({"resolution": to_wire(result)} if isinstance(result, Resolution) else to_wire(result)),
    }
    if format == "json":
        return json.dumps(wire, sort_keys=True)
    heading = (
        result.decision + "; authentication and authorization are separate."
        if isinstance(result, Resolution)
        else "Credential metadata inventory; authentication and authorization are separate."
    )
    return heading + "\n" + json.dumps(wire, indent=2, sort_keys=True)


def lifecycle_evidence(mutation: dict, inventory: InventoryEnvelope) -> dict:
    """Observe the mutation's retained metadata without changing its outcome."""
    operation = mutation.get("operation", "")
    family = (
        "application"
        if operation.startswith("login-")
        else "source"
        if operation in {"configure", "register", "prepare", "sync", "rotate"}
        else "migration"
    )
    required = (
        ["platform"]
        if family == "application"
        else ["platform", "nocodb" if family == "source" else "n8n"]
    )
    summaries = {s["source"]: s for s in inventory.sources}
    if any(not _fresh(summaries.get(s, {})) for s in required):
        return {"status": "unavailable", "observedAt": None, "errorCode": "source_unavailable"}
    observed_at = min((summaries[s]["observedAt"] for s in required), key=timestamp)
    targets = [
        i
        for i in inventory.items
        if i["family"] == family and i.get("domain") == mutation.get("domain")
    ]
    if family == "application":
        targets = [i for i in targets if i.get("application") == mutation.get("application")]
        matches = (
            len(targets) == 1
            and all(
                targets[0].get(k) == mutation.get(k)
                for k in ["role", "state", "credentialGeneration"]
            )
            and not targets[0]["discrepancies"]
        )
    elif family == "migration":
        matches = (
            len(targets) == 1
            and targets[0].get("credentialId") == mutation.get("migratorCredentialId")
            and not targets[0]["discrepancies"]
        )
        runtime = [
            i
            for i in inventory.items
            if i["family"] == "workflow" and i.get("domain") == mutation.get("domain")
        ]
        matches = (
            matches
            and len(runtime) == 1
            and runtime[0].get("credentialId") == mutation.get("runtimeCredentialId")
            and not runtime[0]["discrepancies"]
        )
    else:
        pair = mutation.get("pair") or "default"
        targets = [i for i in targets if i.get("pair") == pair]
        matches = bool(targets) and not any(i["discrepancies"] for i in targets)
        if operation in {"sync", "rotate"}:
            for kind in ["reader", "operator"]:
                expected = mutation.get(kind)
                if expected is not None:
                    rows = [i for i in targets if i.get("accessKind") == kind]
                    matches = (
                        matches
                        and len(rows) == 1
                        and all(
                            rows[0].get(k) == expected.get(k)
                            for k in ["state", "credentialGeneration", "sourceId", "integrationId"]
                        )
                    )
        else:
            for kind in ["reader", "operator"]:
                expected_role = mutation.get(kind + "Role")
                if expected_role:
                    matches = matches and any(
                        i.get("accessKind") == kind
                        and i.get("role") == expected_role
                        and i["evidence"].get("role") is not None
                        for i in targets
                    )
    return {
        "status": "observed" if matches else "inconsistent",
        "observedAt": observed_at,
        "errorCode": None if matches else "target_metadata_mismatch",
    }
