#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source_workflow="$repo_root/kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json"
acceptance_workflow="$repo_root/kubernetes/apps/automation/n8n/app/workflows/nocodb-acceptance-domain.json"
kustomization="$repo_root/kubernetes/apps/automation/n8n/app/kustomization.yaml"

[[ -f "$source_workflow" ]] || {
  echo 'The NocoDB source provisioning workflow template is missing.' >&2
  exit 1
}
[[ -f "$acceptance_workflow" ]] || {
  echo 'The NocoDB acceptance workflow template is missing.' >&2
  exit 1
}

yq -p=json -o=json '.' "$source_workflow" >/dev/null
yq -p=json -o=json '.' "$acceptance_workflow" >/dev/null

python - "$source_workflow" <<'PY'
import json
import re
import sys
from collections import deque
from pathlib import Path


workflow = json.loads(Path(sys.argv[1]).read_text())
nodes = workflow.get("nodes", [])
by_name = {node.get("name"): node for node in nodes}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


require(len(by_name) == len(nodes), "Source workflow node names must be unique.")
require(workflow.get("name") == "NocoDB Source Provisioner", "Unexpected source workflow name.")
require(workflow.get("active") is False, "The source workflow template must be inactive.")
settings = workflow.get("settings", {})
require(
    settings == {
        "executionOrder": "v1",
        "saveDataErrorExecution": "none",
        "saveDataSuccessExecution": "none",
        "saveManualExecutions": False,
        "saveExecutionProgress": False,
    },
    "The source workflow must use execution order v1 and disable all execution persistence.",
)

webhooks = [node for node in nodes if node.get("type") == "n8n-nodes-base.webhook"]
require(len(webhooks) == 1, "The source workflow must have exactly one webhook.")
webhook = webhooks[0].get("parameters", {})
require(
    webhook.get("httpMethod") == "POST"
    and webhook.get("path") == "automation-data-nocodb-source"
    and webhook.get("authentication") == "headerAuth"
    and webhook.get("responseMode") == "responseNode",
    "The source webhook contract is not exact.",
)

normalize = by_name.get("Normalize Source Request", {})
normalize_code = normalize.get("parameters", {}).get("jsCode", "")
require(normalize.get("type") == "n8n-nodes-base.code", "Normalize Source Request must be a Code node.")
allowed_request_fields = {"domain", "operation", "accessKind"}
allowed_operations = {"sync", "rotate"}
allowed_access_kinds = {"reader", "operator"}
for values, label in (
    (allowed_request_fields, "request field"),
    (allowed_operations, "operation"),
    (allowed_access_kinds, "access kind"),
):
    for value in values:
        require(re.search(rf"['\"]{value}['\"]", normalize_code), f"Missing source {label}: {value}")
require("^[a-z][a-z0-9_]{0,47}$" in normalize_code, "The source workflow must enforce the domain grammar.")
require("Object.keys" in normalize_code and "allowedFields" in normalize_code, "Extra source request fields are not rejected.")
require("requestedAccessKind" in normalize_code, "The source workflow must preserve the normalized rotation target separately.")

approved_functions = {
    "platform_operations.validate_domain",
    "platform_operations.prepare_nocodb_access",
    "platform_operations.read_nocodb_source_state",
    "platform_operations.begin_nocodb_source",
    "platform_operations.record_nocodb_integration",
    "platform_operations.record_nocodb_source_job",
    "platform_operations.record_nocodb_source_ready",
    "platform_operations.record_nocodb_source_error",
    "platform_operations.rotate_nocodb_source_credential",
    "platform_operations.validate_nocodb_access",
}
seen_functions = set()
postgres_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.postgres"]
require(postgres_nodes, "The source workflow must use the fixed PostgreSQL function boundary.")
for node in postgres_nodes:
    parameters = node.get("parameters", {})
    query = parameters.get("query", "")
    calls = set(re.findall(r"platform_operations\.[a-z_]+", query))
    require(parameters.get("operation") == "executeQuery", f"{node['name']} must execute a fixed query.")
    require(
        len(calls) == 1
        and calls <= approved_functions
        and re.fullmatch(r"SELECT platform_operations\.[a-z_]+\([^;]*\) AS result;", query),
        f"{node['name']} does not contain one approved fixed-function SELECT.",
    )
    require(parameters.get("options", {}).get("queryReplacement"), f"{node['name']} must bind query parameters.")
    seen_functions |= calls
require(seen_functions == approved_functions, "The source workflow does not use the exact Task 1 function set.")
record_error = by_name.get("Record Source Error", {}).get("parameters", {})
require(
    record_error.get("query") == "SELECT platform_operations.record_nocodb_source_error($1, $2, $3, $4) AS result;"
    and "sourceOperation" in record_error.get("options", {}).get("queryReplacement", ""),
    "Source errors must persist the exact sync or rotate operation through the fixed interface.",
)

host = "http://nocodb.automation-data.svc.cluster.local:8080"
allowed_nocodb_paths = {
    "/api/v2/meta/bases",
    "/api/v2/meta/bases/:baseId/sources",
    "/api/v2/meta/bases/:baseId/sources/:sourceId",
    "/api/v2/meta/bases/:baseId/tables",
    "/api/v2/tables/:tableId/records",
    "/api/v2/jobs/:baseId",
    "/api/v2/meta/workspaces/:workspaceId/integrations",
    "/api/v2/meta/integrations/:integrationId",
}
terminal_job_states = {"completed", "failed"}


def normalized_path(url):
    require(host in url, f"NocoDB URL does not use the fixed service host: {url}")
    suffix = url.split(host, 1)[1]
    if "/workspaces/" in suffix and "/integrations" in suffix:
        return "/api/v2/meta/workspaces/:workspaceId/integrations"
    if suffix.startswith("/api/v2/meta/integrations/"):
        return "/api/v2/meta/integrations/:integrationId"
    if suffix.startswith("/api/v2/jobs/"):
        return "/api/v2/jobs/:baseId"
    if suffix.startswith("/api/v2/tables/") and "/records" in suffix:
        return "/api/v2/tables/:tableId/records"
    if "/sources/" in suffix:
        return "/api/v2/meta/bases/:baseId/sources/:sourceId"
    if "/sources" in suffix:
        return "/api/v2/meta/bases/:baseId/sources"
    if suffix.startswith("/api/v2/meta/bases/") and "/tables" in suffix:
        return "/api/v2/meta/bases/:baseId/tables"
    return suffix.rstrip("/")


http_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.httpRequest"]
require(http_nodes, "The source workflow must contain NocoDB HTTP calls.")
seen_paths = set()
for node in http_nodes:
    parameters = node.get("parameters", {})
    path = normalized_path(parameters.get("url", ""))
    require(path in allowed_nocodb_paths, f"{node['name']} uses an unapproved NocoDB path: {path}")
    require(parameters.get("authentication") == "genericCredentialType", f"{node['name']} must use Header Auth.")
    require(parameters.get("genericAuthType") == "httpHeaderAuth", f"{node['name']} must use Header Auth.")
    method = parameters.get("method", "GET")
    if path == "/api/v2/jobs/:baseId":
        require(method == "POST", f"{node['name']} must POST the job-list request.")
        body = parameters.get("jsonBody", "")
        require("source-create" in body and "status" not in body, "Job polling must request all source-create states.")
    elif path == "/api/v2/meta/bases/:baseId/sources/:sourceId":
        require(method == "GET", f"{node['name']} must GET the discovered source.")
    elif path == "/api/v2/meta/bases/:baseId/sources":
        require(method in {"GET", "POST"}, f"{node['name']} has an invalid source collection method.")
    elif path in {"/api/v2/meta/bases/:baseId/tables", "/api/v2/tables/:tableId/records"}:
        require(method == "GET", f"{node['name']} must perform a bounded read-only data probe.")
        if path == "/api/v2/tables/:tableId/records":
            query = parameters.get("queryParameters", {}).get("parameters", [])
            require(
                {item.get("name"): str(item.get("value")) for item in query}.get("limit") == "1",
                f"{node['name']} must bound the data probe to one record.",
            )
    elif path == "/api/v2/meta/bases":
        require(method in {"GET", "POST"}, f"{node['name']} has an invalid base collection method.")
    elif path == "/api/v2/meta/workspaces/:workspaceId/integrations":
        require(method in {"GET", "POST"}, f"{node['name']} has an invalid workspace integration method.")
    else:
        require(method == "PATCH", f"{node['name']} must PATCH the exact existing integration.")
    seen_paths.add(path)
require(seen_paths == allowed_nocodb_paths, "The source workflow does not use the exact NocoDB endpoint set.")

wait_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.wait"]
require(len(wait_nodes) == 2, "Reader and operator polling each require one Wait node.")
for node in wait_nodes:
    parameters = node.get("parameters", {})
    require(
        parameters.get("amount") == 5 and parameters.get("unit") == "seconds",
        f"{node['name']} must wait exactly five seconds.",
    )

for name in ("Evaluate Reader Job", "Evaluate Operator Job"):
    code = by_name.get(name, {}).get("parameters", {}).get("jsCode", "")
    for marker in ("120", "completed", "failed", "sourceCreateJobId", "missing_stored_job", "duplicate_stored_job", "source_job_timeout"):
        require(marker in code, f"{name} is missing bounded exact-job behavior: {marker}")
    require(all(state in code for state in terminal_job_states), f"{name} omits a terminal job state.")

serialized = json.dumps(workflow)
require("DELETE" not in serialized.upper(), "The source workflow must not call source delete.")
require(not any("credentials" in node for node in nodes), "The source workflow must not embed credential IDs.")

# NocoDB 2026.08.2 (tag commit 28c50ff08c37fe3ced3a7dba021f7cba7b2c51dc)
# defines the database member of IntegrationReq.type as "database". Keep the
# create and rotation payloads aligned with that pinned public API contract.
integration_payload_nodes = (
    "Prepare Reader Integration",
    "Build Reader Rotation Integration",
    "Prepare Operator Integration",
    "Build Operator Rotation Integration",
)
for name in integration_payload_nodes:
    code = by_name.get(name, {}).get("parameters", {}).get("jsCode", "")
    require("type: 'database'" in code, f"{name} must use the pinned NocoDB database integration type.")
    require("type: 'db'" not in code, f"{name} uses the obsolete NocoDB integration type.")

connections = workflow.get("connections", {})


def successors(name):
    return [edge["node"] for output in connections.get(name, {}).get("main", []) for edge in output]


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


def reachable_avoiding(start, blocked):
    found = set()
    pending = deque([start])
    while pending:
        current = pending.popleft()
        for candidate in successors(current):
            if candidate in blocked or candidate in found:
                continue
            found.add(candidate)
            pending.append(candidate)
    return found


executable_nodes = {node["name"] for node in nodes if node.get("type") != "n8n-nodes-base.stickyNote"}
require(
    executable_nodes <= (reachable("Source Webhook") | {"Source Webhook"}),
    "Every source workflow executable node must be reachable from the webhook.",
)
require("Record Reader Ready" in reachable("Get Reader Source"), "Reader source GET must precede ready recording.")
require("Validate Reader PostgreSQL" in reachable("Get Reader Source"), "Reader source GET must precede PostgreSQL validation.")
require("Start Operator" in reachable("Record Reader Ready"), "The operator path must start only after reader ready.")
require("Generate Reader Password" not in reachable("Resume Reader Job"), "A resumed reader job must poll before password change.")
require("Generate Operator Password" not in reachable("Resume Operator Job"), "A resumed operator job must poll before password change.")
require("Respond" not in reachable("Create Reader Source") or "Poll Reader Jobs" in reachable("Create Reader Source"), "Source create cannot bypass polling.")
require(
    "operator_not_eligible" in by_name.get("Start Operator", {}).get("parameters", {}).get("jsCode", ""),
    "An explicit operator rotation must fail when operator access is not eligible.",
)
for access_kind in ("Reader", "Operator"):
    ready = f"Record {access_kind} Ready"
    data_probe_guards = {
        f"Require {access_kind} Data Probe",
        f"Require Rotated {access_kind} Data Probe",
    }
    require(
        ready not in reachable_avoiding("Source Webhook", data_probe_guards),
        f"Every {access_kind.lower()} ready path must pass a normal NocoDB data probe.",
    )
    require(
        f"Relist {access_kind} Sources Before Queue" in reachable(f"Record {access_kind} Integration")
        and f"Create {access_kind} Source" in reachable(f"Relist {access_kind} Sources Before Queue"),
        f"{access_kind} source creation must re-list sources after recording the current integration.",
    )
    require(
        f"Require Rotated {access_kind} Data Probe" in reachable(f"Patch {access_kind} Rotation Integration"),
        f"{access_kind} rotation must probe NocoDB after patching the retained integration.",
    )
    require(
        f"Observe {access_kind} Ready Job" not in by_name
        and f"Require {access_kind} Ready Job" not in by_name,
        f"{access_kind} ready reconciliation must not query expiring completed-job history.",
    )
    require(
        f"{access_kind} Error Rotation" in successors(f"Validate {access_kind} Source"),
        f"{access_kind} source GET must proceed directly to current data and PostgreSQL checks.",
    )
    require(
        f"Poll {access_kind} Jobs" not in reachable(f"Discover {access_kind} Source"),
        f"An existing ready {access_kind.lower()} source must not enter job polling.",
    )
    require(
        [successors(f"Select {access_kind} Source Action")[0], successors(f"Select {access_kind} Source Action")[1]]
        == [f"Discover {access_kind} Source", f"Generate {access_kind} Password"],
        f"{access_kind} existing-source selection must bypass source creation and password generation.",
    )
    require(
        successors(f"Rotate {access_kind}")
        == [f"Generate {access_kind} Rotation Value", ready],
        f"{access_kind} non-rotation readiness must bypass password mutation.",
    )
    require(
        f"Merge {access_kind} Ready Evidence" in reachable(ready),
        f"{access_kind} registry output must be merged with observed readiness evidence.",
    )
    rotation_if = by_name.get(f"{access_kind} Error Rotation", {}).get("parameters", {})
    require(
        "requestedAccessKind" in json.dumps(rotation_if),
        f"{access_kind} failed-rotation routing must use the preserved requested target.",
    )

for name in ("Prepare Source Response", "Prepare Source Error Response"):
    code = by_name.get(name, {}).get("parameters", {}).get("jsCode", "")
    for forbidden in ("password", "token", "header", "credentialId"):
        require(forbidden.lower() not in code.lower(), f"{name} exposes secret-bearing field {forbidden}.")

notes = "\n".join(
    node.get("parameters", {}).get("content", "")
    for node in nodes
    if node.get("type") == "n8n-nodes-base.stickyNote"
)
for label in ("Automation Data Provisioner", "NocoDB Operator API", "NocoDB Source Provisioning Header"):
    require(label in notes, f"The source setup note omits {label}.")
PY

node - "$source_workflow" "$acceptance_workflow" <<'JS'
const fs = require('fs');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
for (const workflowPath of process.argv.slice(2)) {
  const candidate = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));
  for (const node of candidate.nodes.filter((item) => item.type === 'n8n-nodes-base.code')) {
    try {
      new AsyncFunction('$json', '$input', '$', '$binary', 'helpers', node.parameters.jsCode);
    } catch (error) {
      throw new Error(`${candidate.name} Code node ${node.name} does not compile: ${error.message}`);
    }
  }
}
const byName = Object.fromEntries(workflow.nodes.map((node) => [node.name, node]));
const execute = (name, input, lookup = {}, itemInputs = [input]) => {
  const code = byName[name]?.parameters?.jsCode;
  if (!code) throw new Error(`missing Code node ${name}`);
  return new Function('$json', '$input', '$', code)(
    input,
    { all: () => itemInputs.map((json) => ({ json })) },
    (nodeName) => ({ first: () => ({ json: lookup[nodeName] || input }) }),
  );
};

const operatorRotateRequest = execute('Normalize Source Request', {
  body: { domain: 'domain_one', operation: 'rotate', accessKind: 'operator' },
})[0].json;
if (operatorRotateRequest.requestedAccessKind !== 'operator' || operatorRotateRequest.accessKind !== 'operator') {
  throw new Error('Normalize Source Request did not preserve the explicit rotation target separately');
}

const base = { domain: 'domain_one', accessKind: 'reader', baseId: 'base-1', sourceCreateJobId: 'job-1', pollCount: 3 };
const readerValidation = {
  domain: 'domain_one', accessKind: 'reader', role: 'domain_one_reader', valid: true,
  loginValid: true, schemaPrivilegesValid: true, objectPrivilegesValid: true,
  defaultPrivilegesValid: true, outsideSchemaDenied: true, databaseIsolationValid: true,
  forbiddenAttributesDenied: true, forbiddenMembershipsDenied: true, ddlDenied: true,
  controlledDmlPresent: false,
};
const operatorValidation = {
  domain: 'domain_one', accessKind: 'operator', role: 'domain_one_operator', valid: true,
  loginValid: true, schemaPrivilegesValid: true, objectPrivilegesValid: true,
  defaultPrivilegesValid: true, outsideSchemaDenied: true, databaseIsolationValid: true,
  forbiddenAttributesDenied: true, forbiddenMembershipsDenied: true, ddlDenied: true,
  controlledDmlPresent: true,
};
for (const evaluator of ['Evaluate Reader Job', 'Evaluate Operator Job']) {
  const completed = execute(evaluator, { ...base, jobs: [{ id: 'job-1', job: 'source-create', status: 'completed' }] })[0].json;
  if (completed.jobState !== 'completed' || completed.sourceCreateJobId !== 'job-1') {
    throw new Error(`${evaluator} did not select the exact completed stored job`);
  }
  const failed = execute(evaluator, { ...base, jobs: [{ id: 'job-1', job: 'source-create', status: 'failed' }] })[0].json;
  if (failed.jobState !== 'failed') throw new Error(`${evaluator} did not make failure terminal`);
  for (const [label, input, pattern] of [
    ['missing stored job id', { ...base, sourceCreateJobId: null, jobs: [] }, /missing_stored_job/],
    ['missing job', { ...base, jobs: [] }, /missing_stored_job/],
    ['duplicate job', { ...base, jobs: [
      { id: 'job-1', job: 'source-create', status: 'active' },
      { id: 'job-1', job: 'source-create', status: 'waiting' },
    ] }, /duplicate_stored_job/],
  ]) {
    let rejected = false;
    try { execute(evaluator, input); } catch (error) { rejected = pattern.test(error.message); }
    if (!rejected) throw new Error(`${evaluator} ${label} did not fail closed`);
  }
  const timedOut = execute(evaluator, {
    ...base,
    pollCount: 119,
    jobs: [{ id: 'job-1', job: 'source-create', status: 'active' }],
  })[0].json;
  if (timedOut.jobState !== 'timeout' || timedOut.sourceCreateJobId !== 'job-1' || timedOut.preserveWaiting !== true) {
    throw new Error(`${evaluator} timeout did not preserve waiting state and exact stored job`);
  }
}

const splitJobs = [
  { id: 'unrelated', job: 'source-create', status: 'failed' },
  { id: 'job-1', job: 'source-create', status: 'completed' },
];
const splitCompleted = execute(
  'Evaluate Reader Job',
  splitJobs[0],
  { 'Wait Reader Job': base },
  splitJobs,
)[0].json;
if (splitCompleted.jobState !== 'completed' || splitCompleted.sourceCreateJobId !== 'job-1') {
  throw new Error('split job-list items did not select the exact stored job');
}

for (const [kind, node, alias] of [
  ['Reader', 'Discover Reader Source After Job', 'Read Model'],
  ['Operator', 'Discover Operator Source After Job', 'Operator'],
]) {
  const context = { ...base, accessKind: kind.toLowerCase(), integrationId: `integration-${kind.toLowerCase()}`, jobState: 'completed' };
  const source = { id: `source-${kind.toLowerCase()}`, fk_integration_id: context.integrationId, alias };
  const discovered = execute(node, { list: [source] }, { [`Evaluate ${kind} Job`]: context })[0].json;
  if (discovered.sourceId !== source.id || discovered.jobState !== 'completed') {
    throw new Error(`${node} lost initial completed-job evidence`);
  }
  let noncompletedRejected = false;
  try { execute(node, { list: [source] }, { [`Evaluate ${kind} Job`]: { ...context, jobState: 'pending' } }); }
  catch (error) { noncompletedRejected = /source_job_not_completed/.test(error.message); }
  if (!noncompletedRejected) throw new Error(`${node} accepted source discovery without completed-job evidence`);
}

const sourceContext = { ...base, integrationId: 'integration-1', alias: 'Read Model' };
const mergedRotation = execute(
  'Merge Reader State',
  { result: { state: 'error', operation: 'rotate', sourceId: 'source-1', integrationId: 'integration-1' } },
  { 'Start Reader': { ...sourceContext, operation: 'rotate', requestedAccessKind: 'reader' } },
)[0].json;
if (mergedRotation.operation !== 'rotate' || mergedRotation.registryOperation !== 'rotate' || mergedRotation.requestedAccessKind !== 'reader') {
  throw new Error('requested and retained source operations were not kept distinct');
}
for (const [name, contextNode] of [
  ['Merge Reader State', 'Start Reader'],
  ['Merge Operator State', 'Prepare Operator'],
]) {
  const retainedContextBase = execute(
    name,
    { result: { state: 'awaiting_grants', operation: 'sync', baseId: null } },
    { [contextNode]: { ...sourceContext, operation: 'sync' } },
  )[0].json;
  if (retainedContextBase.baseId !== 'base-1') {
    throw new Error(`${name} erased the discovered base with a null stored base`);
  }
  const retainedStoredBase = execute(
    name,
    { result: { state: 'ready', operation: 'sync', baseId: 'stored-base' } },
    { [contextNode]: { ...sourceContext, operation: 'sync' } },
  )[0].json;
  if (retainedStoredBase.baseId !== 'stored-base') {
    throw new Error(`${name} did not retain a non-null stored base for later identity checks`);
  }
}
for (const [label, request, context, expected] of [
  ['targeted rotation', { operation: 'rotate', requestedAccessKind: 'reader' }, { ...sourceContext, accessKind: 'reader' }, 'rotate'],
  ['non-target reader work', { operation: 'rotate', requestedAccessKind: 'operator' }, { ...sourceContext, accessKind: 'reader' }, 'sync'],
  ['initial sync', { operation: 'sync' }, { ...sourceContext, accessKind: 'reader' }, 'sync'],
]) {
  const preparedError = execute('Prepare Source Error', context, { 'Normalize Source Request': request })[0].json;
  if (preparedError.sourceOperation !== expected) throw new Error(`${label} persisted the wrong source operation`);
}
const unique = execute('Discover Reader Source', {
  ...sourceContext,
  sources: [{ id: 'source-1', base_id: 'base-1', fk_integration_id: 'integration-1', alias: 'Read Model' }],
})[0].json;
if (unique.sourceId !== 'source-1' || unique.selectedIntegrationId !== 'integration-1') {
  throw new Error('unique source did not carry its selected current integration');
}
const uniqueOperator = execute('Discover Operator Source', {
  ...sourceContext,
  accessKind: 'operator',
  alias: 'Operator',
  sources: [{ id: 'source-operator', base_id: 'base-1', fk_integration_id: 'integration-1', alias: 'Operator' }],
})[0].json;
if (uniqueOperator.sourceId !== 'source-operator' || uniqueOperator.selectedIntegrationId !== 'integration-1') {
  throw new Error('unique operator source did not carry its selected current integration');
}
for (const [kind, prepareNode, readNode, discoverNode, alias, schema, readonly] of [
  ['Reader', 'Start Reader', 'Read Reader State', 'Discover Reader Source', 'Read Model', 'read_model', true],
  ['Operator', 'Prepare Operator', 'Read Operator State', 'Discover Operator Source', 'Operator', 'operator', false],
]) {
  const sourceId = `source-${kind.toLowerCase()}`;
  const lookup = {
    [prepareNode]: { ...sourceContext, baseId: 'base-1' },
    [readNode]: { result: { baseId: null } },
    [discoverNode]: { sourceId, selectedIntegrationId: 'integration-1' },
  };
  const validated = execute(`Validate ${kind} Source`, {
    id: sourceId,
    base_id: 'base-1',
    fk_integration_id: 'integration-1',
    alias,
    config: { searchPath: [schema] },
    is_data_readonly: readonly,
    is_schema_readonly: true,
  }, lookup)[0].json;
  if (validated.baseId !== 'base-1') {
    throw new Error(`Validate ${kind} Source erased the discovered base with a null stored base`);
  }
  lookup[readNode] = { result: { baseId: 'stored-base' } };
  const retained = execute(`Validate ${kind} Source`, {
    id: sourceId,
    base_id: 'base-1',
    fk_integration_id: 'integration-1',
    alias,
    config: { searchPath: [schema] },
    is_data_readonly: readonly,
    is_schema_readonly: true,
  }, lookup)[0].json;
  if (retained.baseId !== 'stored-base') {
    throw new Error(`Validate ${kind} Source did not retain a non-null stored base for identity validation`);
  }
}
let duplicateRejected = false;
try {
  execute('Discover Reader Source', {
    ...sourceContext,
    sources: [
      { id: 'source-1', fk_integration_id: 'integration-1', alias: 'Read Model' },
      { id: 'source-2', fk_integration_id: 'integration-1', alias: 'Read Model' },
    ],
  });
} catch (error) { duplicateRejected = /duplicate_source/.test(error.message); }
if (!duplicateRejected) throw new Error('duplicate sources did not fail closed');

let errorRetryRejected = false;
try {
  execute('Inspect Reader Sources', {
    ...sourceContext,
    state: 'error',
    sources: [{ id: 'partial', fk_integration_id: 'integration-1', alias: 'Read Model' }],
  });
} catch (error) { errorRetryRejected = /error_retry_requires_zero_sources/.test(error.message); }
if (!errorRetryRejected) throw new Error('error retry accepted an existing deterministic source');

const failedRotation = {
  ...sourceContext,
  operation: 'rotate',
  requestedAccessKind: 'reader',
  registryOperation: 'rotate',
  state: 'error',
  sourceId: 'source-1',
  sources: [{ id: 'source-1', fk_integration_id: 'integration-1', alias: 'Read Model' }],
};
const retryRotation = execute('Inspect Reader Sources', failedRotation)[0].json;
if (retryRotation.action !== 'existing' || retryRotation.sourceId !== 'source-1') {
  throw new Error('failed rotation did not retain the exact source identity');
}
const failedOperatorRotation = {
  ...failedRotation,
  requestedAccessKind: 'operator',
  accessKind: 'operator',
  alias: 'Operator',
  sourceId: 'source-operator',
  sources: [{ id: 'source-operator', fk_integration_id: 'integration-1', alias: 'Operator' }],
};
if (execute('Inspect Operator Sources', failedOperatorRotation)[0].json.action !== 'existing') {
  throw new Error('failed operator rotation did not retain the exact source identity');
}
let mismatchedOperatorIdentityRejected = false;
try {
  execute('Inspect Operator Sources', {
    ...failedOperatorRotation,
    sources: [{ id: 'other-operator', fk_integration_id: 'integration-1', alias: 'Operator' }],
  });
} catch (error) { mismatchedOperatorIdentityRejected = /rotation_source_identity_mismatch/.test(error.message); }
if (!mismatchedOperatorIdentityRejected) throw new Error('operator rotation accepted a mismatched retained source identity');
for (const [node, input, pattern] of [
  ['Inspect Reader Sources', { ...failedRotation, requestedAccessKind: 'operator' }, /rotation_target_mismatch/],
  ['Inspect Operator Sources', { ...failedOperatorRotation, requestedAccessKind: 'reader' }, /rotation_target_mismatch/],
]) {
  let rejected = false;
  try { execute(node, input); } catch (error) { rejected = pattern.test(error.message); }
  if (!rejected) throw new Error(`${node} resumed rotation for the other requested access kind`);
}
const operatorTargetReaderGate = execute(
  'Require Reader PostgreSQL',
  { result: readerValidation },
  {
    'Validate Reader Source': { ...sourceContext, requestedAccessKind: 'operator', sourceCreateJobState: null },
    'Normalize Source Request': operatorRotateRequest,
  },
)[0].json;
if (operatorTargetReaderGate.rotateTarget !== false) throw new Error('operator-targeted rotation enabled the reader rotation path');
const operatorTargetOperatorGate = execute(
  'Require Operator PostgreSQL',
  { result: operatorValidation },
  {
    'Validate Operator Source': { ...sourceContext, accessKind: 'operator', requestedAccessKind: 'operator', sourceCreateJobState: null },
    'Normalize Source Request': operatorRotateRequest,
  },
)[0].json;
if (operatorTargetOperatorGate.rotateTarget !== true) throw new Error('operator-targeted rotation did not enable the operator rotation path');
if (operatorTargetReaderGate.postgresqlValidation.valid !== true || operatorTargetReaderGate.postgresqlValidation.controlledDmlPresent !== false) {
  throw new Error('reader PostgreSQL readiness matrix was not preserved from validate_nocodb_access');
}
if (operatorTargetOperatorGate.postgresqlValidation.valid !== true || operatorTargetOperatorGate.postgresqlValidation.controlledDmlPresent !== true) {
  throw new Error('operator PostgreSQL readiness matrix was not preserved from validate_nocodb_access');
}

const storedReader = {
  domain: 'domain_one', accessKind: 'reader', state: 'ready', baseId: 'base-1', sourceId: 'source-1',
  integrationId: 'integration-1', sourceCreateJobId: 'job-1', generation: 11, credentialGeneration: 2,
  operationStartedAt: '2026-09-04T12:00:00Z', updatedAt: '2026-09-04T12:01:00Z', validatedAt: '2026-09-04T12:01:00Z',
};
const observedReader = {
  ...operatorTargetReaderGate, sourceId: 'source-1', integrationId: 'integration-1', sourceCreateJobId: 'job-1',
  sourceCreateJobState: null, sourceDiscovered: true, sourceReadBack: true,
  dataEditAllowed: false, schemaEditAllowed: false,
};
const mergedReaderReady = execute(
  'Merge Reader Ready Evidence', { result: storedReader },
  { 'Normalize Source Request': { domain: 'domain_one', operation: 'sync', requestedAccessKind: null }, 'Require Reader PostgreSQL': observedReader },
)[0].json;
if (mergedReaderReady.credentialGeneration !== 2 || mergedReaderReady.sourceCreateJobState !== null || mergedReaderReady.postgresqlValidation.valid !== true) {
  throw new Error('reader stored state and observed readiness evidence were not merged');
}
const storedOperator = {
  domain: 'domain_one', accessKind: 'operator', state: 'ready', baseId: 'base-1', sourceId: 'source-operator',
  integrationId: 'integration-operator', sourceCreateJobId: 'job-operator', generation: 12, credentialGeneration: 3,
  operationStartedAt: '2026-09-04T12:02:00Z', updatedAt: '2026-09-04T12:03:00Z', validatedAt: '2026-09-04T12:03:00Z',
};
const observedOperator = {
  ...operatorTargetOperatorGate, sourceId: 'source-operator', integrationId: 'integration-operator', sourceCreateJobId: 'job-operator',
  sourceCreateJobState: null, sourceDiscovered: true, sourceReadBack: true,
  dataEditAllowed: true, schemaEditAllowed: false,
};
const mergedOperatorReady = execute(
  'Merge Operator Ready Evidence', { result: storedOperator },
  { 'Normalize Source Request': operatorRotateRequest, 'Keep Rotated Operator': observedOperator },
)[0].json;
if (mergedOperatorReady.credentialGeneration !== 3 || mergedOperatorReady.postgresqlValidation.controlledDmlPresent !== true) {
  throw new Error('rotated operator response lost stored or observed readiness evidence');
}
const mergedOperatorSync = execute(
  'Merge Operator Ready Evidence', { result: storedOperator },
  {
    'Normalize Source Request': { domain: 'domain_one', operation: 'sync', requestedAccessKind: null },
    'Require Operator PostgreSQL': observedOperator,
  },
)[0].json;
if (mergedOperatorSync.sourceCreateJobState !== null || mergedOperatorSync.postgresqlValidation.valid !== true) {
  throw new Error('unchanged operator sync lost observed readiness evidence');
}
const boundedSourceResponse = execute('Prepare Source Response', mergedOperatorReady, {
  'Normalize Source Request': operatorRotateRequest,
  'Merge Reader Ready Evidence': mergedReaderReady,
})[0].json;
const boundedResponseKeys = ['baseId', 'domain', 'errorCode', 'ok', 'operation', 'operator', 'reader'];
if (JSON.stringify(Object.keys(boundedSourceResponse).sort()) !== JSON.stringify(boundedResponseKeys)) {
  throw new Error('source response exposed request-routing or unbounded internal fields');
}
const readyEvidenceKeys = [
  'accessKind', 'credentialGeneration', 'dataEditAllowed', 'generation', 'integrationId', 'operationStartedAt',
  'postgresqlValidation', 'schemaEditAllowed', 'sourceCreateJobId', 'sourceCreateJobState', 'sourceDiscovered',
  'sourceId', 'sourceReadBack', 'state', 'updatedAt', 'validatedAt',
];
const validationEvidenceKeys = [
  'controlledDmlPresent', 'databaseIsolationValid', 'ddlDenied', 'defaultPrivilegesValid',
  'forbiddenAttributesDenied', 'forbiddenMembershipsDenied', 'loginValid', 'objectPrivilegesValid',
  'outsideSchemaDenied', 'schemaPrivilegesValid', 'valid',
];
for (const kind of ['reader', 'operator']) {
  if (JSON.stringify(Object.keys(boundedSourceResponse[kind]).sort()) !== JSON.stringify(readyEvidenceKeys)) {
    throw new Error(`${kind} source response omitted or exposed readiness evidence fields`);
  }
  if (boundedSourceResponse[kind].sourceCreateJobState !== null || boundedSourceResponse[kind].postgresqlValidation.valid !== true) {
    throw new Error(`${kind} day-two source response fabricated job history or omitted PostgreSQL evidence`);
  }
  if (JSON.stringify(Object.keys(boundedSourceResponse[kind].postgresqlValidation).sort()) !== JSON.stringify(validationEvidenceKeys)) {
    throw new Error(`${kind} source response exposed a non-boolean or unbounded PostgreSQL result`);
  }
}
let inferredReadyEvidenceRejected = false;
try {
  execute('Prepare Source Response', storedReader, {
    'Normalize Source Request': { domain: 'domain_one', operation: 'sync', requestedAccessKind: null },
  });
} catch (error) { inferredReadyEvidenceRejected = /source_response_evidence_invalid/.test(error.message); }
if (!inferredReadyEvidenceRejected) throw new Error('state=ready fabricated missing source, job, UI, or PostgreSQL evidence');
for (const forbidden of ['password', 'token', 'header', 'credentialId', 'role']) {
  if (JSON.stringify(boundedSourceResponse).toLowerCase().includes(forbidden.toLowerCase())) {
    throw new Error(`source response exposed secret-bearing or internal field ${forbidden}`);
  }
}
const unchangedSyncResponse = execute('Prepare Source Response', mergedOperatorSync, {
  'Normalize Source Request': { domain: 'domain_one', operation: 'sync', requestedAccessKind: null },
  'Merge Reader Ready Evidence': mergedReaderReady,
})[0].json;
if (unchangedSyncResponse.operation !== 'sync' || unchangedSyncResponse.reader.postgresqlValidation.valid !== true || unchangedSyncResponse.operator.postgresqlValidation.valid !== true) {
  throw new Error('unchanged sync response was not complete');
}
const awaitingOperator = execute(
  'Capture Optional Operator State',
  { result: {
    domain: 'domain_one', accessKind: 'operator', state: 'awaiting_grants', baseId: null, sourceId: null,
    integrationId: null, sourceCreateJobId: null, generation: 8, credentialGeneration: 0,
    operationStartedAt: '2026-09-04T11:00:00Z', updatedAt: '2026-09-04T11:00:00Z', validatedAt: null,
  } },
  { 'Start Operator': { domain: 'domain_one', operation: 'sync', reader: mergedReaderReady, plan: { operatorRequested: true } } },
)[0].json;
const awaitingResponse = execute('Prepare Source Response', awaitingOperator, {
  'Normalize Source Request': { domain: 'domain_one', operation: 'sync', requestedAccessKind: null },
  'Merge Reader Ready Evidence': mergedReaderReady,
})[0].json;
if (
  awaitingResponse.ok !== true || awaitingResponse.operator.state !== 'awaiting_grants'
  || awaitingResponse.operator.sourceCreateJobState !== null || awaitingResponse.operator.postgresqlValidation !== null
) throw new Error('awaiting-grants operator response fabricated readiness evidence');
let failedOperatorInitialRejected = false;
try { execute('Inspect Operator Sources', { ...failedOperatorRotation, registryOperation: 'sync' }); }
catch (error) { failedOperatorInitialRejected = /rotation_retry_invalid/.test(error.message); }
if (!failedOperatorInitialRejected) throw new Error('failed initial operator source entered rotation retry');
for (const [name, input] of [
  ['Inspect Reader Sources', {
    ...sourceContext,
    operation: 'rotate',
    registryOperation: 'sync',
    state: 'error',
    sourceId: null,
    integrationId: null,
    sources: [],
  }],
  ['Inspect Operator Sources', {
    ...sourceContext,
    accessKind: 'operator',
    alias: 'Operator',
    operation: 'rotate',
    registryOperation: 'sync',
    state: 'error',
    sourceId: null,
    integrationId: null,
    sources: [],
  }],
]) {
  let rejected = false;
  try { execute(name, input); } catch (error) { rejected = /rotation_retry_invalid/.test(error.message); }
  if (!rejected) throw new Error(`${name} let a zero-source failed initial generation enter create during rotation`);
}
for (const [label, input, pattern] of [
  ['sync with retained source', { ...failedRotation, operation: 'sync' }, /error_retry_requires_zero_sources/],
  ['rotation of failed initial source', { ...failedRotation, registryOperation: 'sync' }, /rotation_retry_invalid/],
  ['rotation with mismatched source', {
    ...failedRotation,
    sources: [{ id: 'other-source', fk_integration_id: 'integration-1', alias: 'Read Model' }],
  }, /rotation_source_identity_mismatch/],
  ['rotation without retained source', {
    ...failedRotation,
    sourceId: null,
    sources: [],
  }, /rotation_identity_missing/],
]) {
  let rejected = false;
  try { execute('Inspect Reader Sources', input); } catch (error) { rejected = pattern.test(error.message); }
  if (!rejected) throw new Error(`${label} did not fail closed`);
}
const initialRetry = execute('Inspect Reader Sources', {
  ...sourceContext,
  operation: 'sync',
  registryOperation: 'sync',
  state: 'error',
  sourceId: null,
  integrationId: null,
  sources: [],
})[0].json;
if (initialRetry.action !== 'create') throw new Error('failed initial creation with zero sources cannot retry');

for (const fixture of [
  {
    name: 'reader',
    node: 'Validate Reader Source',
    inspectNode: 'Inspect Reader Sources',
    requireNode: 'Require Reader PostgreSQL',
    validation: readerValidation,
    source: {
      id: 'source-1', base_id: 'base-1', fk_integration_id: 'integration-current', alias: 'Read Model',
      config: { searchPath: ['read_model'] }, is_data_readonly: true, is_schema_readonly: true,
    },
    lookup: {
      'Start Reader': { ...sourceContext, baseId: 'base-1' },
      'Read Reader State': { result: { sourceId: 'source-1', integrationId: 'integration-stale' } },
      'Discover Reader Source': { sourceId: 'source-1', selectedIntegrationId: 'integration-current' },
    },
  },
  {
    name: 'operator',
    node: 'Validate Operator Source',
    inspectNode: 'Inspect Operator Sources',
    requireNode: 'Require Operator PostgreSQL',
    validation: operatorValidation,
    source: {
      id: 'source-operator', base_id: 'base-1', fk_integration_id: 'integration-current', alias: 'Operator',
      config: { searchPath: ['operator'] }, is_data_readonly: false, is_schema_readonly: true,
    },
    lookup: {
      'Prepare Operator': { ...sourceContext, baseId: 'base-1', accessKind: 'operator' },
      'Read Operator State': { result: { sourceId: 'source-operator', integrationId: 'integration-stale' } },
      'Discover Operator Source': { sourceId: 'source-operator', selectedIntegrationId: 'integration-current' },
    },
  },
]) {
  const readySelection = execute(fixture.inspectNode, {
    domain: 'domain_one', operation: 'sync', state: 'ready', accessKind: fixture.name,
    alias: fixture.source.alias, sourceId: fixture.source.id, integrationId: fixture.source.fk_integration_id,
    sources: [fixture.source],
  })[0].json;
  if (readySelection.action !== 'existing') {
    throw new Error(`${fixture.name} ready sync selected source creation or password generation`);
  }
  const valid = execute(fixture.node, fixture.source, fixture.lookup)[0].json;
  if (valid.integrationId !== 'integration-current') throw new Error(`${fixture.name} GET did not accept its selected current integration`);
  if (valid.dataEditAllowed !== (fixture.name === 'operator') || valid.schemaEditAllowed !== false || valid.sourceDiscovered !== true || valid.sourceReadBack !== true) {
    throw new Error(`${fixture.name} source GET flags were not preserved as observed evidence`);
  }
  if (valid.sourceCreateJobState !== null) throw new Error(`${fixture.name} ready source fabricated completed-job history`);
  const currentEvidence = execute(
    fixture.requireNode,
    { result: fixture.validation },
    {
      [fixture.node]: valid,
      'Normalize Source Request': { domain: 'domain_one', operation: 'sync', requestedAccessKind: null },
    },
  )[0].json;
  if (currentEvidence.postgresqlValidation.valid !== true || currentEvidence.rotateTarget !== false || currentEvidence.sourceCreateJobState !== null) {
    throw new Error(`${fixture.name} ready sync did not carry fresh source and PostgreSQL evidence without job history`);
  }
  let mismatchRejected = false;
  try { execute(fixture.node, { ...fixture.source, fk_integration_id: 'integration-other' }, fixture.lookup); }
  catch (error) { mismatchRejected = /source_identity_invalid/.test(error.message); }
  if (!mismatchRejected) throw new Error(`${fixture.name} GET accepted an integration different from discovery`);
}

for (const fixture of [
  {
    node: 'Validate Reader Source',
    source: { id: 'source-new-reader', base_id: 'base-1', fk_integration_id: 'integration-new', alias: 'Read Model', config: { searchPath: ['read_model'] }, is_data_readonly: true, is_schema_readonly: true },
    lookup: {
      'Start Reader': { domain: 'domain_one', baseId: 'base-1' },
      'Read Reader State': { result: null },
      'Discover Reader Source After Job': { sourceId: 'source-new-reader', selectedIntegrationId: 'integration-new', sourceCreateJobId: 'job-current-reader', jobState: 'completed' },
    },
    expected: 'job-current-reader',
  },
  {
    node: 'Validate Operator Source',
    source: { id: 'source-new-operator', base_id: 'base-1', fk_integration_id: 'integration-new', alias: 'Operator', config: { searchPath: ['operator'] }, is_data_readonly: false, is_schema_readonly: true },
    lookup: {
      'Prepare Operator': { domain: 'domain_one', baseId: 'base-1' },
      'Read Operator State': { result: null },
      'Discover Operator Source After Job': { sourceId: 'source-new-operator', selectedIntegrationId: 'integration-new', sourceCreateJobId: 'job-current-operator', jobState: 'completed' },
    },
    expected: 'job-current-operator',
  },
]) {
  const initialEvidence = execute(fixture.node, fixture.source, fixture.lookup)[0].json;
  if (initialEvidence.sourceCreateJobId !== fixture.expected || initialEvidence.sourceCreateJobState !== 'completed') {
    throw new Error(`${fixture.node} did not carry the current completed job identity into read-back evidence`);
  }
}

const queueContext = {
  ...sourceContext,
  state: 'provisioning',
  currentIntegrationId: 'integration-1',
  sources: [],
};
if (execute('Require Reader Queue Slot', queueContext)[0].json.integrationId !== 'integration-1') {
  throw new Error('queue slot did not bind the current integration identity');
}
for (const [label, sources, pattern] of [
  ['existing exact source', [{ id: 'source-1', fk_integration_id: 'integration-1', alias: 'Read Model' }], /source_exists_before_queue/],
  ['mismatched integration', [{ id: 'source-1', fk_integration_id: 'other-integration', alias: 'Read Model' }], /source_integration_mismatch/],
  ['mismatched alias', [{ id: 'source-1', fk_integration_id: 'integration-1', alias: 'Other' }], /source_alias_mismatch/],
]) {
  let rejected = false;
  try { execute('Require Reader Queue Slot', { ...queueContext, sources }); } catch (error) { rejected = pattern.test(error.message); }
  if (!rejected) throw new Error(`queue slot accepted ${label}`);
}

for (const name of [
  'Require Reader Data Probe',
  'Require Rotated Reader Data Probe',
  'Require Operator Data Probe',
  'Require Rotated Operator Data Probe',
]) {
  const context = { domain: 'domain_one', accessKind: name.includes('Operator') ? 'operator' : 'reader', sourceId: 'source-1' };
  const success = execute(name, { statusCode: 200, body: { list: [], pageInfo: {} }, context })[0].json;
  if (success.sourceId !== 'source-1' || success.dataProbeReady !== true) {
    throw new Error(`${name} did not accept the bounded normal data response`);
  }
  let rejected = false;
  try { execute(name, { statusCode: 200, body: { unexpected: [] }, context }); } catch (error) { rejected = /data_probe_invalid/.test(error.message); }
  if (!rejected) throw new Error(`${name} accepted a malformed data response`);
}
JS

python - "$acceptance_workflow" <<'PY'
import base64
import hashlib
import json
import re
import sys
from pathlib import Path


workflow = json.loads(Path(sys.argv[1]).read_text())
nodes = workflow.get("nodes", [])
by_name = {node.get("name"): node for node in nodes}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


canary_bytes = base64.b64decode(
    "bm9jb2RiLWlzc3VlMzM0LWF0dGFjaG1lbnQtY2FuYXJ5LXYxCg==", validate=True
)
require(
    canary_bytes == b"nocodb-issue334-attachment-canary-v1\n"
    and len(canary_bytes) == 37
    and hashlib.sha256(canary_bytes).hexdigest()
    == "09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3",
    "Recovery canary bytes, size, and checksum constants differ.",
)


require(len(by_name) == len(nodes), "Acceptance workflow node names must be unique.")
require(workflow.get("name") == "NocoDB Acceptance Domain", "Unexpected acceptance workflow name.")
require(workflow.get("active") is False, "The acceptance workflow template must be inactive.")
require(
    workflow.get("settings") == {
        "executionOrder": "v1",
        "saveDataErrorExecution": "none",
        "saveDataSuccessExecution": "none",
        "saveManualExecutions": False,
        "saveExecutionProgress": False,
    },
    "The acceptance workflow must use execution order v1 and disable all execution persistence.",
)

webhook = by_name.get("Acceptance Webhook", {}).get("parameters", {})
require(
    webhook.get("httpMethod") == "POST"
    and webhook.get("path") == "nocodb-acceptance-domain"
    and webhook.get("authentication") == "headerAuth"
    and webhook.get("responseMode") == "responseNode",
    "The acceptance webhook contract is not exact.",
)
normalize = by_name.get("Normalize Acceptance Request", {}).get("parameters", {}).get("jsCode", "")
for marker in ("operation", "runId", "structure", "grants", "probe", "cleanup", "Object.keys", "allowedFields", "recovery-canary-v1"):
    require(marker in normalize, f"Acceptance request validation omits {marker}.")
for forbidden in ("domain", "sql"):
    require(not re.search(rf"['\"]{forbidden}['\"]", normalize), f"Acceptance accepts forbidden field {forbidden}.")

structure_sql = by_name.get("Create Acceptance Structure", {}).get("parameters", {}).get("query", "")
required_structure = (
    "CREATE SCHEMA IF NOT EXISTS read_model AUTHORIZATION issue334_acceptance_owner;",
    "CREATE SCHEMA IF NOT EXISTS operator AUTHORIZATION issue334_acceptance_owner;",
    "CREATE TABLE IF NOT EXISTS app.acceptance_fact (",
    "id bigint PRIMARY KEY,",
    "fact text NOT NULL",
    "CREATE OR REPLACE VIEW read_model.acceptance_facts AS",
    "SELECT id, fact FROM app.acceptance_fact;",
    "CREATE TABLE IF NOT EXISTS operator.acceptance_decision (",
    "id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,",
    "run_id text NOT NULL,",
    "decision text NOT NULL,",
    "protected_created_at timestamptz NOT NULL DEFAULT clock_timestamp()",
    "CREATE UNIQUE INDEX IF NOT EXISTS issue334_acceptance_recovery_canary_one",
    "WHERE run_id = 'recovery-canary-v1';",
)
for marker in required_structure:
    require(marker in structure_sql, f"Acceptance structure SQL omits {marker}")
require("SET LOCAL ROLE issue334_acceptance_owner;" in structure_sql, "Acceptance DDL must run as the owner role.")

grant_sql = by_name.get("Grant Acceptance Operator Access", {}).get("parameters", {}).get("query", "")
for marker in (
    "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'issue334_acceptance_operator') THEN",
    "RAISE EXCEPTION 'operator_candidate_missing';",
    "GRANT USAGE ON SCHEMA operator TO issue334_acceptance_operator;",
    "GRANT SELECT, INSERT, DELETE ON TABLE operator.acceptance_decision TO issue334_acceptance_operator;",
    "GRANT UPDATE (decision) ON TABLE operator.acceptance_decision TO issue334_acceptance_operator;",
    "GRANT USAGE ON SEQUENCE operator.acceptance_decision_id_seq TO issue334_acceptance_operator;",
):
    require(marker in grant_sql, f"Acceptance grant SQL omits {marker}")

postgres_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.postgres"]
require(len(postgres_nodes) == 6, "Acceptance must have exactly six fixed migrator operations.")
cleanup_sql = "BEGIN;\nSET LOCAL ROLE issue334_acceptance_owner;\nDELETE FROM app.acceptance_fact WHERE id = $1 AND fact = $2;\nCOMMIT;"
for name in ("Clear Reader Negative Residue", "Cleanup Unexpected Reader Insert"):
    parameters = by_name.get(name, {}).get("parameters", {})
    require(
        parameters.get("operation") == "executeQuery"
        and parameters.get("query") == cleanup_sql
        and parameters.get("options", {}).get("queryReplacement")
        == "={{ [$json.readerProbeId, $json.readerProbeFact] }}",
        f"{name} must use the fixed owner-authority cleanup transaction.",
    )
claim = by_name.get("Claim Recovery Canary Upload", {}).get("parameters", {})
claim_sql = claim.get("query", "")
for marker in (
    "BEGIN;",
    "SET LOCAL ROLE issue334_acceptance_owner;",
    "UPDATE operator.acceptance_decision",
    "WHERE id = $1",
    "AND run_id = 'recovery-canary-v1'",
    'AND decision = \'{"kind":"nocodb-attachment-recovery-canary","version":1,"state":"pending"}\'',
    "RETURNING id AS \"rowId\";",
    "COMMIT;",
):
    require(marker in claim_sql, f"Recovery canary upload claim omits {marker}")
require(
    claim.get("operation") == "executeQuery"
    and claim.get("options", {}).get("queryReplacement") == "={{ [$json.rowId] }}",
    "Recovery canary upload claim must bind only the validated row ID.",
)
initialize = by_name.get("Initialize Recovery Canary Row", {})
initialize_sql = initialize.get("parameters", {}).get("query", "")
for marker in (
    "BEGIN;",
    "SET LOCAL ROLE issue334_acceptance_owner;",
    "INSERT INTO operator.acceptance_decision (run_id, decision)",
    "VALUES ('recovery-canary-v1', '{\"kind\":\"nocodb-attachment-recovery-canary\",\"version\":1,\"state\":\"pending\"}')",
    "ON CONFLICT DO NOTHING;",
    "COMMIT;",
):
    require(marker in initialize_sql, f"Recovery canary initialization omits {marker}")
require(
    initialize.get("alwaysOutputData") is True,
    "Recovery canary conflict initialization must always continue to the row re-list.",
)
require(
    by_name["Claim Recovery Canary Upload"].get("alwaysOutputData") is True,
    "A losing recovery canary upload claim must still reach the fail-closed guard.",
)
for node in postgres_nodes:
    query = node.get("parameters", {}).get("query", "")
    require(
        re.findall(r"SET LOCAL ROLE ([a-z0-9_]+);", query) == ["issue334_acceptance_owner"],
        f"{node['name']} must assume only the fixed owner role.",
    )
    require(
        "{{$json" not in query and "EXECUTE " not in query.upper() and "format(" not in query.lower(),
        f"{node['name']} accepts dynamic SQL or a dynamic role.",
    )

http_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.httpRequest"]
require(http_nodes, "The acceptance workflow must use the NocoDB data API.")
methods = [node.get("parameters", {}).get("method", "GET") for node in http_nodes]
for method in ("POST", "GET", "PATCH", "DELETE"):
    require(method in methods, f"Acceptance probe omits {method} data behavior.")
for node in http_nodes:
    parameters = node.get("parameters", {})
    require(
        parameters.get("authentication") == "genericCredentialType"
        and parameters.get("genericAuthType") == "httpHeaderAuth",
        f"{node['name']} must use the NocoDB API Header Auth credential.",
    )
    url = parameters.get("url", "")
    require("http://nocodb.automation-data.svc.cluster.local:8080/" in url, f"{node['name']} has an unapproved API host.")
    require(
        "/tables/" in url
        or url.endswith("/api/v2/meta/bases")
        or ("/api/v2/meta/bases/" in url and ("/sources" in url or "/tables" in url or "/shared" in url))
        or url.endswith("/api/v2/meta/comments")
        or url.endswith("/api/v2/storage/upload")
        or url.startswith("={{ 'http://nocodb.automation-data.svc.cluster.local:8080/' + $json.attachment.path }}"),
        f"{node['name']} has an unapproved acceptance API path.",
    )

canary_http = {name: by_name.get(name, {}).get("parameters", {}) for name in (
    "Get Recovery Saved View",
    "List Recovery Canary Rows",
    "Upload Recovery Canary",
    "Record Uploaded Recovery Canary",
    "List Recovery Canary Comments",
    "Create Recovery Canary Comment",
    "Record Ready Recovery Canary",
    "Download Recovery Canary",
)}
require(all(canary_http.values()), "Acceptance recovery canary HTTP graph is incomplete.")
require("Create Pending Recovery Canary" not in by_name, "Recovery canary initialization must not use a NocoDB create race.")
require(
    canary_http["Get Recovery Saved View"].get("method", "GET") == "GET"
    and "/api/v2/meta/tables/" in canary_http["Get Recovery Saved View"].get("url", "")
    and canary_http["Get Recovery Saved View"].get("url", "").endswith("/views' }}"),
    "Recovery canary must read the exact reflected facts-table views endpoint.",
)
upload = canary_http["Upload Recovery Canary"]
upload_query = {item.get("name"): item.get("value") for item in upload.get("queryParameters", {}).get("parameters", [])}
require(
    upload.get("method") == "POST"
    and upload.get("url", "").endswith("/api/v2/storage/upload")
    and upload.get("contentType") == "multipart-form-data"
    and upload_query == {"path": "issue334_acceptance/recovery-canary-v1"}
    and upload.get("bodyParameters", {}).get("parameters") == [{
        "parameterType": "formBinaryData",
        "name": "file",
        "inputDataFieldName": "canaryFile",
    }],
    "Recovery canary upload must use one fixed multipart file and storage path.",
)
comment_lists = [canary_http["List Recovery Canary Comments"]]
for parameters in comment_lists:
    query = {item.get("name"): item.get("value") for item in parameters.get("queryParameters", {}).get("parameters", [])}
    require(
        parameters.get("method", "GET") == "GET"
        and parameters.get("url", "").endswith("/api/v2/meta/comments")
        and set(query) == {"fk_model_id", "row_id"},
        "Recovery canary comment discovery must use only exact model and row query parameters.",
    )
require(
    canary_http["Create Recovery Canary Comment"].get("method") == "POST"
    and canary_http["Create Recovery Canary Comment"].get("url", "").endswith("/api/v2/meta/comments"),
    "Recovery canary association must use the pinned comment-create endpoint.",
)
download = canary_http["Download Recovery Canary"]
require(
    download.get("method", "GET") == "GET"
    and download.get("options", {}).get("response", {}).get("response", {}) == {
        "responseFormat": "file",
        "outputPropertyName": "canaryDownload",
    },
    "Recovery canary download must return one bounded binary property for exact verification.",
)
prepare_binary_code = by_name.get("Prepare Recovery Canary Binary", {}).get("parameters", {}).get("jsCode", "")
verify_binary_code = by_name.get("Require Recovery Canary Download", {}).get("parameters", {}).get("jsCode", "")
require(
    "await helpers.prepareBinaryData(buffer, 'issue334-recovery-canary-v1.txt', 'text/plain')" in prepare_binary_code,
    "Recovery canary upload binary must use the configured n8n binary manager.",
)
require(
    "await helpers.getBinaryDataBuffer(0, 'canaryDownload')" in verify_binary_code
    and "$binary" not in verify_binary_code,
    "Recovery canary verification must resolve filesystem binary data through the Code helper.",
)
for name, parameters in canary_http.items():
    method = parameters.get("method", "GET")
    url = parameters.get("url", "")
    if "comment" in url or "/download/" in url or "attachment.path" in url:
        require(method in {"GET", "POST"}, f"{name} uses a forbidden canary association or download mutation.")

share_nodes = {
    node["name"]: node.get("parameters", {})
    for node in http_nodes
    if "/shared" in node.get("parameters", {}).get("url", "")
    or "/share" in node.get("parameters", {}).get("url", "")
}
require(
    set(share_nodes) == {"Get Acceptance Base Share", "Get Reader Shared Views", "Get Operator Shared Views"},
    "Acceptance must make exactly one base-share and two exact table-share reads.",
)
require(
    all(parameters.get("method", "GET") == "GET" for parameters in share_nodes.values()),
    "Acceptance public-share checks must be GET-only.",
)
require(
    "/api/v2/meta/bases/" in share_nodes["Get Acceptance Base Share"].get("url", "")
    and "/shared" in share_nodes["Get Acceptance Base Share"].get("url", "")
    and "/api/v2/meta/tables/" in share_nodes["Get Reader Shared Views"].get("url", "")
    and "/share" in share_nodes["Get Reader Shared Views"].get("url", "")
    and "/api/v2/meta/tables/" in share_nodes["Get Operator Shared Views"].get("url", "")
    and "/share" in share_nodes["Get Operator Shared Views"].get("url", ""),
    "Acceptance public-share checks use the wrong NocoDB endpoints.",
)

reader_read = by_name.get("Read Acceptance Facts", {}).get("parameters", {})
require(
    reader_read.get("method") == "GET"
    and "/api/v2/tables/" in reader_read.get("url", "")
    and {item.get("name"): str(item.get("value")) for item in reader_read.get("queryParameters", {}).get("parameters", [])}.get("limit") == "1",
    "The acceptance probe must perform a bounded reader GET of acceptance_facts.",
)

serialized = json.dumps(workflow)
require("issue334_acceptance" in serialized, "The acceptance domain must be fixed.")
require(not any("credentials" in node for node in nodes), "The acceptance template must not embed credential IDs.")
require("DROP " not in serialized.upper() and "TRUNCATE " not in serialized.upper(), "Acceptance must not expose broad destructive SQL.")
response_predecessors = {
    source
    for source, outputs in workflow.get("connections", {}).items()
    if any(
        edge.get("node") == "Respond"
        for output in outputs.get("main", [])
        for edge in output
    )
}
require(
    response_predecessors
    == {"Structure Result", "Grant Result", "Require Cleanup Absent", "Prepare Acceptance Response", "Prepare Acceptance Error Response"},
    "The acceptance response must use only the bounded response builders.",
)
for name in response_predecessors:
    code = by_name.get(name, {}).get("parameters", {}).get("jsCode", "")
    for forbidden in ("password", "token", "header", "credentialId"):
        require(forbidden.lower() not in code.lower(), f"{name} exposes secret-bearing field {forbidden}.")

connections = workflow.get("connections", {})
pending = ["Acceptance Webhook"]
reachable = {"Acceptance Webhook"}
while pending:
    source = pending.pop()
    for output in connections.get(source, {}).get("main", []):
        for edge in output:
            if edge["node"] not in reachable:
                reachable.add(edge["node"])
                pending.append(edge["node"])
executable_nodes = {node["name"] for node in nodes if node.get("type") != "n8n-nodes-base.stickyNote"}
require(executable_nodes <= reachable, "Every acceptance executable node must be reachable from the webhook.")
require(
    "Require Reader Facts Read" in reachable
    and "Insert Acceptance Decision" in {
        edge["node"]
        for output in connections.get("Require Reader Facts Read", {}).get("main", [])
        for edge in output
    },
    "The successful reader GET must be verified before the acceptance write probes.",
)
require(
    "Cleanup Unexpected Reader Insert" in reachable
    and "Fail Unexpected Reader Insert" in {
        edge["node"]
        for output in connections.get("Cleanup Unexpected Reader Insert", {}).get("main", [])
        for edge in output
    },
    "An unexpectedly permitted reader insert must be cleaned before failure.",
)
require(
    "List Cleanup Decisions" in {
        edge["node"]
        for output in connections.get("Continue Cleanup", {}).get("main", [])
        for edge in output
    }
    and "Require Cleanup Absent" in reachable,
    "Cleanup must page within its bound and re-read to prove runId absence.",
)
require(
    "Get Acceptance Reader Source" in {
        edge["node"] for output in connections.get("Keep Acceptance Sources", {}).get("main", []) for edge in output
    }
    and "Get Acceptance Operator Source" in reachable
    and "List Acceptance Tables" in {
        edge["node"] for output in connections.get("Capture Acceptance Operator Source", {}).get("main", []) for edge in output
    },
    "Acceptance must read both exact source configurations before resolving reflected tables.",
)
require(
    "Get Acceptance Base Share" in {
        edge["node"] for output in connections.get("Resolve Acceptance Tables", {}).get("main", []) for edge in output
    }
    and "Get Reader Shared Views" in {
        edge["node"] for output in connections.get("Require Acceptance Base Private", {}).get("main", []) for edge in output
    }
    and "Get Operator Shared Views" in {
        edge["node"] for output in connections.get("Require Reader Shares Empty", {}).get("main", []) for edge in output
    }
    and "Cleanup Only" in {
        edge["node"] for output in connections.get("Require Operator Shares Empty", {}).get("main", []) for edge in output
    },
    "Acceptance must validate the base and both exact table share surfaces before probing or cleanup.",
)
def outgoing(name):
    return {
        edge["node"]
        for output in connections.get(name, {}).get("main", [])
        for edge in output
    }

def ordered_outputs(name):
    return [
        [edge["node"] for edge in output]
        for output in connections.get(name, {}).get("main", [])
    ]

require(
    ordered_outputs("Select Recovery Canary State") == [
        ["Initialize Recovery Canary Row"],
        ["Claim Recovery Canary Upload"],
        ["List Recovery Canary Comments"],
        ["List Recovery Canary Comments"],
        ["Wait Recovery Canary Join"],
    ],
    "Recovery canary states do not route to the exact initialize/upload/associate/verify/join paths.",
)
require(
    ordered_outputs("Recovery Canary Upload Claimed") == [
        ["Prepare Recovery Canary Binary"],
        ["Wait Recovery Canary Join"],
    ],
    "A losing recovery canary claim can reach the upload path.",
)

for source, target in (
    ("Confirm Probe Cleanup", "Get Recovery Saved View"),
    ("Get Recovery Saved View", "Require Recovery Saved View"),
    ("Require Recovery Saved View", "List Recovery Canary Rows"),
    ("List Recovery Canary Rows", "Inspect Recovery Canary Row"),
    ("Initialize Recovery Canary Row", "List Recovery Canary Rows"),
    ("Wait Recovery Canary Join", "Increment Recovery Canary Poll"),
    ("Increment Recovery Canary Poll", "List Recovery Canary Rows"),
    ("Require Recovery Canary Claim", "Recovery Canary Upload Claimed"),
    ("Prepare Recovery Canary Binary", "Upload Recovery Canary"),
    ("Upload Recovery Canary", "Require Recovery Canary Upload"),
    ("Require Recovery Canary Upload", "Record Uploaded Recovery Canary"),
    ("Record Uploaded Recovery Canary", "Require Uploaded Recovery Canary"),
    ("Require Uploaded Recovery Canary", "List Recovery Canary Comments"),
    ("Create Recovery Canary Comment", "List Recovery Canary Comments"),
    ("Record Ready Recovery Canary", "Require Ready Recovery Canary"),
    ("Require Ready Recovery Canary", "Download Recovery Canary"),
    ("Download Recovery Canary", "Require Recovery Canary Download"),
    ("Require Recovery Canary Download", "Prepare Acceptance Response"),
):
    require(target in outgoing(source), f"Recovery canary graph must route {source} to {target}.")
notes = by_name.get("Acceptance Setup", {}).get("parameters", {}).get("content", "")
for label in ("automation-data/issue334_acceptance/migrator", "NocoDB Operator API", "NocoDB Acceptance Header"):
    require(label in notes, f"The acceptance setup note omits {label}.")
require("all six Postgres nodes" in notes, "The acceptance setup must bind the migrator credential to all six Postgres nodes.")
wait = by_name.get("Wait Recovery Canary Join", {})
require(
    wait.get("type") == "n8n-nodes-base.wait"
    and wait.get("parameters") == {"amount": 5, "unit": "seconds"},
    "Recovery canary join polling must use exact five-second waits.",
)
increment_code = by_name.get("Increment Recovery Canary Poll", {}).get("parameters", {}).get("jsCode", "")
inspect_code = by_name.get("Inspect Recovery Canary Row", {}).get("parameters", {}).get("jsCode", "")
require(
    "canaryPollCount > 12" in increment_code and "canaryPollCount >= 12" in inspect_code,
    "Recovery canary join polling must stop after exactly twelve waits.",
)
PY

node - "$acceptance_workflow" <<'JS'
const fs = require('fs');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const byName = Object.fromEntries(workflow.nodes.map((node) => [node.name, node]));
const execute = (name, input, lookup = {}, itemInputs = [input], binary = {}) => {
  const code = byName[name]?.parameters?.jsCode;
  if (!code) throw new Error(`missing Code node ${name}`);
  return new Function('$json', '$input', '$', '$binary', code)(
    input,
    { all: () => itemInputs.map((json) => ({ json })) },
    (nodeName) => ({
      isExecuted: Object.prototype.hasOwnProperty.call(lookup, nodeName),
      first: () => ({ json: lookup[nodeName] || input }),
      last: () => ({ json: lookup[nodeName] || input }),
    }),
    binary,
  );
};
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const executeAsync = async (name, input, lookup = {}, itemInputs = [input], binary = {}, helpers = {}) => {
  const code = byName[name]?.parameters?.jsCode;
  if (!code) throw new Error(`missing Code node ${name}`);
  return await new AsyncFunction('$json', '$input', '$', '$binary', 'helpers', code)(
    input,
    { all: () => itemInputs.map((json) => ({ json })) },
    (nodeName) => ({
      isExecuted: Object.prototype.hasOwnProperty.call(lookup, nodeName),
      first: () => ({ json: lookup[nodeName] || input }),
      last: () => ({ json: lookup[nodeName] || input }),
    }),
    binary,
    helpers,
  );
};

(async () => {

let reservedRunIdRejected = false;
try {
  execute('Normalize Acceptance Request', { body: { operation: 'probe', runId: 'recovery-canary-v1' } });
} catch (error) { reservedRunIdRejected = /reserved_run_id/.test(error.message); }
if (!reservedRunIdRejected) throw new Error('the persistent recovery canary row can be targeted by an incoming cleanup/probe run ID');

const reflection = {
  operation: 'probe',
  runId: 'run-one',
  readerSourceId: 'source-reader',
  operatorSourceId: 'source-operator',
};
const readerSourceMetadata = execute(
  'Capture Acceptance Reader Source',
  { id: 'source-reader', base_id: 'base-1', alias: 'Read Model', config: { searchPath: ['read_model'] } },
  { 'Keep Acceptance Sources': { ...reflection, baseId: 'base-1' } },
)[0].json;
const reflectedContext = execute(
  'Capture Acceptance Operator Source',
  { id: 'source-operator', base_id: 'base-1', alias: 'Operator', config: { searchPath: ['operator'] } },
  { 'Capture Acceptance Reader Source': readerSourceMetadata },
)[0].json;
if (reflectedContext.readerSchema !== 'read_model' || reflectedContext.operatorSchema !== 'operator') {
  throw new Error('source GET metadata did not derive the exact reflected schemas');
}
for (const [label, node, source, lookup, pattern] of [
  [
    'public reader schema',
    'Capture Acceptance Reader Source',
    { id: 'source-reader', base_id: 'base-1', alias: 'Read Model', config: { searchPath: ['public'] } },
    { 'Keep Acceptance Sources': { ...reflection, baseId: 'base-1' } },
    /acceptance_reader_source_invalid/,
  ],
  [
    'missing reader schema',
    'Capture Acceptance Reader Source',
    { id: 'source-reader', base_id: 'base-1', alias: 'Read Model', config: {} },
    { 'Keep Acceptance Sources': { ...reflection, baseId: 'base-1' } },
    /acceptance_reader_source_invalid/,
  ],
  [
    'wrong operator schema',
    'Capture Acceptance Operator Source',
    { id: 'source-operator', base_id: 'base-1', alias: 'Operator', config: { searchPath: ['public'] } },
    { 'Capture Acceptance Reader Source': readerSourceMetadata },
    /acceptance_operator_source_invalid/,
  ],
]) {
  let rejected = false;
  try { execute(node, source, lookup); } catch (error) { rejected = pattern.test(error.message); }
  if (!rejected) throw new Error(`${label} was accepted`);
}
const exactTables = [
  { id: 'table-facts', title: 'acceptance_facts', table_name: 'acceptance_facts', source_id: 'source-reader', schema: null },
  { id: 'table-decisions', title: 'acceptance_decision', table_name: 'acceptance_decision', source_id: 'source-operator', schema: null },
];
const completePage = { totalRows: 2, page: 1, pageSize: 25, isFirstPage: true, isLastPage: true };
const resolved = execute('Resolve Acceptance Tables', { ...reflectedContext, tables: exactTables, pageInfo: completePage })[0].json;
if (
  resolved.factsTableId !== 'table-facts'
  || resolved.decisionTableId !== 'table-decisions'
  || JSON.stringify(resolved.reflectedSchemas) !== JSON.stringify(['operator', 'read_model'])
  || resolved.reflectedTables.find((table) => table.id === 'table-facts')?.schema !== 'read_model'
  || resolved.reflectedTables.find((table) => table.id === 'table-decisions')?.schema !== 'operator'
) throw new Error('exact reflected schemas and tables were not derived');
const canaryContext = {
  ...resolved,
  inserted: true,
  read: true,
  readerRead: true,
  decisionUpdated: true,
  protectedUpdateDenied: true,
  protectedUpdateStatus: 400,
  protectedUpdateEvidence: 'postgresql_42501',
  readerInsertDenied: true,
  readerInsertStatus: 403,
  readerInsertEvidence: 'nocodb_readonly_source',
};
const savedView = execute(
  'Require Recovery Saved View',
  {
    list: [{ id: 'view-facts', fk_model_id: 'table-facts', title: 'acceptance_facts', type: 3, uuid: null }],
  },
  { 'Confirm Probe Cleanup': { list: [] }, 'Evaluate Reader Insert Denial': canaryContext },
)[0].json;
if (JSON.stringify(savedView.savedView) !== JSON.stringify({ id: 'view-facts', tableId: 'table-facts', title: 'acceptance_facts', type: 3 })) {
  throw new Error('recovery canary did not preserve exact observed default-view identity');
}
for (const body of [
  { list: [] },
  { list: [{ id: 'view-facts', fk_model_id: 'table-decisions', title: 'acceptance_facts', type: 3, uuid: null }] },
  { list: [{ id: 'view-facts', fk_model_id: 'table-facts', title: 'acceptance_facts', type: 2, uuid: null }] },
  { list: [{ id: 'view-facts', fk_model_id: 'table-facts', title: 'acceptance_facts', type: 3, uuid: 'public' }] },
  { list: [
    { id: 'view-facts', fk_model_id: 'table-facts', title: 'acceptance_facts', type: 3, uuid: null },
    { id: 'view-extra', fk_model_id: 'table-facts', title: 'extra', type: 3, uuid: null },
  ] },
]) {
  let rejected = false;
  try { execute('Require Recovery Saved View', body, { 'Confirm Probe Cleanup': { list: [] }, 'Evaluate Reader Insert Denial': canaryContext }); }
  catch (error) { rejected = /recovery_saved_view_invalid/.test(error.message); }
  if (!rejected) throw new Error('invalid or incomplete saved-view identity was accepted');
}

const emptyCanary = execute(
  'Inspect Recovery Canary Row',
  { list: [], pageInfo: { totalRows: 0 } },
  { 'Require Recovery Saved View': savedView },
)[0].json;
if (emptyCanary.canaryAction !== 'create' || emptyCanary.canaryRow !== null) throw new Error('missing recovery canary row did not select create');
const pendingDecision = { kind: 'nocodb-attachment-recovery-canary', version: 1, state: 'pending' };
const pendingCanary = execute(
  'Inspect Recovery Canary Row',
  { list: [{ id: 41, run_id: 'recovery-canary-v1', decision: JSON.stringify(pendingDecision) }], pageInfo: { totalRows: 1 } },
  { 'Require Recovery Saved View': savedView },
)[0].json;
if (pendingCanary.canaryAction !== 'upload' || pendingCanary.rowId !== 41) throw new Error('pending recovery canary did not select one upload');
const observedUploading = execute(
  'Inspect Recovery Canary Row',
  { list: [{ id: 41, run_id: 'recovery-canary-v1', decision: JSON.stringify({ ...pendingDecision, state: 'uploading' }) }], pageInfo: { totalRows: 1 } },
  { 'Require Recovery Saved View': savedView },
)[0].json;
if (observedUploading.canaryAction !== 'wait' || observedUploading.canaryPollCount !== 0) {
  throw new Error('an in-progress recovery canary did not join with a bounded poll');
}
let missingDuringJoinRejected = false;
try {
  execute(
    'Inspect Recovery Canary Row',
    { list: [], pageInfo: { totalRows: 0 } },
    { 'Require Recovery Saved View': savedView, 'Increment Recovery Canary Poll': { canaryPollCount: 1 } },
  );
} catch (error) { missingDuringJoinRejected = /recovery_canary_row_invalid/.test(error.message); }
if (!missingDuringJoinRejected) throw new Error('a canary row that disappeared during join was reinitialized');
const losingClaim = execute(
  'Require Recovery Canary Claim',
  {},
  { 'Inspect Recovery Canary Row': pendingCanary },
)[0].json;
if (losingClaim.claimWon !== false || losingClaim.canaryAction !== 'wait') {
  throw new Error('a losing upload claim did not join without uploading');
}
const winningClaim = execute(
  'Require Recovery Canary Claim',
  { rowId: 41 },
  { 'Inspect Recovery Canary Row': pendingCanary },
)[0].json;
if (winningClaim.claimWon !== true || winningClaim.canaryAction !== 'upload') {
  throw new Error('the exact winning upload claim was not selected');
}
let ambiguousUploadRejected = false;
try {
  execute(
    'Inspect Recovery Canary Row',
    { list: [{ id: 41, run_id: 'recovery-canary-v1', decision: JSON.stringify({ ...pendingDecision, state: 'uploading' }) }], pageInfo: { totalRows: 1 } },
    { 'Require Recovery Saved View': savedView, 'Increment Recovery Canary Poll': { canaryPollCount: 12 } },
  );
} catch (error) { ambiguousUploadRejected = /attachment_upload_ambiguous/.test(error.message); }
if (!ambiguousUploadRejected) throw new Error('stale uploading state exceeded the join bound without failing');
for (const rows of [
  [{ id: 41, run_id: 'recovery-canary-v1', decision: '{bad-json' }],
  [{ id: 41, run_id: 'recovery-canary-v1', decision: JSON.stringify(pendingDecision) }, { id: 42, run_id: 'recovery-canary-v1', decision: JSON.stringify(pendingDecision) }],
]) {
  let rejected = false;
  try { execute('Inspect Recovery Canary Row', { list: rows, pageInfo: { totalRows: rows.length } }, { 'Require Recovery Saved View': savedView }); }
  catch (error) { rejected = /recovery_canary_row_invalid/.test(error.message); }
  if (!rejected) throw new Error('malformed or duplicate recovery canary rows were accepted');
}

let preparedBytes = null;
const preparedBinary = (await executeAsync(
  'Prepare Recovery Canary Binary',
  pendingCanary,
  {},
  [pendingCanary],
  {},
  {
    prepareBinaryData: async (buffer, fileName, mimeType) => {
      preparedBytes = Buffer.from(buffer);
      return { data: 'filesystem-v2', id: 'filesystem-v2:prepared-canary', fileName, mimeType };
    },
  },
))[0];
if (
  preparedBinary.binary?.canaryFile?.data !== 'filesystem-v2'
  || preparedBinary.binary?.canaryFile?.id !== 'filesystem-v2:prepared-canary'
  || preparedBinary.binary?.canaryFile?.fileName !== 'issue334-recovery-canary-v1.txt'
  || preparedBinary.binary?.canaryFile?.mimeType !== 'text/plain'
  || preparedBytes?.toString('base64') !== 'bm9jb2RiLWlzc3VlMzM0LWF0dGFjaG1lbnQtY2FuYXJ5LXYxCg=='
) throw new Error('recovery canary binary bytes or metadata are not exact');
const uploaded = execute(
  'Require Recovery Canary Upload',
  [{
    path: 'download/issue334_acceptance/recovery-canary-v1/issue334-recovery-canary-v1_Ab-9_.txt',
    title: 'issue334-recovery-canary-v1.txt',
    mimetype: 'text/plain',
    size: 37,
    signedPath: 'transient-must-not-persist',
  }],
  { 'Prepare Recovery Canary Binary': pendingCanary },
)[0].json;
if (
  uploaded.canaryDecision.state !== 'uploaded'
  || uploaded.canaryDecision.attachment.sha256 !== '09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3'
  || JSON.stringify(uploaded.canaryDecision).includes('signedPath')
) throw new Error('uploaded recovery canary metadata was not bounded and persisted exactly');
for (const attachment of [
  { path: 'download/other/file.txt', title: 'issue334-recovery-canary-v1.txt', mimetype: 'text/plain', size: 37 },
  { path: 'download/issue334_acceptance/recovery-canary-v1/issue334-recovery-canary-v1_Ab-9_.txt', title: 'wrong.txt', mimetype: 'text/plain', size: 37 },
  { path: 'download/issue334_acceptance/recovery-canary-v1/issue334-recovery-canary-v1_Ab-9_.txt', title: 'issue334-recovery-canary-v1.txt', mimetype: 'text/plain', size: 38 },
]) {
  let rejected = false;
  try { execute('Require Recovery Canary Upload', [attachment], { 'Prepare Recovery Canary Binary': pendingCanary }); }
  catch (error) { rejected = /recovery_canary_upload_invalid/.test(error.message); }
  if (!rejected) throw new Error('untrusted recovery canary upload metadata was accepted');
}

const canonicalComment = {
  id: 'comment-canary',
  base_id: 'base-1',
  source_id: 'source-operator',
  fk_model_id: 'table-decisions',
  row_id: '41',
  comment: 'issue334-recovery-canary-v1',
  attachments: [{
    id: 'attachment-canary',
    path: uploaded.canaryDecision.attachment.path,
    title: 'issue334-recovery-canary-v1.txt',
    mimetype: 'text/plain',
    size: 37,
  }],
};
const missingComment = execute(
  'Inspect Recovery Canary Comments',
  { list: [] },
  { 'Require Uploaded Recovery Canary': uploaded },
)[0].json;
if (missingComment.createComment !== true) throw new Error('uploaded canary without a comment did not select association');
const associated = execute(
  'Inspect Recovery Canary Comments',
  { list: [canonicalComment] },
  { 'Require Uploaded Recovery Canary': uploaded },
)[0].json;
if (
  associated.createComment !== false
  || associated.canaryDecision.state !== 'ready'
  || associated.canaryDecision.commentId !== 'comment-canary'
  || associated.canaryDecision.attachment.id !== 'attachment-canary'
) throw new Error('exact durable comment association did not produce ready canary metadata');
for (const comments of [
  [canonicalComment, { ...canonicalComment, id: 'comment-duplicate' }],
  [{ ...canonicalComment, row_id: '42' }],
  [{ ...canonicalComment, attachments: [{ ...canonicalComment.attachments[0], path: 'download/other/file.txt' }] }],
]) {
  let rejected = false;
  try { execute('Inspect Recovery Canary Comments', { list: comments }, { 'Require Uploaded Recovery Canary': uploaded }); }
  catch (error) { rejected = /recovery_canary_comment_invalid/.test(error.message); }
  if (!rejected) throw new Error('duplicate or mismatched recovery canary comment association was accepted');
}
const readyCanary = execute(
  'Inspect Recovery Canary Row',
  { list: [{ id: 41, run_id: 'recovery-canary-v1', decision: JSON.stringify(associated.canaryDecision) }], pageInfo: { totalRows: 1 } },
  { 'Require Recovery Saved View': savedView },
)[0].json;
if (readyCanary.canaryAction !== 'verify') throw new Error('ready recovery canary rerun selected a write path');
const losingExecutionActions = [emptyCanary.canaryAction, losingClaim.canaryAction, observedUploading.canaryAction, readyCanary.canaryAction];
if (losingExecutionActions.includes('upload') || losingExecutionActions.at(-1) !== 'verify') {
  throw new Error('the losing concurrent execution uploaded instead of joining the ready canary');
}
let downloadHelperCalled = false;
const verifiedDownload = (await executeAsync(
  'Require Recovery Canary Download',
  {},
  { 'Inspect Recovery Canary Comments': associated },
  [{}],
  { canaryDownload: { data: 'filesystem-v2', id: 'filesystem-v2:downloaded-canary', fileSize: '37' } },
  { getBinaryDataBuffer: async (index, property) => {
    if (index !== 0 || property !== 'canaryDownload') throw new Error('wrong binary helper arguments');
    downloadHelperCalled = true;
    return Buffer.from('bm9jb2RiLWlzc3VlMzM0LWF0dGFjaG1lbnQtY2FuYXJ5LXYxCg==', 'base64');
  } },
))[0].json;
if (!downloadHelperCalled || verifiedDownload.attachmentCanary?.state !== 'ready' || verifiedDownload.attachmentCanary?.sha256 !== '09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3') {
  throw new Error('exact downloaded canary bytes were not retained as bounded evidence');
}
let wrongDownloadRejected = false;
try {
  await executeAsync(
    'Require Recovery Canary Download',
    {},
    { 'Inspect Recovery Canary Comments': associated },
    [{}],
    { canaryDownload: { data: 'filesystem-v2', id: 'filesystem-v2:wrong-canary' } },
    { getBinaryDataBuffer: async () => Buffer.from('wrong\n') },
  );
} catch (error) { wrongDownloadRejected = /recovery_canary_download_invalid/.test(error.message); }
if (!wrongDownloadRejected) throw new Error('wrong recovery canary download bytes were accepted');
const privateBase = execute(
  'Require Acceptance Base Private',
  { uuid: null, roles: null, fk_custom_url_id: null },
  { 'Resolve Acceptance Tables': resolved },
)[0].json;
if (privateBase.publicSharing.basePublicShareUuid !== null) throw new Error('null base share UUID was not retained as evidence');
for (const body of [{ roles: null }, { uuid: 'public-base-uuid', roles: 'viewer' }]) {
  let rejected = false;
  try { execute('Require Acceptance Base Private', body, { 'Resolve Acceptance Tables': resolved }); }
  catch (error) { rejected = /acceptance_base_share_invalid/.test(error.message); }
  if (!rejected) throw new Error('missing or non-null base share UUID was accepted');
}
const noReaderShares = execute(
  'Require Reader Shares Empty', { list: [] }, { 'Require Acceptance Base Private': privateBase },
)[0].json;
const noOperatorShares = execute(
  'Require Operator Shares Empty', { list: [] }, { 'Require Reader Shares Empty': noReaderShares },
)[0].json;
if (
  noOperatorShares.publicSharing.views.length !== 2
  || noOperatorShares.publicSharing.views.some((view) => view.publicShareUuid !== null)
) throw new Error('empty exact table share collections were not retained as bounded evidence');
for (const [name, lookup] of [
  ['Require Reader Shares Empty', { 'Require Acceptance Base Private': privateBase }],
  ['Require Operator Shares Empty', { 'Require Reader Shares Empty': noReaderShares }],
]) {
  for (const body of [{ list: [{ id: 'view-one', uuid: 'shared-view' }] }, { unexpected: [] }]) {
    let rejected = false;
    try { execute(name, body, lookup); } catch (error) { rejected = /acceptance_table_share_invalid/.test(error.message); }
    if (!rejected) throw new Error(`${name} accepted a public or malformed share collection`);
  }
}
let untrustedSchemaRejected = false;
try {
  execute('Resolve Acceptance Tables', { ...reflectedContext, readerSchema: 'public', tables: exactTables, pageInfo: completePage });
} catch (error) { untrustedSchemaRejected = /acceptance_reflection_invalid/.test(error.message); }
if (!untrustedSchemaRejected) throw new Error('Resolve Acceptance Tables reported a hard-coded schema instead of validating source metadata');
for (const [label, mutate] of [
  ['public table schema', (input) => { input.tables[0].schema = 'public'; }],
  ['missing table schema', (input) => { delete input.tables[0].schema; }],
  ['cross-source table identity', (input) => {
    [input.tables[0].source_id, input.tables[1].source_id] = [input.tables[1].source_id, input.tables[0].source_id];
  }],
  ['unreturned later-page table', (input) => { input.pageInfo.totalRows = 3; }],
  ['nonterminal table page', (input) => { input.pageInfo.isLastPage = false; }],
]) {
  const input = {
    ...reflectedContext,
    tables: exactTables.map((table) => ({ ...table })),
    pageInfo: { ...completePage },
  };
  mutate(input);
  let rejected = false;
  try { execute('Resolve Acceptance Tables', input); }
  catch (error) { rejected = /acceptance_reflection_invalid/.test(error.message); }
  if (!rejected) throw new Error(`${label} was accepted as an exact reflected surface`);
}
let unexpectedTableRejected = false;
try {
  execute('Resolve Acceptance Tables', {
    ...reflection,
    readerSchema: 'read_model',
    operatorSchema: 'operator',
    tables: [...exactTables, { id: 'extra', title: 'other', table_name: 'other', source_id: 'source-reader', schema: 'read_model' }],
    pageInfo: { ...completePage, totalRows: 3 },
  });
} catch (error) { unexpectedTableRejected = /acceptance_reflection_invalid/.test(error.message); }
if (!unexpectedTableRejected) throw new Error('unexpected reflected table was accepted');

const readContext = { ...resolved, factsTableId: 'table-facts' };
const readerRead = execute('Require Reader Facts Read', {
  statusCode: 200,
  body: { list: [{ id: 1, fact: 'fixture' }], pageInfo: { totalRows: 1 } },
  context: readContext,
})[0].json;
if (readerRead.readerRead !== true || readerRead.factsTableId !== 'table-facts') {
  throw new Error('successful acceptance reader GET was not verified');
}
let malformedReadRejected = false;
try { execute('Require Reader Facts Read', { statusCode: 200, body: {}, context: readContext }); }
catch (error) { malformedReadRejected = /reader_read_invalid/.test(error.message); }
if (!malformedReadRejected) throw new Error('malformed reader GET was accepted');

const protectedContext = { runId: 'run-one', recordId: 7 };
const protectedDenial = execute('Capture Protected Update Denial', {
  statusCode: 400,
  body: {
    error: 'ERR_DATABASE_OP_FAILED',
    code: '42501',
    message: "The database user does not have permission to access 'acceptance_decision'.",
  },
  context: protectedContext,
})[0].json;
if (protectedDenial.protectedUpdateDenied !== true) throw new Error('PostgreSQL 42501 denial was not accepted');
for (const response of [
  { statusCode: 500, body: { message: 'network failure' }, context: protectedContext },
  { statusCode: 400, body: { error: 'ERR_DATABASE_OP_FAILED', code: '23505', message: 'duplicate' }, context: protectedContext },
]) {
  let rejected = false;
  try { execute('Capture Protected Update Denial', response); } catch (error) { rejected = /protected_update_denial_invalid/.test(error.message); }
  if (!rejected) throw new Error('non-authorization protected-update error was accepted');
}

const negativeOne = execute('Prepare Reader Negative Probe', { ...readerRead, runId: 'run-one' })[0].json;
const negativeTwo = execute('Prepare Reader Negative Probe', { ...readerRead, runId: 'run-two' })[0].json;
if (
  negativeOne.readerProbeId === negativeTwo.readerProbeId
  || negativeOne.readerProbeFact !== 'forbidden:run-one'
  || negativeTwo.readerProbeFact !== 'forbidden:run-two'
) throw new Error('reader negative probe is not unique and run-bound');
const readerDenial = execute('Evaluate Reader Insert Denial', {
  statusCode: 403,
  body: { error: 'ERR_FORBIDDEN', message: "Forbidden - Source 'Read Model' is read-only" },
  context: negativeOne,
})[0].json;
if (readerDenial.readerInsertDenied !== true || readerDenial.unexpectedlyPermitted !== false) {
  throw new Error('exact read-only source denial was not accepted');
}
const readerUnexpected = execute('Evaluate Reader Insert Denial', {
  statusCode: 200,
  body: { id: negativeOne.readerProbeId },
  context: negativeOne,
})[0].json;
if (readerUnexpected.unexpectedlyPermitted !== true) throw new Error('unexpected reader insert did not route to cleanup');
let duplicateNotDenial = false;
try {
  execute('Evaluate Reader Insert Denial', {
    statusCode: 400,
    body: { error: 'ERR_DUPLICATE_RECORD', message: 'duplicate key' },
    context: negativeOne,
  });
} catch (error) { duplicateNotDenial = /reader_insert_denial_invalid/.test(error.message); }
if (!duplicateNotDenial) throw new Error('duplicate-key residue created a false reader-denial pass');

const cleanupContext = { operation: 'cleanup', runId: 'run-one', cleanupPageCount: 0, removedCount: 0 };
const cleanupPage = execute('Prepare Cleanup Page', {
  ...cleanupContext,
  rows: [{ id: 1, run_id: 'run-one' }, { id: 2, run_id: 'run-one' }],
})[0].json;
if (!cleanupPage.hasRows || cleanupPage.cleanupPageCount !== 1 || cleanupPage.deleteRows.length !== 2) {
  throw new Error('cleanup page was not bounded and prepared');
}
const cleanupDone = execute('Prepare Cleanup Page', { ...cleanupPage, rows: [] })[0].json;
if (cleanupDone.hasRows !== false || cleanupDone.removedCount !== 2) throw new Error('cleanup did not retain its exact removed count');
let cleanupBoundRejected = false;
try {
  execute('Prepare Cleanup Page', {
    ...cleanupContext,
    cleanupPageCount: 10,
    rows: [{ id: 3, run_id: 'run-one' }],
  });
} catch (error) { cleanupBoundRejected = /cleanup_page_bound_exceeded/.test(error.message); }
if (!cleanupBoundRejected) throw new Error('cleanup accepted rows beyond its page bound');
const absent = execute('Require Cleanup Absent', {
  statusCode: 200,
  body: { list: [], pageInfo: { totalRows: 0 } },
  context: cleanupDone,
})[0].json;
if (absent.ok !== true || absent.removedCount !== 2) throw new Error('cleanup absence was not verified');

const acceptanceResponse = execute(
  'Prepare Acceptance Response',
  { list: [] },
  {
    'Evaluate Reader Insert Denial': {
      ...noOperatorShares,
      inserted: true,
      read: true,
      readerRead: true,
      decisionUpdated: true,
      removed: true,
      protectedUpdateDenied: true,
      protectedUpdateStatus: 400,
      protectedUpdateEvidence: 'postgresql_42501',
      readerInsertDenied: true,
      readerInsertStatus: 403,
      readerInsertEvidence: 'nocodb_readonly_source',
    },
    'Require Recovery Canary Download': { ...verifiedDownload, ...noOperatorShares },
  },
)[0].json;
if (
  acceptanceResponse.credentialProof?.throughN8n !== true
  || acceptanceResponse.credentialProof?.credentialName !== 'NocoDB Operator API'
  || acceptanceResponse.publicSharing?.basePublicShareUuid !== null
  || acceptanceResponse.publicSharing?.views?.length !== 2
  || acceptanceResponse.attachmentCanary?.state !== 'ready'
  || acceptanceResponse.attachmentCanary?.savedViewId !== 'view-facts'
  || acceptanceResponse.attachmentCanary?.commentId !== 'comment-canary'
  || acceptanceResponse.attachmentCanary?.attachmentId !== 'attachment-canary'
) throw new Error('successful HTTP probe omitted credential-path or public-sharing evidence');
for (const forbidden of ['password', 'token', 'header', 'credentialId', 'created_by', 'signedPath', 'signedUrl', 'bm9jb2ri']) {
  if (JSON.stringify(acceptanceResponse).toLowerCase().includes(forbidden.toLowerCase())) {
    throw new Error(`acceptance response exposed secret-bearing field ${forbidden}`);
  }
}
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
JS

mapfile -t packaged_workflows < <(
  yq -r '.configMapGenerator[] | select(.name == "n8n-workflow-templates") | .files[]' \
    "$kustomization" | LC_ALL=C sort
)
expected_workflows=(
  'automation-data-provisioner.json=workflows/automation-data-provisioner.json'
  'automation-data-recovery-canary.json=workflows/automation-data-recovery-canary.json'
  'nocodb-acceptance-domain.json=workflows/nocodb-acceptance-domain.json'
  'nocodb-source-provisioner.json=workflows/nocodb-source-provisioner.json'
  'platform-canary.json=workflows/platform-canary.json'
)
[[ "${packaged_workflows[*]}" == "${expected_workflows[*]}" ]] || {
  echo 'The n8n workflow ConfigMap must package the complete exact workflow template set.' >&2
  exit 1
}

echo 'NocoDB workflow contracts passed.'
