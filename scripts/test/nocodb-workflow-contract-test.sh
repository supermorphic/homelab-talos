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
    require(
        url.startswith(host + "/") or url.startswith("={{ '" + host + "/"),
        f"NocoDB URL does not use the fixed service host: {url}",
    )
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
    (nodeName) => ({ first: () => lookup[nodeName] === null ? undefined : ({ json: lookup[nodeName] || input }) }),
  );
};

const operatorRotateRequest = execute('Normalize Source Request', {
  body: { domain: 'domain_one', operation: 'rotate', accessKind: 'operator' },
})[0].json;
if (operatorRotateRequest.requestedAccessKind !== 'operator' || operatorRotateRequest.accessKind !== 'operator') {
  throw new Error('Normalize Source Request did not preserve the explicit rotation target separately');
}
const readerRotateRequest = execute('Normalize Source Request', {
  body: { domain: 'domain_one', operation: 'rotate', accessKind: 'reader' },
})[0].json;
const readerRotationOperatorGate = execute(
  'Start Operator',
  { result: { domain: 'domain_one', accessKind: 'reader', state: 'ready', baseId: 'base-1' } },
  {
    'Normalize Source Request': readerRotateRequest,
    'Keep Access Plan': { plan: { operatorRequested: true, operatorEligible: true } },
    'Start Reader': { workspaceId: 'workspace-1' },
  },
)[0].json;
if (readerRotationOperatorGate.operatorRequired !== true || readerRotationOperatorGate.reader.accessKind !== 'reader') {
  throw new Error('reader-only rotation did not route the ready operator through current validation');
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
for (const [node, errorGate] of [
  ['Prepare Reader Rotation', 'Reader Error Rotation'],
  ['Prepare Operator Rotation', 'Operator Error Rotation'],
]) {
  const cryptoInput = {
    domain: 'domain_one', operation: 'rotate', requestedAccessKind: node.includes('Reader') ? 'reader' : 'operator',
    accessKind: node.includes('Reader') ? 'reader' : 'operator', sourceId: 'source-1', integrationId: 'integration-1',
    generatedValue: 'a'.repeat(48), postgresqlValidation: { valid: true },
  };
  const prepared = execute(node, cryptoInput, { [errorGate]: null })[0].json;
  if (JSON.stringify(prepared) !== JSON.stringify(cryptoInput)) {
    throw new Error(`${node} did not preserve the complete Crypto-node input when the normal IF output was empty`);
  }
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
import copy
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
    "The acceptance workflow must disable all execution persistence.",
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
for marker in ("structure", "grants", "probe", "cleanup", "feedback", "recovery-canary-v1", "recovery-canary-v2"):
    require(marker in normalize, f"Acceptance request validation omits {marker}.")
for forbidden in ("domain", "sql"):
    require(not re.search(rf"['\"]{forbidden}['\"]", normalize), f"Acceptance accepts forbidden field {forbidden}.")

structure_sql = by_name.get("Create Acceptance Structure", {}).get("parameters", {}).get("query", "")
for marker in (
    "CREATE TABLE IF NOT EXISTS app.acceptance_fact (",
    "run_id text,",
    "artifact_id text,",
    "artifact_uri text,",
    "artifact_media_type text,",
    "artifact_size_bytes bigint,",
    "artifact_sha256 text",
    "CREATE OR REPLACE VIEW read_model.acceptance_facts AS",
    "SELECT id, fact, run_id, artifact_id, artifact_uri, artifact_media_type,",
    "-334, 'recovery-canary-v2', 'artifact-available'",
    "'issue334-artifact-v1', 'https://artifacts.example.invalid/issue334/artifact-v1'",
    "'text/plain', 37,",
    "'09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3'",
    "VALUES ('recovery-canary-v2', 'retain')",
    "ON CONFLICT DO NOTHING;",
    "RAISE EXCEPTION 'recovery_canary_incompatible';",
    'SELECT current_user AS "credentialRole";',
):
    require(marker in structure_sql, f"Acceptance structure SQL omits {marker}")
require("UPDATE operator.acceptance_decision" not in structure_sql, "Structure must not overwrite an old native canary.")

grant_sql = by_name.get("Grant Acceptance Access", {}).get("parameters", {}).get("query", "")
for marker in (
    "issue334_acceptance_operator",
    "issue334_acceptance_runtime",
    "GRANT USAGE ON SCHEMA read_model, operator TO issue334_acceptance_runtime;",
    "GRANT SELECT ON TABLE read_model.acceptance_facts TO issue334_acceptance_runtime;",
    "GRANT SELECT ON TABLE operator.acceptance_decision TO issue334_acceptance_runtime;",
    "GRANT UPDATE (decision) ON TABLE operator.acceptance_decision TO issue334_acceptance_operator;",
):
    require(marker in grant_sql, f"Acceptance grant SQL omits {marker}")
require(
    "GRANT" not in grant_sql.split("issue334_acceptance_runtime;")[-1]
    and "REVOKE" not in grant_sql.upper(),
    "Acceptance grants must preserve the runtime role's existing app rights.",
)

migrator_names = {
    "Create Acceptance Structure",
    "Grant Acceptance Access",
    "Clear Reader Negative Residue",
    "Cleanup Unexpected Reader Insert",
    "Clear Feedback Residue",
    "Cleanup Feedback Fact",
}
runtime_names = {
    "Publish Initial Feedback Fact",
    "Consume Feedback Before Refresh",
    "Refresh Feedback Fact",
    "Consume Feedback After Refresh",
}
postgres_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.postgres"]
require({node["name"] for node in postgres_nodes} == migrator_names | runtime_names, "Acceptance PostgreSQL node set is not exact.")
for node in postgres_nodes:
    query = node.get("parameters", {}).get("query", "")
    require("{{$json" not in query and "EXECUTE " not in query.upper(), f"{node['name']} contains dynamic SQL.")
    require(not node.get("credentials"), f"{node['name']} embeds a credential ID.")
    if node["name"] in migrator_names:
        require(
            re.findall(r"SET LOCAL ROLE ([a-z0-9_]+);", query) == ["issue334_acceptance_owner"],
            f"{node['name']} must use only the reviewed owner role.",
        )
    else:
        require("SET ROLE" not in query.upper() and "current_user" in query, f"{node['name']} must prove the runtime login directly.")
    if node["name"] in {"Clear Feedback Residue", "Cleanup Feedback Fact"} | runtime_names:
        require(node.get("alwaysOutputData") is True, f"{node['name']} must fail closed through a zero-row result.")

clear_feedback = by_name.get("Clear Feedback Residue", {}).get("parameters", {})
require(
    "WHERE id = $3 AND run_id = $1" in clear_feedback.get("query", "")
    and "WHERE run_id = $1 AND run_id <>" not in clear_feedback.get("query", "")
    and clear_feedback.get("options", {}).get("queryReplacement")
    == "={{ [$json.runId, $json.factId, $json.residueDecisionId] }}",
    "Pre-feedback decision cleanup must target at most one independently observed exact row.",
)
cleanup_fact = by_name.get("Cleanup Feedback Fact", {}).get("parameters", {})
require(
    "WHERE id = $1 AND run_id = $2 AND id <> -334" in cleanup_fact.get("query", "")
    and cleanup_fact.get("options", {}).get("queryReplacement") == "={{ [$json.factId, $json.runId] }}",
    "Feedback fact cleanup must bind the exact non-reserved fact identity.",
)

notes = by_name.get("Acceptance Setup", {}).get("parameters", {}).get("content", "")
for label in (
    "automation-data/issue334_acceptance/migrator",
    "automation-data/issue334_acceptance/runtime",
    "NocoDB Operator API",
    "NocoDB Acceptance Header",
):
    require(label in notes, f"The acceptance setup note omits {label}.")
for name in sorted(migrator_names | runtime_names):
    require(name in notes, f"The acceptance setup note omits the binding for {name}.")

http_nodes = [node for node in nodes if node.get("type") == "n8n-nodes-base.httpRequest"]
require(http_nodes, "The acceptance workflow must use the NocoDB Operator API.")
expected_http = {
    "List Acceptance Bases": ("GET", "http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/bases"),
    "List Acceptance Sources": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/bases/' + $json.baseId + '/sources' }}"),
    "Get Acceptance Reader Source": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/bases/' + $json.baseId + '/sources/' + $json.readerSourceId }}"),
    "Get Acceptance Operator Source": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/bases/' + $json.baseId + '/sources/' + $json.operatorSourceId }}"),
    "List Acceptance Tables": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/bases/' + $json.baseId + '/tables' }}"),
    "Get Acceptance Base Share": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/bases/' + $json.baseId + '/shared' }}"),
    "Get Reader Shared Views": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/tables/' + $json.factsTableId + '/share' }}"),
    "Get Operator Shared Views": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/tables/' + $json.decisionTableId + '/share' }}"),
    "List Cleanup Decisions": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Delete Cleanup Page": ("DELETE", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Insert Acceptance Decision": ("POST", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Read Inserted Decision": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Update Acceptance Decision": ("PATCH", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Read Updated Decision": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $('Require Inserted Decision').first().json.decisionTableId + '/records' }}"),
    "Try Protected Column Update": ("PATCH", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Try Reader Insert": ("POST", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $('Prepare Reader Negative Probe').first().json.factsTableId + '/records' }}"),
    "Delete Probe Decision": ("DELETE", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Confirm Probe Cleanup": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $('Evaluate Reader Insert Denial').first().json.decisionTableId + '/records' }}"),
    "Confirm Cleanup Absence": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Read Acceptance Facts": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.factsTableId + '/records' }}"),
    "Get Recovery Saved View": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/meta/tables/' + $('Evaluate Reader Insert Denial').first().json.factsTableId + '/views' }}"),
    "Read Recovery Fact": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.factsTableId + '/records' }}"),
    "Read Recovery Decision": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "List Feedback Residue": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Insert Feedback Decision": ("POST", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}"),
    "Read Refreshed Fact": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.factsTableId + '/records' }}"),
    "Read Cleanup Fact": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $('Prepare Cleanup Fact').first().json.factsTableId + '/records' }}"),
    "Read Retained Recovery Fact": ("GET", "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.factsTableId + '/records' }}"),
}


def validate_http_contract(candidate_nodes):
    require({node["name"] for node in candidate_nodes} == set(expected_http), "Acceptance HTTP node set is not exact.")
    for node in candidate_nodes:
        parameters = node.get("parameters", {})
        require(
            parameters.get("authentication") == "genericCredentialType"
            and parameters.get("genericAuthType") == "httpHeaderAuth",
            f"{node['name']} must use Header Auth.",
        )
        require(
            (parameters.get("method", "GET"), parameters.get("url", ""))
            == expected_http[node["name"]],
            f"{node['name']} has an unapproved HTTP method or API path.",
        )
        require(not node.get("credentials"), f"{node['name']} embeds a credential ID.")


validate_http_contract(http_nodes)


def require_url_mutation_rejected(url, label):
    mutated_nodes = copy.deepcopy(http_nodes)
    target = next(node for node in mutated_nodes if node["name"] == "List Cleanup Decisions")
    target["parameters"]["url"] = url
    try:
        validate_http_contract(mutated_nodes)
    except SystemExit:
        return
    raise SystemExit(f"Acceptance HTTP contract accepted {label}.")


require_url_mutation_rejected(
    "={{ 'http://off-host.invalid/proxy/http://nocodb.automation-data.svc.cluster.local:8080/api/v2/tables/' + $json.decisionTableId + '/records' }}",
    "an off-host URL containing the approved host later",
)
require_url_mutation_rejected(
    "={{ 'http://nocodb.automation-data.svc.cluster.local:8080/api/v2/unapproved/' + $json.decisionTableId + '/records' }}",
    "an unapproved path sharing the approved records suffix",
)

serialized = json.dumps(workflow)
for forbidden in ("storage/upload", "/meta/comments", "/download/", "multipart-form-data", "prepareBinaryData", "getBinaryDataBuffer", "attachmentCanary"):
    require(forbidden.lower() not in serialized.lower(), f"Dead native attachment behavior remains: {forbidden}")
require("DROP " not in serialized.upper() and "TRUNCATE " not in serialized.upper(), "Acceptance exposes broad destructive SQL.")

recovery_fact = by_name.get("Read Recovery Fact", {}).get("parameters", {})
recovery_decision = by_name.get("Read Recovery Decision", {}).get("parameters", {})
require(
    recovery_fact.get("method") == "GET"
    and {item.get("name"): str(item.get("value")) for item in recovery_fact.get("queryParameters", {}).get("parameters", [])}
    == {"where": "(id,eq,-334)", "limit": "2"},
    "Recovery fact must use one exact bounded reader query.",
)
require(
    recovery_decision.get("method") == "GET"
    and {item.get("name"): str(item.get("value")) for item in recovery_decision.get("queryParameters", {}).get("parameters", [])}
    == {"where": "(run_id,eq,recovery-canary-v2)", "limit": "2"},
    "Recovery decision must use one exact bounded operator query.",
)
for name, expected_query in (
    ("List Feedback Residue", {"where": "={{ '(run_id,eq,' + encodeURIComponent($json.runId) + ')' }}", "limit": "2"}),
    ("Read Cleanup Fact", {"where": "={{ '(id,eq,' + $('Prepare Cleanup Fact').first().json.factId + ')~and(run_id,eq,' + encodeURIComponent($('Prepare Cleanup Fact').first().json.runId) + ')' }}", "limit": "2"}),
    ("Read Retained Recovery Fact", {"where": "(id,eq,-334)~and(run_id,eq,recovery-canary-v2)", "limit": "2"}),
):
    parameters = by_name.get(name, {}).get("parameters", {})
    query = {item.get("name"): str(item.get("value")) for item in parameters.get("queryParameters", {}).get("parameters", [])}
    require(query == expected_query, f"{name} must use its exact bounded identity query.")

share_nodes = {
    name: by_name[name].get("parameters", {})
    for name in ("Get Acceptance Base Share", "Get Reader Shared Views", "Get Operator Shared Views")
}
require(
    all(parameters.get("method", "GET") == "GET" for parameters in share_nodes.values()),
    "Acceptance public-share checks must remain GET-only.",
)
reader_read = by_name.get("Read Acceptance Facts", {}).get("parameters", {})
require(
    {item.get("name"): str(item.get("value")) for item in reader_read.get("queryParameters", {}).get("parameters", [])}
    == {"limit": "1"},
    "The acceptance probe must retain its one-record reader bound.",
)

connections = workflow.get("connections", {})


def outgoing(name):
    return {
        edge["node"]
        for output in connections.get(name, {}).get("main", [])
        for edge in output
    }


def ordered_outputs(name):
    return [[edge["node"] for edge in output] for output in connections.get(name, {}).get("main", [])]


require(
    ordered_outputs("Select Acceptance Operation") == [
        ["Create Acceptance Structure"], ["Grant Acceptance Access"],
        ["List Acceptance Bases"], ["List Acceptance Bases"], ["List Acceptance Bases"],
    ],
    "Acceptance operation routing is not exact.",
)
require(ordered_outputs("Cleanup Only") == [["Initialize Cleanup"], ["Feedback Only"]], "Cleanup routing is not exact.")
require(ordered_outputs("Feedback Only") == [["Prepare Feedback Fact"], ["Read Acceptance Facts"]], "Feedback routing is not exact.")
for source, target in (
    ("Require Recovery Saved View", "Read Recovery Fact"),
    ("Read Recovery Fact", "Require Recovery Fact"),
    ("Require Recovery Fact", "Read Recovery Decision"),
    ("Read Recovery Decision", "Require Recovery Decision"),
    ("Require Recovery Decision", "Prepare Acceptance Response"),
    ("Prepare Feedback Fact", "List Feedback Residue"),
    ("List Feedback Residue", "Require Feedback Residue Bounded"),
    ("Require Feedback Residue Bounded", "Clear Feedback Residue"),
    ("Clear Feedback Residue", "Publish Initial Feedback Fact"),
    ("Publish Initial Feedback Fact", "Require Initial Runtime Fact"),
    ("Require Initial Runtime Fact", "Insert Feedback Decision"),
    ("Insert Feedback Decision", "Normalize Feedback Decision"),
    ("Normalize Feedback Decision", "Consume Feedback Before Refresh"),
    ("Consume Feedback Before Refresh", "Require Feedback Before Refresh"),
    ("Require Feedback Before Refresh", "Refresh Feedback Fact"),
    ("Refresh Feedback Fact", "Require Refreshed Runtime Fact"),
    ("Require Refreshed Runtime Fact", "Read Refreshed Fact"),
    ("Read Refreshed Fact", "Require Refreshed Reader Fact"),
    ("Require Refreshed Reader Fact", "Consume Feedback After Refresh"),
    ("Consume Feedback After Refresh", "Prepare Feedback Response"),
    ("Prepare Feedback Response", "Respond"),
    ("Require Cleanup Absent", "Prepare Cleanup Fact"),
    ("Prepare Cleanup Fact", "Cleanup Feedback Fact"),
    ("Cleanup Feedback Fact", "Read Cleanup Fact"),
    ("Read Cleanup Fact", "Require Cleanup Fact Absent"),
    ("Require Cleanup Fact Absent", "Read Retained Recovery Fact"),
    ("Read Retained Recovery Fact", "Require Cleanup Fact"),
    ("Require Cleanup Fact", "Respond"),
):
    require(target in outgoing(source), f"Acceptance graph must route {source} to {target}.")
require(
    "Get Acceptance Reader Source" in outgoing("Keep Acceptance Sources")
    and "Get Acceptance Operator Source" in outgoing("Capture Acceptance Reader Source")
    and "List Acceptance Tables" in outgoing("Capture Acceptance Operator Source"),
    "Acceptance must read both exact source configurations before resolving reflected tables.",
)
require(
    "Get Acceptance Base Share" in outgoing("Resolve Acceptance Tables")
    and "Get Reader Shared Views" in outgoing("Require Acceptance Base Private")
    and "Get Operator Shared Views" in outgoing("Require Reader Shares Empty")
    and "Cleanup Only" in outgoing("Require Operator Shares Empty"),
    "Acceptance must validate the base and both exact table share surfaces before operations.",
)
require(
    "Insert Acceptance Decision" in outgoing("Require Reader Facts Read"),
    "The successful bounded reader GET must be verified before write probes.",
)
require(
    "Cleanup Unexpected Reader Insert" in outgoing("Reader Insert Denied")
    and "Fail Unexpected Reader Insert" in outgoing("Cleanup Unexpected Reader Insert"),
    "An unexpectedly permitted reader insert must be cleaned before failure.",
)
require(
    "List Cleanup Decisions" in outgoing("Continue Cleanup")
    and "Require Cleanup Absent" in outgoing("Confirm Cleanup Absence"),
    "Decision cleanup must page within its bound and independently prove absence.",
)

response_predecessors = {
    source
    for source, outputs in connections.items()
    if any(edge.get("node") == "Respond" for output in outputs.get("main", []) for edge in output)
}
require(
    response_predecessors == {
        "Structure Result", "Grant Result", "Require Cleanup Fact", "Prepare Acceptance Response",
        "Prepare Feedback Response", "Prepare Acceptance Error Response",
    },
    "Acceptance responses must use only bounded response builders.",
)

pending = deque(["Acceptance Webhook"])
reachable = {"Acceptance Webhook"}
while pending:
    source = pending.popleft()
    for target in outgoing(source):
        if target not in reachable:
            reachable.add(target)
            pending.append(target)
executable = {node["name"] for node in nodes if node.get("type") != "n8n-nodes-base.stickyNote"}
require(executable <= reachable, "Every acceptance executable node must be reachable from the webhook.")
PY

node - "$acceptance_workflow" <<'JS'
const fs = require('fs');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const byName = Object.fromEntries(workflow.nodes.map((node) => [node.name, node]));
const execute = (name, input, lookup = {}, itemInputs = [input]) => {
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
    {},
  );
};
const rejects = (name, input, lookup, pattern) => {
  try { execute(name, input, lookup); } catch (error) { return pattern.test(error.message); }
  return false;
};

const feedbackRequest = execute('Normalize Acceptance Request', {
  body: { operation: 'feedback', runId: 'feedback-run-one' },
})[0].json;
if (feedbackRequest.operation !== 'feedback' || feedbackRequest.runId !== 'feedback-run-one') {
  throw new Error('the fixed feedback operation was not accepted');
}
for (const reserved of ['recovery-canary-v1', 'recovery-canary-v2']) {
  if (!rejects('Normalize Acceptance Request', { body: { operation: 'cleanup', runId: reserved } }, {}, /reserved_run_id/)) {
    throw new Error(`reserved ID ${reserved} was accepted`);
  }
}

const sourceContext = {
  operation: 'probe', runId: 'run-one', baseId: 'base-acceptance',
  readerSourceId: 'source-reader', operatorSourceId: 'source-operator',
};
const reader = execute(
  'Capture Acceptance Reader Source',
  { id: 'source-reader', base_id: 'base-acceptance', alias: 'Read Model', config: { searchPath: ['read_model'] } },
  { 'Keep Acceptance Sources': sourceContext },
)[0].json;
const sources = execute(
  'Capture Acceptance Operator Source',
  { id: 'source-operator', base_id: 'base-acceptance', alias: 'Operator', config: { searchPath: ['operator'] } },
  { 'Capture Acceptance Reader Source': reader },
)[0].json;
if (sources.readerSchema !== 'read_model' || sources.operatorSchema !== 'operator') throw new Error('source search paths were not retained');
const exactTables = [
  { id: 'table-facts', title: 'acceptance_facts', table_name: 'acceptance_facts', source_id: 'source-reader', schema: null },
  { id: 'table-decisions', title: 'acceptance_decision', table_name: 'acceptance_decision', source_id: 'source-operator', schema: null },
];
const resolved = execute('Resolve Acceptance Tables', {
  ...sources,
  tables: exactTables,
  pageInfo: { totalRows: 2, page: 1, pageSize: 25, isLastPage: true },
})[0].json;
if (resolved.reflectedTables[0].schema !== 'operator' || resolved.reflectedTables[1].schema !== 'read_model') {
  throw new Error('null table schemas were not resolved from validated source search paths');
}
for (const mutate of [
  (tables) => { tables[0].schema = 'read_model'; },
  (tables) => { tables[0].source_id = 'source-operator'; },
  (tables) => { tables[1].source_id = 'source-reader'; },
]) {
  const tables = exactTables.map((table) => ({ ...table }));
  mutate(tables);
  if (!rejects('Resolve Acceptance Tables', { ...sources, tables }, {}, /acceptance_reflection_invalid/)) {
    throw new Error('mismatched table/source identity was accepted');
  }
}

const privateBase = execute(
  'Require Acceptance Base Private',
  { uuid: null, roles: null, fk_custom_url_id: null },
  { 'Resolve Acceptance Tables': resolved },
)[0].json;
for (const body of [{ roles: null }, { uuid: 'public-base-uuid', roles: 'viewer' }]) {
  if (!rejects('Require Acceptance Base Private', body, { 'Resolve Acceptance Tables': resolved }, /acceptance_base_share_invalid/)) {
    throw new Error('missing or non-null base share UUID was accepted');
  }
}
const noReaderShares = execute(
  'Require Reader Shares Empty', { list: [], pageInfo: { totalRows: 0, isLastPage: true } },
  { 'Require Acceptance Base Private': privateBase },
)[0].json;
const noOperatorShares = execute(
  'Require Operator Shares Empty', { list: [], pageInfo: { totalRows: 0, isLastPage: true } },
  { 'Require Reader Shares Empty': noReaderShares },
)[0].json;
if (noOperatorShares.publicSharing.views.length !== 2) throw new Error('private table share evidence was not retained');
for (const [name, lookup] of [
  ['Require Reader Shares Empty', { 'Require Acceptance Base Private': privateBase }],
  ['Require Operator Shares Empty', { 'Require Reader Shares Empty': noReaderShares }],
]) {
  for (const body of [{ list: [{ id: 'view-one', uuid: 'shared-view' }] }, { unexpected: [] }]) {
    if (!rejects(name, body, lookup, /acceptance_table_share_invalid/)) {
      throw new Error(`${name} accepted a public or malformed share collection`);
    }
  }
}

const readerReadContext = { ...resolved, operation: 'probe', runId: 'run-one' };
const readerRead = execute('Require Reader Facts Read', {
  statusCode: 200,
  body: { list: [{ id: -334, fact: 'artifact-available' }], pageInfo: { totalRows: 1 } },
  context: readerReadContext,
})[0].json;
if (readerRead.readerRead !== true) throw new Error('successful bounded reader GET was not verified');
if (!rejects('Require Reader Facts Read', { statusCode: 200, body: {}, context: readerReadContext }, {}, /reader_read_invalid/)) {
  throw new Error('malformed reader GET was accepted');
}
const protectedContext = { ...readerRead, recordId: 7 };
const protectedDenial = execute('Capture Protected Update Denial', {
  statusCode: 400,
  body: {
    error: 'ERR_DATABASE_OP_FAILED', code: '42501',
    message: "The database user does not have permission to access 'acceptance_decision'.",
  },
  context: protectedContext,
})[0].json;
if (protectedDenial.protectedUpdateDenied !== true) throw new Error('exact PostgreSQL authorization denial was not accepted');
for (const response of [
  { statusCode: 500, body: { message: 'network failure' }, context: protectedContext },
  { statusCode: 400, body: { error: 'ERR_DATABASE_OP_FAILED', code: '23505', message: 'duplicate' }, context: protectedContext },
]) {
  if (!rejects('Capture Protected Update Denial', response, {}, /protected_update_denial_invalid/)) {
    throw new Error('non-authorization protected-update error was accepted');
  }
}
const negativeOne = execute('Prepare Reader Negative Probe', {}, { 'Capture Protected Update Denial': { ...protectedDenial, runId: 'run-one' } })[0].json;
const negativeTwo = execute('Prepare Reader Negative Probe', {}, { 'Capture Protected Update Denial': { ...protectedDenial, runId: 'run-two' } })[0].json;
if (negativeOne.readerProbeId === negativeTwo.readerProbeId || negativeOne.readerProbeFact !== 'forbidden:run-one') {
  throw new Error('reader negative probe is not unique and run-bound');
}
const readerDenial = execute('Evaluate Reader Insert Denial', {
  statusCode: 403,
  body: { error: 'ERR_FORBIDDEN', message: "Forbidden - Source 'Read Model' is read-only" },
  context: negativeOne,
})[0].json;
if (readerDenial.readerInsertDenied !== true || readerDenial.unexpectedlyPermitted !== false) {
  throw new Error('exact read-only source denial was not accepted');
}
const readerUnexpected = execute('Evaluate Reader Insert Denial', {
  statusCode: 200, body: { id: negativeOne.readerProbeId }, context: negativeOne,
})[0].json;
if (readerUnexpected.unexpectedlyPermitted !== true) throw new Error('unexpected reader insert did not route to cleanup');
if (!rejects('Evaluate Reader Insert Denial', {
  statusCode: 400, body: { error: 'ERR_DUPLICATE_RECORD', message: 'duplicate key' }, context: negativeOne,
}, {}, /reader_insert_denial_invalid/)) throw new Error('duplicate residue created a false reader-denial pass');

const cleanupContext = { operation: 'cleanup', runId: 'run-one', cleanupPageCount: 0, removedCount: 0 };
const cleanupPage = execute('Prepare Cleanup Page', {
  ...cleanupContext, rows: [{ id: 1, run_id: 'run-one' }, { id: 2, run_id: 'run-one' }],
})[0].json;
if (!cleanupPage.hasRows || cleanupPage.cleanupPageCount !== 1 || cleanupPage.deleteRows.length !== 2) {
  throw new Error('cleanup page was not bounded and prepared');
}
const cleanupDone = execute('Prepare Cleanup Page', { ...cleanupPage, rows: [] })[0].json;
if (cleanupDone.hasRows !== false || cleanupDone.removedCount !== 2) throw new Error('cleanup removed count was not retained');
if (!rejects('Prepare Cleanup Page', {
  ...cleanupContext, cleanupPageCount: 10, rows: [{ id: 3, run_id: 'run-one' }],
}, {}, /cleanup_page_bound_exceeded/)) throw new Error('cleanup accepted rows beyond its page bound');
const cleanupAbsent = execute('Require Cleanup Absent', {
  statusCode: 200, body: { list: [], pageInfo: { totalRows: 0 } }, context: cleanupDone,
})[0].json;
if (cleanupAbsent.ok !== true || cleanupAbsent.removedCount !== 2) throw new Error('decision cleanup absence was not verified');
if (!rejects('Require Cleanup Absent', {
  statusCode: 200, body: { list: [], pageInfo: { totalRows: 1 } }, context: cleanupDone,
}, {}, /cleanup_absence_invalid/)) throw new Error('inconsistent decision absence evidence was accepted');

const probeContext = {
  ...resolved, inserted: true, read: true, readerRead: true, decisionUpdated: true,
  protectedUpdateDenied: true, protectedUpdateStatus: 400, protectedUpdateEvidence: 'postgresql_42501',
  readerInsertDenied: true, readerInsertStatus: 403, readerInsertEvidence: 'source_read_only',
  publicSharing: {
    basePublicShareUuid: null,
    views: [
      { title: 'acceptance_facts', publicShareUuid: null },
      { title: 'acceptance_decision', publicShareUuid: null },
    ],
  },
};
const savedView = execute(
  'Require Recovery Saved View',
  { list: [{ id: 'view-facts', fk_model_id: 'table-facts', title: 'acceptance_facts', type: 3, uuid: null }] },
  { 'Evaluate Reader Insert Denial': probeContext, 'Confirm Probe Cleanup': { list: [], pageInfo: { totalRows: 0, isLastPage: true } } },
)[0].json;
const cleanupProbeContext = { ...probeContext, runId: 'run-after-feedback', recordId: 91 };
const recoveryViewInput = {
  list: [{ id: 'view-facts', fk_model_id: 'table-facts', title: 'acceptance_facts', type: 3, uuid: null }],
};
const emptyProbeResult = { list: [], pageInfo: { totalRows: 0, isLastPage: true } };
const afterFeedbackView = execute('Require Recovery Saved View', recoveryViewInput, {
  'Evaluate Reader Insert Denial': cleanupProbeContext,
  'Confirm Probe Cleanup': emptyProbeResult,
})[0].json;
if (afterFeedbackView.savedView.id !== 'view-facts') {
  throw new Error('an absent exact probe record prevented post-rotation completion');
}
for (const invalidCleanup of [
  { list: [{ id: 91, run_id: 'run-after-feedback' }], pageInfo: { totalRows: 1, isLastPage: true } },
  { list: [{ id: '91', run_id: 'run-after-feedback' }], pageInfo: { totalRows: 1, isLastPage: true } },
  { list: [{ id: 92, run_id: 'run-after-feedback', decision: 'corrected' }], pageInfo: { totalRows: 1, isLastPage: true } },
  { list: [], pageInfo: { totalRows: 1, isLastPage: true } },
  { list: [], pageInfo: { totalRows: 0, isLastPage: false } },
  { list: [] },
  { error: 'request_failed' },
]) {
  if (!rejects('Require Recovery Saved View', recoveryViewInput, {
    'Evaluate Reader Insert Denial': cleanupProbeContext,
    'Confirm Probe Cleanup': invalidCleanup,
  }, /probe_cleanup_failed/)) {
    throw new Error('a non-empty or malformed probe cleanup result passed as deletion evidence');
  }
}
const probeWhereExpression = byName['Confirm Probe Cleanup'].parameters.queryParameters.parameters
  .find((parameter) => parameter.name === 'where').value;
const probeWhere = new Function('$', `return (${probeWhereExpression.slice(3, -2)});`)(
  (name) => ({ first: () => ({ json: cleanupProbeContext }) }),
);
if (probeWhere !== '(id,eq,91)~and(run_id,eq,run-after-feedback)') {
  throw new Error('probe cleanup query must select only the exact probe record within its run');
}
for (const view of [
  { id: 'view-other', fk_model_id: 'table-facts', title: 'Grid', type: 3, uuid: null },
  { id: 'view-facts', fk_model_id: 'table-decisions', title: 'acceptance_facts', type: 3, uuid: null },
]) {
  if (!rejects('Require Recovery Saved View', { list: [view] }, { 'Evaluate Reader Insert Denial': probeContext, 'Confirm Probe Cleanup': { list: [], pageInfo: { totalRows: 0, isLastPage: true } } }, /recovery_saved_view_invalid/)) {
    throw new Error('mismatched recovery view identity was accepted');
  }
}

const factFixture = {
  id: -334,
  run_id: 'recovery-canary-v2',
  fact: 'artifact-available',
  artifact_id: 'issue334-artifact-v1',
  artifact_uri: 'https://artifacts.example.invalid/issue334/artifact-v1',
  artifact_media_type: 'text/plain',
  artifact_size_bytes: 37,
  artifact_sha256: '09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3',
};
const fact = execute('Require Recovery Fact', { list: [factFixture] }, { 'Require Recovery Saved View': savedView })[0].json;
for (const [label, patch] of [
  ['artifact metadata', { artifact_media_type: 'application/json' }],
  ['artifact URI', { artifact_uri: 'https://other.example.invalid/issue334/artifact-v1' }],
  ['reserved fact ID', { id: -335 }],
  ['legacy attachment shape', { attachment: [{ path: 'download/legacy' }] }],
]) {
  if (!rejects('Require Recovery Fact', { list: [{ ...factFixture, ...patch }] }, { 'Require Recovery Saved View': savedView }, /recovery_fact_invalid/)) {
    throw new Error(`${label} mismatch was accepted`);
  }
}

const decisionFixture = { id: 41, run_id: 'recovery-canary-v2', decision: 'retain' };
const canaryContext = execute('Require Recovery Decision', { list: [decisionFixture] }, { 'Require Recovery Fact': fact })[0].json;
for (const row of [
  { ...decisionFixture, run_id: 'recovery-canary-v1' },
  { ...decisionFixture, decision: 'corrected' },
  { ...decisionFixture, attachment: { path: 'download/legacy' } },
]) {
  if (!rejects('Require Recovery Decision', { list: [row] }, { 'Require Recovery Fact': fact }, /recovery_decision_invalid/)) {
    throw new Error('mismatched or legacy recovery decision was accepted');
  }
}
const expectedCanary = {
  version: 2,
  state: 'ready',
  baseId: 'base-acceptance',
  readerSourceId: 'source-reader',
  operatorSourceId: 'source-operator',
  factTableId: 'table-facts',
  decisionTableId: 'table-decisions',
  viewId: 'view-facts',
  rowId: '41',
  factId: -334,
  artifact: {
    id: 'issue334-artifact-v1',
    uri: 'https://artifacts.example.invalid/issue334/artifact-v1',
    mediaType: 'text/plain',
    sizeBytes: 37,
    sha256: '09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3',
  },
};
if (JSON.stringify(canaryContext.recoveryCanary) !== JSON.stringify(expectedCanary)) {
  throw new Error('record recovery canary output is not exact');
}
const response = execute('Prepare Acceptance Response', {}, { 'Require Recovery Decision': canaryContext })[0].json;
if (JSON.stringify(response.recoveryCanary) !== JSON.stringify(expectedCanary) || response.attachmentCanary !== undefined) {
  throw new Error('probe response did not expose only the record recovery canary');
}

const chainedReaderRead = execute('Require Reader Facts Read', {
  statusCode: 200,
  body: { list: [factFixture], pageInfo: { totalRows: 1 } },
  context: { ...noOperatorShares, operation: 'probe', runId: 'run-chain' },
})[0].json;
const chainedInsert = execute(
  'Normalize Inserted Decision', { id: 91 },
  { 'Cleanup Only': noOperatorShares, 'Require Reader Facts Read': chainedReaderRead },
)[0].json;
const chainedRead = execute('Require Inserted Decision', {
  list: [{ id: 91, run_id: chainedInsert.runId, decision: 'pending', protected_created_at: 'fixed-time' }],
}, { 'Normalize Inserted Decision': chainedInsert })[0].json;
const chainedUpdated = execute('Require Updated Decision', {
  list: [{ id: 91, run_id: chainedInsert.runId, decision: 'approved', protected_created_at: 'fixed-time' }],
}, { 'Require Inserted Decision': chainedRead })[0].json;
const chainedProtected = execute('Capture Protected Update Denial', {
  statusCode: 400,
  body: {
    error: 'ERR_DATABASE_OP_FAILED', code: '42501',
    message: "The database user does not have permission to access 'acceptance_decision'.",
  },
  context: chainedUpdated,
})[0].json;
const chainedNegative = execute(
  'Prepare Reader Negative Probe', {}, { 'Capture Protected Update Denial': chainedProtected },
)[0].json;
const chainedReaderDenial = execute('Evaluate Reader Insert Denial', {
  statusCode: 403,
  body: { error: 'ERR_FORBIDDEN', message: "Forbidden - Source 'Read Model' is read-only" },
  context: chainedNegative,
})[0].json;
const chainedView = execute('Require Recovery Saved View', {
  list: [{ id: 'view-facts', fk_model_id: 'table-facts', title: 'acceptance_facts', type: 3, uuid: null }],
}, {
  'Evaluate Reader Insert Denial': chainedReaderDenial,
  'Confirm Probe Cleanup': { list: [], pageInfo: { totalRows: 0, isLastPage: true } },
})[0].json;
const chainedFact = execute(
  'Require Recovery Fact', { list: [factFixture] }, { 'Require Recovery Saved View': chainedView },
)[0].json;
const chainedCanary = execute(
  'Require Recovery Decision', { list: [decisionFixture] }, { 'Require Recovery Fact': chainedFact },
)[0].json;
const chainedResponse = execute(
  'Prepare Acceptance Response', {}, { 'Require Recovery Decision': chainedCanary },
)[0].json;
if (chainedResponse.readerRead !== true || chainedResponse.runId !== 'run-chain') {
  throw new Error('reader-read evidence did not survive the actual producer-to-response Code-node chain');
}

const prepared = execute('Prepare Feedback Fact', {}, { 'Feedback Only': { ...resolved, operation: 'feedback', runId: 'feedback-run-one' } })[0].json;
if (!Number.isSafeInteger(prepared.factId) || prepared.factId === -334) throw new Error('feedback fact ID is not safe and run-bound');
const otherPrepared = execute('Prepare Feedback Fact', {}, { 'Feedback Only': { ...resolved, operation: 'feedback', runId: 'feedback-run-two' } })[0].json;
if (prepared.factId === otherPrepared.factId) throw new Error('distinct feedback runs reused a fact ID');
const noFeedbackResidue = execute('Require Feedback Residue Bounded', {
  list: [], pageInfo: { totalRows: 0, isLastPage: true },
}, { 'Prepare Feedback Fact': prepared })[0].json;
if (noFeedbackResidue.residueDecisionId !== null) throw new Error('empty feedback residue selected a row');
const oneFeedbackResidue = execute('Require Feedback Residue Bounded', {
  list: [{ id: 73, run_id: prepared.runId, decision: 'corrected' }],
  pageInfo: { totalRows: 1, isLastPage: true },
}, { 'Prepare Feedback Fact': prepared })[0].json;
if (oneFeedbackResidue.residueDecisionId !== 73) throw new Error('one exact feedback residue row was not selected');
for (const body of [
  {
    list: [
      { id: 73, run_id: prepared.runId, decision: 'corrected' },
      { id: 74, run_id: prepared.runId, decision: 'corrected' },
    ],
    pageInfo: { totalRows: 2, isLastPage: true },
  },
  {
    list: [{ id: 73, run_id: 'other-run', decision: 'corrected' }],
    pageInfo: { totalRows: 1, isLastPage: true },
  },
  {
    list: [{ id: null, run_id: prepared.runId, decision: 'corrected' }],
    pageInfo: { totalRows: 1, isLastPage: true },
  },
  { list: [], pageInfo: { totalRows: 1, isLastPage: false } },
]) {
  if (!rejects('Require Feedback Residue Bounded', body, { 'Prepare Feedback Fact': prepared }, /feedback_residue_invalid/)) {
    throw new Error('duplicate, mismatched, or incomplete feedback residue was accepted');
  }
}
if (!rejects('Require Initial Runtime Fact', {
  factId: prepared.factId, runId: prepared.runId, fact: 'original',
}, { 'Prepare Feedback Fact': prepared }, /feedback_initial_fact_invalid/)) {
  throw new Error('missing runtime binding proof was accepted');
}
const initial = execute('Require Initial Runtime Fact', {
  factId: prepared.factId, runId: prepared.runId, fact: 'original', runtimeRole: 'issue334_acceptance_runtime',
}, { 'Prepare Feedback Fact': prepared })[0].json;
const normalizedDecision = execute('Normalize Feedback Decision', { id: 73 }, { 'Require Initial Runtime Fact': initial })[0].json;
const before = execute('Require Feedback Before Refresh', {
  factId: prepared.factId, runId: prepared.runId, initialFact: 'original', operatorDecision: 'corrected',
  effectiveBeforeRefresh: 'corrected', runtimeRole: 'issue334_acceptance_runtime',
}, { 'Normalize Feedback Decision': normalizedDecision })[0].json;
const refreshed = execute('Require Refreshed Runtime Fact', {
  factId: prepared.factId, runId: prepared.runId, fact: 'refreshed', runtimeRole: 'issue334_acceptance_runtime',
}, { 'Require Feedback Before Refresh': before })[0].json;
const observed = execute('Require Refreshed Reader Fact', {
  list: [{ id: prepared.factId, run_id: prepared.runId, fact: 'refreshed' }],
}, { 'Require Refreshed Runtime Fact': refreshed })[0].json;
const feedback = execute('Prepare Feedback Response', {
  factId: prepared.factId, runId: prepared.runId, refreshedFact: 'refreshed', operatorDecision: 'corrected',
  effectiveAfterRefresh: 'corrected', runtimeRole: 'issue334_acceptance_runtime',
}, { 'Require Refreshed Reader Fact': observed })[0].json;
const expectedFeedback = {
  initialFact: 'original',
  operatorDecision: 'corrected',
  effectiveBeforeRefresh: 'corrected',
  refreshedFact: 'refreshed',
  effectiveAfterRefresh: 'corrected',
};
if (
  feedback.ok !== true || feedback.operation !== 'feedback' || feedback.runId !== 'feedback-run-one' ||
  feedback.domain !== 'issue334_acceptance' || feedback.factId !== prepared.factId ||
  JSON.stringify(feedback.feedback) !== JSON.stringify(expectedFeedback)
) throw new Error('feedback response is not exact');
for (const invalid of [
  { factId: prepared.factId, runId: prepared.runId, refreshedFact: 'refreshed', operatorDecision: 'corrected', effectiveAfterRefresh: 'original', runtimeRole: 'issue334_acceptance_runtime' },
  { factId: prepared.factId, runId: prepared.runId, refreshedFact: 'refreshed', operatorDecision: 'corrected', effectiveAfterRefresh: 'corrected' },
]) {
  if (!rejects('Prepare Feedback Response', invalid, { 'Require Refreshed Reader Fact': observed }, /feedback_after_refresh_invalid/)) {
    throw new Error('unobserved or losing feedback result was accepted');
  }
}

const cleanupFactContext = {
  ...cleanupAbsent, factsTableId: 'table-facts', decisionTableId: 'table-decisions', factId: prepared.factId,
};
const factAbsent = execute('Require Cleanup Fact Absent', {
  list: [], pageInfo: { totalRows: 0, isLastPage: true },
}, { 'Prepare Cleanup Fact': cleanupFactContext })[0].json;
if (factAbsent.factId !== prepared.factId || factAbsent.runId !== cleanupAbsent.runId) {
  throw new Error('exact cleanup fact absence did not retain context');
}
if (!rejects('Require Cleanup Fact Absent', {
  list: [{ id: prepared.factId, run_id: cleanupAbsent.runId, fact: 'refreshed' }],
  pageInfo: { totalRows: 1, isLastPage: true },
}, { 'Prepare Cleanup Fact': cleanupFactContext }, /cleanup_fact_absence_invalid/)) {
  throw new Error('remaining exact feedback fact was accepted as absent');
}
const retainedCanary = execute('Require Cleanup Fact', {
  list: [factFixture], pageInfo: { totalRows: 1, isLastPage: true },
}, { 'Require Cleanup Fact Absent': factAbsent })[0].json;
if (retainedCanary.ok !== true || retainedCanary.removedCount !== 2) {
  throw new Error('cleanup response was not gated by retained recovery fact evidence');
}
for (const body of [
  { list: [], pageInfo: { totalRows: 0, isLastPage: true } },
  { list: [{ ...factFixture, run_id: 'other-run' }], pageInfo: { totalRows: 1, isLastPage: true } },
  { list: [{ ...factFixture, id: -335 }], pageInfo: { totalRows: 1, isLastPage: true } },
]) {
  if (!rejects('Require Cleanup Fact', body, { 'Require Cleanup Fact Absent': factAbsent }, /cleanup_canary_invalid/)) {
    throw new Error('cleanup responded without exact retained recovery fact evidence');
  }
}
JS

mapfile -t packaged_workflows < <(
  yq -r '.configMapGenerator[] | select(.name == "n8n-workflow-templates") | .files[]' \
    "$kustomization" | LC_ALL=C sort
)
expected_workflows=(
  'automation-data-canary.json=workflows/automation-data-canary.json'
  'automation-data-provisioner.json=workflows/automation-data-provisioner.json'
  'nocodb-acceptance-domain.json=workflows/nocodb-acceptance-domain.json'
  'nocodb-source-provisioner.json=workflows/nocodb-source-provisioner.json'
  'platform-canary.json=workflows/platform-canary.json'
  'platform-workflow-failure.json=workflows/platform-workflow-failure.json'
)
[[ "${packaged_workflows[*]}" == "${expected_workflows[*]}" ]] || {
  echo 'The n8n workflow ConfigMap must package the complete exact workflow template set.' >&2
  exit 1
}

echo 'NocoDB workflow contracts passed.'
