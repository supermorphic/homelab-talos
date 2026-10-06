"""Expiring, single-login n8n transport; the provisioning credential stays in n8n."""

from __future__ import annotations

import hashlib
import json
import re
import secrets
import time
import uuid
from itertools import pairwise
from pathlib import Path

from automation_data_client import (
    PrivateFileError,
    validate_private_directory,
    validate_private_file,
    write_private_file_exclusive,
)

ORIGIN = "https://n8n.lab.supermorphic.com"
PROVISIONER = "http://127.0.0.1:5678/webhook/automation-data-provision"
LIFETIME = 3600
OPERATIONS = ("login-register", "login-validate", "login-activate", "login-complete")
RETENTION = {
    "executionOrder": "v1",
    "saveDataSuccessExecution": "none",
    "saveDataErrorExecution": "none",
    "saveManualExecutions": False,
    "saveExecutionProgress": False,
    "executionTimeout": 120,
}


def _outside_checkout(path: Path) -> None:
    if not path.is_absolute():
        raise PrivateFileError("transport_path_not_absolute")
    for parent in (path, *path.parents):
        if parent.is_symlink() or (parent / ".git").exists():
            raise PrivateFileError("transport_path_unsafe")


def _scope(domain: str, application: str, schema: str) -> dict:
    if (
        not isinstance(domain, str)
        or not re.fullmatch(r"[a-z][a-z0-9_]{0,47}", domain)
        or domain in {"postgres", "template0", "template1", "automation_data_control"}
        or not isinstance(application, str)
        or not re.fullmatch(r"[a-z][a-z0-9_]{0,23}", application)
        or not isinstance(schema, str)
        or not re.fullmatch(r"[a-z][a-z0-9_]{0,47}", schema)
        or schema.startswith("pg_")
        or schema in {"public", "information_schema"}
    ):
        raise PrivateFileError("transport_scope_invalid")
    return {"domain": domain, "application": application, "schema": schema}


def _load(path: Path) -> dict:
    _outside_checkout(path)
    validate_private_directory(path.parent)
    validate_private_file(path)
    if path.stat().st_size > 65536:
        raise PrivateFileError("transport_file_too_large")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise PrivateFileError("transport_file_invalid")
    return value


def _digest(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def _write(path: Path, value: dict) -> None:
    write_private_file_exclusive(path, (json.dumps(value, indent=2) + "\n").encode())


def render(profile: dict) -> dict:
    """Render an inactive relay with only a hash of its random, temporary bearer."""
    scope = profile["scope"]
    role = (
        "app_"
        + hashlib.md5(
            f"{scope['domain']}:{scope['application']}".encode(), usedforsecurity=False
        ).hexdigest()
        + "_integration"
    )
    config = json.dumps(
        {
            **scope,
            "role": role,
            "issuedAt": profile["issuedAt"],
            "expiresAt": profile["expiresAt"],
            "tokenDigest": hashlib.sha256(profile["token"].encode()).hexdigest(),
        }
    )
    preamble = "const scope = " + config + ";\n"
    prepare_code = """const body = $json.body;
const token = $json.headers?.['x-automation-data-login'];
if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{64}$/.test(token) ||
    !body || typeof body !== 'object' || Array.isArray(body) ||
    JSON.stringify(body).length > 4096) throw new Error('request_rejected');
return [{json: {token, request: body}}];"""
    authorize_code = (
        preamble
        + """const now = Math.floor(Date.now() / 1000);
const body = $json.request;
if (now < scope.issuedAt || now >= scope.expiresAt ||
    scope.expiresAt - scope.issuedAt !== 3600 || $json.tokenDigest !== scope.tokenDigest ||
    !body || typeof body !== 'object' || Array.isArray(body) ||
    body.domain !== scope.domain || body.application !== scope.application)
  throw new Error('request_rejected');
const fields = {
  'login-register': ['schema'], 'login-validate': [],
  'login-activate': ['operationId', 'expectedGeneration', 'password'],
  'login-complete': ['operationId', 'credentialGeneration'],
};
if (!Object.hasOwn(fields, body.operation)) throw new Error('request_rejected');
const expected = ['domain', 'application', 'operation', ...fields[body.operation]];
if (Object.keys(body).length !== expected.length || expected.some(key => !Object.hasOwn(body, key)))
  throw new Error('request_rejected');
if (body.operation === 'login-register' && body.schema !== scope.schema)
  throw new Error('request_rejected');
if (Object.hasOwn(body, 'operationId') && (typeof body.operationId !== 'string' ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.operationId)))
  throw new Error('request_rejected');
if (body.operation === 'login-activate' && (body.expectedGeneration !== 0 ||
    typeof body.password !== 'string' || !/^[A-Za-z0-9_-]{32,256}$/.test(body.password)))
  throw new Error('request_rejected');
if (body.operation === 'login-complete' && body.credentialGeneration !== 1)
  throw new Error('request_rejected');
const request = {domain: scope.domain, application: scope.application, operation: body.operation};
for (const key of fields[body.operation]) request[key] = body[key];
return [{json: request}];"""
    )
    response_code = (
        preamble
        + """const result = $json;
const uuid = value => value === null || (typeof value === 'string' &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value));
if (result.ok !== true || result.domain !== scope.domain ||
    result.application !== scope.application || result.database !== scope.domain ||
    result.schema !== scope.schema || result.role !== scope.role ||
    !['awaiting_grants', 'activating', 'ready', 'error'].includes(result.state) ||
    !Number.isSafeInteger(result.credentialGeneration) || result.credentialGeneration < 0 ||
    result.credentialGeneration > 1 || !uuid(result.operationId ?? null) ||
    ![null, 0].includes(result.expectedGeneration ?? null) ||
    (result.valid !== undefined && typeof result.valid !== 'boolean'))
  throw new Error('response_rejected');
return [{json: {ok: true, domain: scope.domain, application: scope.application,
  database: scope.domain, schema: scope.schema, role: scope.role, state: result.state,
  credentialGeneration: result.credentialGeneration, operationId: result.operationId ?? null,
  expectedGeneration: result.expectedGeneration ?? null,
  ...(result.valid !== undefined ? {valid: result.valid} : {})}}];"""
    )
    nodes = []

    def add(name, kind, version, parameters, **extra):
        nodes.append(
            {
                "id": str(uuid.uuid5(uuid.NAMESPACE_URL, name)),
                "name": name,
                "type": "n8n-nodes-base." + kind,
                "typeVersion": version,
                "position": [len(nodes) * 240, 0],
                "parameters": parameters,
                **extra,
            }
        )

    add(
        "Login Webhook",
        "webhook",
        2.1,
        {
            "httpMethod": "POST",
            "path": profile["url"].split("/webhook/")[1],
            "authentication": "none",
            "responseMode": "lastNode",
            "responseData": "firstEntryJson",
            "options": {},
        },
    )
    add("Prepare Request", "code", 2, {"mode": "runOnceForAllItems", "jsCode": prepare_code})
    add(
        "Hash Transport Token",
        "crypto",
        1,
        {
            "action": "hash",
            "type": "SHA256",
            "value": "={{ $json.token }}",
            "dataPropertyName": "tokenDigest",
            "encoding": "hex",
        },
    )
    add("Authorize Request", "code", 2, {"mode": "runOnceForAllItems", "jsCode": authorize_code})

    def http(name, body, timeout):
        add(
            name,
            "httpRequest",
            4.4,
            {
                "method": "POST",
                "url": PROVISIONER,
                "authentication": "genericCredentialType",
                "genericAuthType": "httpHeaderAuth",
                "sendBody": True,
                "specifyBody": "json",
                "jsonBody": body,
                "options": {
                    "timeout": timeout,
                    "redirect": {"redirect": {"followRedirects": False}},
                    "response": {"response": {"responseFormat": "json"}},
                },
            },
            credentials={
                "httpHeaderAuth": {
                    "id": profile["credentialId"],
                    "name": "Automation Data Provisioning Header",
                }
            },
        )

    deadline = str(profile["expiresAt"] * 1000)
    expiry_guard = "if (Date.now() >= " + deadline + ") throw new Error('request_rejected'); "
    http(
        "Read Registered Login",
        "={{ (() => { "
        + expiry_guard
        + "const request = $json; return request.operation === 'login-register' ? request : "
        + "{domain: request.domain, application: request.application, operation: 'login-validate'}; "
        + "})() }}",
        "={{ $json.operation === 'login-register' ? 60000 : 20000 }}",
    )
    add(
        "Check Registered Scope",
        "code",
        2,
        {"mode": "runOnceForAllItems", "jsCode": response_code},
    )
    add(
        "Needs Activation or Completion",
        "if",
        2.2,
        {
            "conditions": {
                "options": {"caseSensitive": True, "typeValidation": "strict", "version": 2},
                "conditions": [
                    {
                        "leftValue": "={{ ['login-activate', 'login-complete'].includes($('Authorize Request').first().json.operation) }}",
                        "rightValue": True,
                        "operator": {"type": "boolean", "operation": "equals"},
                    }
                ],
                "combinator": "and",
            },
            "options": {},
        },
    )
    http(
        "Call Provisioner",
        "={{ (() => { " + expiry_guard + "return $('Authorize Request').first().json; })() }}",
        60000,
    )
    add("Safe Response", "code", 2, {"mode": "runOnceForAllItems", "jsCode": response_code})
    connections = {
        left["name"]: {"main": [[{"node": right["name"], "type": "main", "index": 0}]]}
        for left, right in pairwise(nodes)
    }
    connections["Needs Activation or Completion"]["main"].append(
        [{"node": "Safe Response", "type": "main", "index": 0}]
    )
    return {
        "name": "Application Login Enrollment " + profile["session"],
        "active": False,
        "nodes": nodes,
        "connections": connections,
        "settings": dict(RETENTION),
    }


def prepare(
    directory: Path,
    domain: str,
    application: str,
    schema: str,
    credential_id: str,
    *,
    now: int | None = None,
) -> dict:
    scope = _scope(domain, application, schema)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", credential_id):
        raise PrivateFileError("transport_credential_id_invalid")
    _outside_checkout(directory)
    # Exclusive session creation never changes an application credential or older session.
    directory.mkdir(mode=0o700)
    validate_private_directory(directory)
    issued = int(time.time()) if now is None else now
    session = uuid.uuid4().hex
    profile = {
        "version": 1,
        "session": session,
        "scope": scope,
        "issuedAt": issued,
        "expiresAt": issued + LIFETIME,
        "credentialId": credential_id,
        "url": ORIGIN + "/webhook/automation-data-login-" + session,
        "token": secrets.token_urlsafe(48),
    }
    _write(directory / "transport.json", profile)
    _write(directory / "workflow.json", render(profile))
    return {
        "transportFile": str(directory / "transport.json"),
        "workflowFile": str(directory / "workflow.json"),
        "scope": scope,
        "expiresAt": profile["expiresAt"],
        "published": False,
    }


def _profile(path: Path, now: int | None) -> dict:
    profile = _load(path)
    scope = profile.get("scope", {})
    _scope(scope.get("domain"), scope.get("application"), scope.get("schema"))
    issued, expires = profile.get("issuedAt"), profile.get("expiresAt")
    current = int(time.time()) if now is None else now
    if (
        profile.get("version") != 1
        or type(issued) is not int
        or type(expires) is not int
        or expires - issued != LIFETIME
        or not issued <= current < expires
        or not re.fullmatch(r"[a-f0-9]{32}", profile.get("session", ""))
        or profile.get("url") != ORIGIN + "/webhook/automation-data-login-" + profile["session"]
        or not re.fullmatch(r"[A-Za-z0-9_-]{64}", profile.get("token", ""))
        or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", profile.get("credentialId", ""))
    ):
        raise PrivateFileError("transport_profile_invalid_or_expired")
    return profile


def _graph_contract(graph: dict) -> dict:
    """Ignore editor layout/IDs; retain every executable node setting and binding."""
    ignored = {"id", "position", "notes", "notesInFlow", "webhookId"}
    nodes = [
        {key: value for key, value in node.items() if key not in ignored}
        for node in graph.get("nodes", [])
    ]
    return {
        "nodes": sorted(nodes, key=lambda node: node["name"]),
        "connections": graph.get("connections"),
    }


def verify(directory: Path, observation: Path, *, now: int | None = None) -> dict:
    """Check a fresh full MCP readback, including the published version; never publish."""
    profile = _profile(directory / "transport.json", now)
    graph = render(profile)
    if observation.stat().st_size > 262144:
        raise PrivateFileError("transport_observation_too_large")
    observed = json.loads(observation.read_text())
    observed = observed.get("workflow", observed)
    active = observed.get("activeVersion") or {}
    if active.get("sameAsDraft") is True:
        active = observed
    if (
        observed.get("active") is not True
        or not observed.get("id")
        or not observed.get("versionId")
        or observed.get("activeVersionId") != observed["versionId"]
        or _graph_contract(observed) != _graph_contract(graph)
        or _graph_contract(active) != _graph_contract(graph)
        or any(observed.get("settings", {}).get(key) != value for key, value in RETENTION.items())
        or observed.get("settings", {}).get("errorWorkflow")
        or observed.get("pinData")
        or observed.get("staticData")
    ):
        raise PrivateFileError("transport_published_contract_mismatch")
    receipt = {
        "profileSha256": _digest(profile),
        "workflowSha256": _digest(graph),
        "workflowId": observed["id"],
        "versionId": observed["versionId"],
        "verifiedAt": int(time.time()) if now is None else now,
    }
    _write(directory / "verified.json", receipt)
    return {key: receipt[key] for key in ("workflowId", "versionId", "verifiedAt")}


def request_configuration(
    path: Path, payload: dict, *, now: int | None = None
) -> tuple[str, dict]:
    profile = _profile(path, now)
    receipt = _load(path.parent / "verified.json")
    scope = profile["scope"]
    if (
        receipt.get("profileSha256") != _digest(profile)
        or receipt.get("workflowSha256") != _digest(render(profile))
        or payload.get("domain") != scope["domain"]
        or payload.get("application") != scope["application"]
        or payload.get("operation") not in OPERATIONS
        or ("schema" in payload and payload["schema"] != scope["schema"])
    ):
        raise PrivateFileError("transport_request_scope_mismatch")
    return profile["url"], {"X-Automation-Data-Login": profile["token"]}
