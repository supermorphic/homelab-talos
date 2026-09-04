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
        f"Observe {access_kind} Ready Job" in reachable(f"Validate {access_kind} Source")
        and f"Require {access_kind} Ready Job" in reachable(f"Observe {access_kind} Ready Job")
        and ready in reachable(f"Require {access_kind} Ready Job"),
        f"{access_kind} ready output must observe the exact stored source-create job after source GET.",
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
for (const workflowPath of process.argv.slice(2)) {
  const candidate = JSON.parse(fs.readFileSync(workflowPath, 'utf8'));
  for (const node of candidate.nodes.filter((item) => item.type === 'n8n-nodes-base.code')) {
    try {
      new Function('$json', '$input', '$', node.parameters.jsCode);
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

const sourceContext = { ...base, integrationId: 'integration-1', alias: 'Read Model' };
const mergedRotation = execute(
  'Merge Reader State',
  { result: { state: 'error', operation: 'rotate', sourceId: 'source-1', integrationId: 'integration-1' } },
  { 'Start Reader': { ...sourceContext, operation: 'rotate', requestedAccessKind: 'reader' } },
)[0].json;
if (mergedRotation.operation !== 'rotate' || mergedRotation.registryOperation !== 'rotate' || mergedRotation.requestedAccessKind !== 'reader') {
  throw new Error('requested and retained source operations were not kept distinct');
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
    'Validate Reader Source': { ...sourceContext, requestedAccessKind: 'operator' },
    'Normalize Source Request': operatorRotateRequest,
  },
)[0].json;
if (operatorTargetReaderGate.rotateTarget !== false) throw new Error('operator-targeted rotation enabled the reader rotation path');
const operatorTargetOperatorGate = execute(
  'Require Operator PostgreSQL',
  { result: operatorValidation },
  {
    'Validate Operator Source': { ...sourceContext, accessKind: 'operator', requestedAccessKind: 'operator' },
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
  sourceCreateJobState: 'completed', sourceDiscovered: true, sourceReadBack: true,
  dataEditAllowed: false, schemaEditAllowed: false,
};
const mergedReaderReady = execute(
  'Merge Reader Ready Evidence', { result: storedReader },
  { 'Normalize Source Request': { domain: 'domain_one', operation: 'sync', requestedAccessKind: null }, 'Require Reader PostgreSQL': observedReader },
)[0].json;
if (mergedReaderReady.credentialGeneration !== 2 || mergedReaderReady.sourceCreateJobState !== 'completed' || mergedReaderReady.postgresqlValidation.valid !== true) {
  throw new Error('reader stored state and observed readiness evidence were not merged');
}
const storedOperator = {
  domain: 'domain_one', accessKind: 'operator', state: 'ready', baseId: 'base-1', sourceId: 'source-operator',
  integrationId: 'integration-operator', sourceCreateJobId: 'job-operator', generation: 12, credentialGeneration: 3,
  operationStartedAt: '2026-09-04T12:02:00Z', updatedAt: '2026-09-04T12:03:00Z', validatedAt: '2026-09-04T12:03:00Z',
};
const observedOperator = {
  ...operatorTargetOperatorGate, sourceId: 'source-operator', integrationId: 'integration-operator', sourceCreateJobId: 'job-operator',
  sourceCreateJobState: 'completed', sourceDiscovered: true, sourceReadBack: true,
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
if (mergedOperatorSync.sourceCreateJobState !== 'completed' || mergedOperatorSync.postgresqlValidation.valid !== true) {
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
  if (boundedSourceResponse[kind].sourceCreateJobState !== 'completed' || boundedSourceResponse[kind].postgresqlValidation.valid !== true) {
    throw new Error(`${kind} source response did not contain observed terminal job and PostgreSQL evidence`);
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
  const valid = execute(fixture.node, fixture.source, fixture.lookup)[0].json;
  if (valid.integrationId !== 'integration-current') throw new Error(`${fixture.name} GET did not accept its selected current integration`);
  if (valid.dataEditAllowed !== (fixture.name === 'operator') || valid.schemaEditAllowed !== false || valid.sourceDiscovered !== true || valid.sourceReadBack !== true) {
    throw new Error(`${fixture.name} source GET flags were not preserved as observed evidence`);
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
      'Discover Reader Source After Job': { sourceId: 'source-new-reader', selectedIntegrationId: 'integration-new', sourceCreateJobId: 'job-current-reader' },
    },
    expected: 'job-current-reader',
  },
  {
    node: 'Validate Operator Source',
    source: { id: 'source-new-operator', base_id: 'base-1', fk_integration_id: 'integration-new', alias: 'Operator', config: { searchPath: ['operator'] }, is_data_readonly: false, is_schema_readonly: true },
    lookup: {
      'Prepare Operator': { domain: 'domain_one', baseId: 'base-1' },
      'Read Operator State': { result: null },
      'Discover Operator Source After Job': { sourceId: 'source-new-operator', selectedIntegrationId: 'integration-new', sourceCreateJobId: 'job-current-operator' },
    },
    expected: 'job-current-operator',
  },
]) {
  if (execute(fixture.node, fixture.source, fixture.lookup)[0].json.sourceCreateJobId !== fixture.expected) {
    throw new Error(`${fixture.node} did not carry the current completed job identity into read-back evidence`);
  }
}

for (const [name, kind] of [['Require Reader Ready Job', 'reader'], ['Require Operator Ready Job', 'operator']]) {
  const context = {
    ...base, accessKind: kind, sourceId: `source-${kind}`, sourceCreateJobId: `job-${kind}`,
    dataEditAllowed: kind === 'operator', schemaEditAllowed: false, sourceDiscovered: true, sourceReadBack: true,
  };
  const result = execute(name, { ...context, jobs: [{ id: `job-${kind}`, job: 'source-create', status: 'completed' }] })[0].json;
  if (result.sourceCreateJobState !== 'completed') throw new Error(`${name} did not preserve observed completed job state`);
  for (const jobs of [[], [{ id: `job-${kind}`, job: 'source-create', status: 'active' }]]) {
    let rejected = false;
    try { execute(name, { ...context, jobs }); } catch (error) { rejected = /ready_job_invalid/.test(error.message); }
    if (!rejected) throw new Error(`${name} accepted missing or nonterminal job evidence`);
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
for marker in ("operation", "runId", "structure", "grants", "probe", "cleanup", "Object.keys", "allowedFields"):
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
require(len(postgres_nodes) == 4, "Acceptance must have exactly four fixed migrator operations.")
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
    require("http://nocodb.automation-data.svc.cluster.local:8080/api/v2/" in url, f"{node['name']} has an unapproved API host.")
    require(
        "/tables/" in url
        or url.endswith("/api/v2/meta/bases")
        or ("/api/v2/meta/bases/" in url and ("/sources" in url or "/tables" in url or "/shared" in url)),
        f"{node['name']} has an unapproved acceptance API path.",
    )

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
notes = by_name.get("Acceptance Setup", {}).get("parameters", {}).get("content", "")
for label in ("automation-data/issue334_acceptance/migrator", "NocoDB Operator API", "NocoDB Acceptance Header"):
    require(label in notes, f"The acceptance setup note omits {label}.")
require("all four Postgres nodes" in notes, "The acceptance setup must bind the migrator credential to all four Postgres nodes.")
PY

node - "$acceptance_workflow" <<'JS'
const fs = require('fs');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
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
  { id: 'table-facts', title: 'acceptance_facts', table_name: 'acceptance_facts', source_id: 'source-reader', schema: 'read_model' },
  { id: 'table-decisions', title: 'acceptance_decision', table_name: 'acceptance_decision', source_id: 'source-operator', schema: 'operator' },
];
const completePage = { totalRows: 2, page: 1, pageSize: 25, isFirstPage: true, isLastPage: true };
const resolved = execute('Resolve Acceptance Tables', { ...reflectedContext, tables: exactTables, pageInfo: completePage })[0].json;
if (
  resolved.factsTableId !== 'table-facts'
  || resolved.decisionTableId !== 'table-decisions'
  || JSON.stringify(resolved.reflectedSchemas) !== JSON.stringify(['operator', 'read_model'])
  || resolved.reflectedTables.some((table) => table.schema !== exactTables.find((candidate) => candidate.id === table.id).schema)
) throw new Error('exact reflected schemas and tables were not derived');
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
  },
)[0].json;
if (
  acceptanceResponse.credentialProof?.throughN8n !== true
  || acceptanceResponse.credentialProof?.credentialName !== 'NocoDB Operator API'
  || acceptanceResponse.publicSharing?.basePublicShareUuid !== null
  || acceptanceResponse.publicSharing?.views?.length !== 2
) throw new Error('successful HTTP probe omitted credential-path or public-sharing evidence');
for (const forbidden of ['password', 'token', 'header', 'credentialId']) {
  if (JSON.stringify(acceptanceResponse).toLowerCase().includes(forbidden.toLowerCase())) {
    throw new Error(`acceptance response exposed secret-bearing field ${forbidden}`);
  }
}
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
