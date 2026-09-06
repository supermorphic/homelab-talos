#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json"
canary_workflow="$repo_root/kubernetes/apps/automation/n8n/app/workflows/automation-data-canary.json"
kustomization="$repo_root/kubernetes/apps/automation/n8n/app/kustomization.yaml"

[[ -f "$workflow" ]] || {
  echo 'The automation-data provisioning workflow template is missing.' >&2
  exit 1
}
[[ -f "$canary_workflow" ]] || {
  echo 'The automation-data canary workflow template is missing.' >&2
  exit 1
}

# Use the pinned YAML/JSON parser before the structural graph checks below.
yq -p=json -o=json '.' "$workflow" >/dev/null
yq -p=json -o=json '.' "$canary_workflow" >/dev/null

python - "$workflow" <<'PY'
import json
import re
import sys
from collections import deque
from pathlib import Path


workflow_path = Path(sys.argv[1])
workflow = json.loads(workflow_path.read_text())
nodes = workflow.get("nodes", [])
by_name = {node.get("name"): node for node in nodes}
if len(by_name) != len(nodes):
    raise SystemExit("Workflow node names must be unique.")


def require(condition, message):
    if not condition:
        raise SystemExit(message)


require(workflow.get("name") == "Automation Data Provisioner", "Unexpected workflow name.")
require(workflow.get("active") is False, "The provisioning template must be inactive.")
settings = workflow.get("settings", {})
require(settings.get("saveDataErrorExecution") == "none", "Failed execution data must not be saved.")
require(settings.get("saveDataSuccessExecution") == "none", "Successful execution data must not be saved.")
require(settings.get("saveManualExecutions") is False, "Manual execution data must not be saved.")
require(settings.get("saveExecutionProgress") is False, "Intermediate execution data must not be saved.")

webhooks = [node for node in nodes if node.get("type") == "n8n-nodes-base.webhook"]
require(len(webhooks) == 1, "Exactly one webhook trigger is required.")
webhook = webhooks[0]
require(webhook.get("parameters", {}).get("httpMethod") == "POST", "The webhook must use POST.")
require(webhook.get("parameters", {}).get("path") == "automation-data-provision", "Unexpected webhook path.")
require(webhook.get("parameters", {}).get("authentication") == "headerAuth", "The webhook must use Header Auth.")
require(webhook.get("parameters", {}).get("responseMode") == "responseNode", "The webhook must use an explicit response node.")

normalize = by_name.get("Normalize Request", {})
require(normalize.get("type") == "n8n-nodes-base.code", "Normalize Request must be a Code node.")
normalize_code = normalize.get("parameters", {}).get("jsCode", "")
allowed_fields_match = re.search(r"allowedFields\s*=\s*new Set\(\[([^]]+)\]\)", normalize_code)
require(allowed_fields_match is not None, "Normalize Request must declare its request fields.")
allowed_fields = re.findall(r"['\"]([^'\"]+)['\"]", allowed_fields_match.group(1))
require(allowed_fields == ["domain", "operation", "credential"], "The request field set is not exact.")
for literal in ("domain", "operation", "credential", "provision", "reconcile", "rotate", "validate"):
    require(re.search(rf"['\"]{literal}['\"]", normalize_code), f"Normalize Request must declare {literal!r}.")
require("^[a-z][a-z0-9_]{0,47}$" in normalize_code, "Normalize Request must enforce the domain grammar.")
require("Object.keys" in normalize_code and "allowedFields" in normalize_code, "Normalize Request must reject extra request fields.")

operation_switch = by_name.get("Select Operation", {})
require(operation_switch.get("type") == "n8n-nodes-base.switch", "Select Operation must be a Switch node.")
rules = operation_switch.get("parameters", {}).get("rules", {}).get("values", [])
operations = sorted(rule.get("conditions", {}).get("conditions", [{}])[0].get("rightValue") for rule in rules)
require(operations == ["provision", "reconcile", "rotate", "validate"], "The workflow operation set is not exact.")

approved_functions = {
    "platform_operations.provision_domain",
    "platform_operations.reconcile_domain",
    "platform_operations.record_domain_credentials",
    "platform_operations.rotate_domain_credential",
    "platform_operations.record_operation_error",
    "platform_operations.validate_domain",
}
seen_functions = set()
postgres_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.postgres"]
require(postgres_nodes, "The workflow must contain PostgreSQL control calls.")
for node in postgres_nodes:
    parameters = node.get("parameters", {})
    require(parameters.get("operation") == "executeQuery", f"{node['name']} must execute a fixed query.")
    query = parameters.get("query", "")
    calls = set(re.findall(r"platform_operations\.[a-z_]+", query))
    require(len(calls) == 1 and calls <= approved_functions, f"{node['name']} calls an unapproved control function.")
    require(
        re.fullmatch(r"SELECT platform_operations\.[a-z_]+\([^;]*\) AS result;", query),
        f"{node['name']} must contain only one fixed control-function SELECT.",
    )
    require(parameters.get("options", {}).get("queryReplacement"), f"{node['name']} must bind query parameters.")
    seen_functions |= calls
require(seen_functions == approved_functions, "The workflow does not use the complete required control-function set.")

http_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.httpRequest"]
require(http_nodes, "The workflow must contain local n8n credential API calls.")
allowed_literal_url = "http://127.0.0.1:5678/api/v1/credentials"
allowed_dynamic_urls = {
    "={{ 'http://127.0.0.1:5678/api/v1/credentials/' + $json.credentialId }}",
    "={{ 'http://127.0.0.1:5678/api/v1/credentials/' + $json.credentialId + '/test' }}",
}
for node in http_nodes:
    parameters = node.get("parameters", {})
    url = parameters.get("url")
    require(url == allowed_literal_url or url in allowed_dynamic_urls, f"{node['name']} has a dynamic or non-local API URL.")
    require(parameters.get("authentication") == "genericCredentialType", f"{node['name']} must use an n8n Header Auth credential.")
    require(parameters.get("genericAuthType") == "httpHeaderAuth", f"{node['name']} must use Header Auth.")
    method = parameters.get("method", "GET")
    if url == allowed_literal_url:
        require(method in {"GET", "POST"}, f"{node['name']} has an invalid collection method.")
    elif url.endswith("+ '/test' }}"):
        require(method == "POST", f"{node['name']} must POST credential tests.")
    else:
        require(method == "PATCH", f"{node['name']} must PATCH credential updates.")

for name in ("List Provision Credentials", "List Ready Credentials", "List Rotation Credentials"):
    parameters = by_name.get(name, {}).get("parameters", {})
    pagination = parameters.get("options", {}).get("pagination", {}).get("pagination", {})
    require(
        pagination.get("paginationMode") == "updateAParameterInEachRequest",
        f"{name} must follow the complete cursor-paginated credential inventory.",
    )
    require(
        pagination.get("parameters", {}).get("parameters")
        == [{"type": "qs", "name": "cursor", "value": "={{ $response.body.nextCursor }}"}],
        f"{name} must pass the API nextCursor as the next request cursor.",
    )
    require(
        pagination.get("paginationCompleteWhen") == "other"
        and pagination.get("completeExpression") == "={{ !$response.body.nextCursor }}"
        and pagination.get("limitPagesFetched") is False,
        f"{name} must continue until the credential API cursor is exhausted.",
    )

serialized = json.dumps(workflow)
for forbidden in ("DROP DATABASE", "DROP ROLE", "TRUNCATE", "DELETE FROM", "queryField"):
    require(forbidden.lower() not in serialized.lower(), f"Forbidden operation or request field found: {forbidden}")
require(not any("credentials" in node for node in nodes), "The Git template must not embed credential IDs or bindings.")

connections = workflow.get("connections", {})


def successors(name):
    outputs = connections.get(name, {}).get("main", [])
    return [edge["node"] for output in outputs for edge in output]


def reachable(start):
    found = set()
    pending = deque([start])
    while pending:
        current = pending.popleft()
        for candidate in successors(current):
            if candidate not in found:
                found.add(candidate)
                pending.append(candidate)
    return found


secret_generators = {node["name"] for node in nodes if node.get("type") == "n8n-nodes-base.crypto"}
credential_writes = {
    node["name"]
    for node in http_nodes
    if node.get("parameters", {}).get("method") in {"POST", "PATCH"}
    and not node.get("parameters", {}).get("url", "").endswith("+ '/test' }}")
}
ready_reachable = reachable("Ready Credential Set")
require(not (ready_reachable & secret_generators), "Ready reconciliation can reach password generation.")
require(not (ready_reachable & credential_writes), "Ready reconciliation can reach credential creation or update.")

rotation_reachable = reachable("Prepare Rotation") | {"Prepare Rotation"}
rotation_generators = rotation_reachable & secret_generators
rotation_patches = {
    name
    for name in rotation_reachable & credential_writes
    if by_name[name].get("parameters", {}).get("method") == "PATCH"
}
rotation_posts = {
    name
    for name in rotation_reachable & credential_writes
    if by_name[name].get("parameters", {}).get("method") == "POST"
}
require(len(rotation_generators) == 1, "Rotation must reach exactly one password generator.")
require(len(rotation_patches) == 1 and not rotation_posts, "Rotation must update exactly one existing credential.")
rotation_body = by_name[next(iter(rotation_patches))].get("parameters", {}).get("jsonBody", "")
require(
    rotation_body == "={{ JSON.stringify({ data: { password: $json.password }, isPartialData: true }) }}",
    "Rotation must partially update only the existing credential password.",
)

response = by_name.get("Respond", {})
require(response.get("type") == "n8n-nodes-base.respondToWebhook", "A final response node is required.")
response_body = response.get("parameters", {}).get("responseBody", "")
for forbidden in ("password", "apiKey", "headers", "credentialData"):
    require(forbidden not in response_body, f"Final response references secret-bearing field {forbidden}.")
require(response.get("parameters", {}).get("respondWith") == "json", "The final response must be JSON.")

success_code = by_name.get("Prepare Success Response", {}).get("parameters", {}).get("jsCode", "")
for field in (
    "migratorCredentialId",
    "runtimeCredentialId",
    "migratorCredentialUpdatedAt",
    "runtimeCredentialUpdatedAt",
    "passwordsUnchanged",
):
    require(field in success_code, f"Successful responses must expose non-secret {field} evidence.")
require("migratorPassword" not in success_code and "runtimePassword" not in success_code,
        "Successful responses must not expose generated passwords.")
for field in (
    "migratorDdlValid",
    "runtimeCrudValid",
    "runtimeDdlDenied",
    "runtimeOwnerAssumptionDenied",
    "runtimeRoleManagementDenied",
):
    require(field in success_code, f"Successful responses must expose live {field} evidence.")

notes = "\n".join(
    node.get("parameters", {}).get("content", "")
    for node in nodes
    if node.get("type") == "n8n-nodes-base.stickyNote"
)
for label in (
    "Automation Data Provisioner",
    "Automation Data n8n API",
    "Automation Data Provisioning Header",
    "X-Automation-Data-Provisioning",
    "full-access Community API key",
    "n8n.lab.supermorphic.com",
):
    require(label in notes, f"Workflow setup note is missing {label!r}.")

print("automation-data workflow contract: PASS")
PY

node - "$workflow" <<'JS'
const fs = require('fs');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const byName = Object.fromEntries(workflow.nodes.map((node) => [node.name, node]));
const normalize = new Function('$json', byName['Normalize Request'].parameters.jsCode);
const normal = normalize({ body: { domain: 'domain_one', operation: 'provision' } });
if (normal[0].json.domain !== 'domain_one') throw new Error('normal domain changed');
for (const domain of ['postgres', 'template0', 'template1', 'automation_data_control']) {
  let rejected = false;
  try { normalize({ body: { domain, operation: 'provision' } }); }
  catch (error) { rejected = error.message === 'invalid_domain'; }
  if (!rejected) throw new Error(`reserved domain accepted: ${domain}`);
}
// Execute the production response/error Code nodes and follow their real graph
// outputs. PostgreSQL is a recording boundary, not a simulated database here.
const dispatchResponse = (operation, result) => {
  const request = { domain: 'domain_one', operation };
  const lookup = () => ({ first: () => ({ json: request }) });
  let name = 'Prepare Success Response';
  let input = { result };
  let recordings = 0;
  for (let step = 0; step < 8; step++) {
    const node = byName[name];
    if (node.type === 'n8n-nodes-base.respondToWebhook') return { response: input, recordings };
    let output = 0;
    if (node.type === 'n8n-nodes-base.postgres') {
      if (!node.parameters.query.includes('platform_operations.record_operation_error(')) {
        throw new Error(`unexpected database call in error dispatch: ${name}`);
      }
      recordings++;
      input = { result: null };
    } else {
      try { input = new Function('$json', '$', node.parameters.jsCode)(input, lookup)[0].json; }
      catch (error) {
        if (node.onError !== 'continueErrorOutput') throw error;
        output = 1;
        input = { error: error.message };
      }
    }
    const edges = workflow.connections[name]?.main?.[output];
    if (edges?.length !== 1) throw new Error(`error dispatch did not select one successor: ${name}`);
    name = edges[0].node;
  }
  throw new Error('error dispatch failed to reach a response');
};
const validChecks = Object.fromEntries([
  'ownerNoLogin', 'migratorCanSetOwner', 'runtimeCannotSetOwner',
  'migratorControlConnectDenied', 'runtimeControlConnectDenied',
  'migratorDomainConnectAllowed', 'runtimeDomainConnectAllowed',
  'runtimePrivilegesValid', 'defaultPrivilegesValid', 'crossDomainConnectDenied',
  'migratorDdlValid', 'runtimeCrudValid', 'runtimeDdlDenied',
  'runtimeOwnerAssumptionDenied', 'runtimeRoleManagementDenied',
].map((name) => [name, true]));
for (const result of [
  ...['provisioning', 'rotating', 'error'].map((state) => ({ domain: 'domain_one', state })),
  { domain: 'domain_one', state: 'ready', ...validChecks, runtimePrivilegesValid: false },
  '{invalid-json',
]) {
  for (const operation of ['validate', 'provision', 'rotate', 'reconcile']) {
    const { response, recordings } = dispatchResponse(operation, result);
    if (response.ok !== false || response.errorCode !== 'workflow_operation_failed') {
      throw new Error(`${operation} validation failure did not return its bounded error`);
    }
    if (recordings !== (operation === 'validate' ? 0 : 1)) {
      throw new Error(`${operation} validation failure reached ${recordings} mutation error recorders`);
    }
  }
}
const validResponse = dispatchResponse('validate', { domain: 'domain_one', state: 'ready', ...validChecks });
if (validResponse.response.ok !== true || validResponse.recordings !== 0) {
  throw new Error('successful validation changed the registry or failed');
}
const targetPages = [
  { json: { data: [{ id: 'unrelated', name: 'unrelated', type: 'postgres' }], nextCursor: 'page-two' } },
  { json: { data: [
    { id: 'migrator-id', name: 'automation-data/domain_one/migrator', type: 'postgres' },
    { id: 'runtime-id', name: 'automation-data/domain_one/runtime', type: 'postgres' },
  ] } },
];
const lookup = () => ({ first: () => ({ json: { domain: 'domain_one', credential: 'runtime' } }) });
const execute = (name, pages = targetPages) => {
  const code = byName[name]?.parameters?.jsCode;
  if (!code) throw new Error(`missing code for ${name}`);
  return new Function('$input', '$', code)({ all: () => pages }, lookup);
};
for (const name of ['Analyze Provision Credential Snapshot', 'Ready Credential Set', 'Prepare Rotation']) {
  const result = execute(name)[0].json;
  if (result.migrator?.id !== 'migrator-id' || result.runtime?.id !== 'runtime-id') {
    throw new Error(`${name} did not find exact credentials on a later cursor page`);
  }
}
if (execute('Prepare Rotation')[0].json.target.id !== 'runtime-id') {
  throw new Error('Rotation did not select its target from the complete credential inventory');
}
const duplicatePages = [...targetPages, { json: { data: [
  { id: 'duplicate-runtime', name: 'automation-data/domain_one/runtime', type: 'postgres' },
] } }];
for (const name of ['Analyze Provision Credential Snapshot', 'Ready Credential Set', 'Prepare Rotation']) {
  let rejected = false;
  try {
    execute(name, duplicatePages);
  } catch (error) {
    rejected = /duplicate|credential_set_invalid/.test(error.message);
  }
  if (!rejected) throw new Error(`${name} accepted a duplicate credential across cursor pages`);
}
JS

python - "$canary_workflow" <<'PY'
import json
import sys
from pathlib import Path


workflow = json.loads(Path(sys.argv[1]).read_text())
nodes = workflow.get("nodes", [])
by_name = {node.get("name"): node for node in nodes}
if workflow.get("name") != "Automation Data Canary" or workflow.get("active") is not False:
    raise SystemExit("The automation-data canary must be the inactive exact workflow.")
settings = workflow.get("settings", {})
if (
    settings.get("saveDataErrorExecution") != "none"
    or settings.get("saveDataSuccessExecution") != "none"
    or settings.get("saveManualExecutions") is not False
    or settings.get("saveExecutionProgress") is not False
):
    raise SystemExit("The automation-data canary must not persist execution data.")
webhook = by_name.get("Canary Webhook", {}).get("parameters", {})
if (
    webhook.get("httpMethod") != "POST"
    or webhook.get("path") != "automation-data-canary"
    or webhook.get("authentication") != "headerAuth"
    or webhook.get("responseMode") != "responseNode"
):
    raise SystemExit("The automation-data canary webhook contract is not exact.")
postgres = by_name.get("Test Stable Runtime Credential", {}).get("parameters", {})
if postgres.get("query") != "SELECT current_database() AS database, current_user AS role;":
    raise SystemExit("The automation-data canary query is not the bounded identity query.")
code = by_name.get("Bounded Canary Response", {}).get("parameters", {}).get("jsCode", "")
for value in (
    "status",
    "database",
    "role",
    "executionId",
    "automation_data_canary",
    "automation_data_canary_runtime",
):
    if value not in code:
        raise SystemExit(f"The automation-data canary response omits {value}.")
serialized = json.dumps(workflow)
if any("credentials" in node for node in nodes) or '"password"' in serialized.lower():
    raise SystemExit("The automation-data canary template embeds credential data or bindings.")
notes = by_name.get("Canary Setup", {}).get("parameters", {}).get("content", "")
for value in ("Platform Canary Header", "automation-data/automation_data_canary/runtime"):
    if value not in notes:
        raise SystemExit(f"The automation-data canary setup note omits {value}.")
PY

node - "$canary_workflow" <<'JS'
const fs = require('fs');

const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const code = workflow.nodes.find((node) => node.name === 'Bounded Canary Response')?.parameters?.jsCode;
if (!code) throw new Error('The bounded automation-data canary response node is missing.');

const respond = new Function('$json', '$execution', code);
const result = respond(
  { database: 'automation_data_canary', role: 'automation_data_canary_runtime' },
  { id: 42 },
);
const response = result?.[0]?.json;
const expectedFields = ['database', 'executionId', 'role', 'status'];
if (JSON.stringify(Object.keys(response ?? {}).sort()) !== JSON.stringify(expectedFields)) {
  throw new Error('The automation-data canary must return exactly four bounded response fields.');
}
if (
  response.status !== 'ok'
  || response.database !== 'automation_data_canary'
  || response.role !== 'automation_data_canary_runtime'
  || response.executionId !== '42'
) {
  throw new Error('The automation-data canary response does not expose the stable runtime identity.');
}
for (const identity of [
  { database: 'unexpected_database', role: 'automation_data_canary_runtime' },
  { database: 'automation_data_canary', role: 'unexpected_role' },
]) {
  let rejected = false;
  try { respond(identity, { id: 42 }); }
  catch (error) { rejected = error.message === 'stable_runtime_identity_mismatch'; }
  if (!rejected) throw new Error('The automation-data canary accepts an unexpected runtime identity.');
}
JS

mapfile -t packaged_workflows < <(
  yq -r '.configMapGenerator[] | select(.name == "n8n-workflow-templates") | .files[]' \
    "$kustomization" | LC_ALL=C sort
)
expected_workflows=(
  'automation-data-canary.json=workflows/automation-data-canary.json'
  'automation-data-provisioner.json=workflows/automation-data-provisioner.json'
  'platform-canary.json=workflows/platform-canary.json'
)
[[ "${packaged_workflows[*]}" == "${expected_workflows[*]}" ]] || {
  echo 'The n8n workflow ConfigMap must package both secret-free templates.' >&2
  exit 1
}
