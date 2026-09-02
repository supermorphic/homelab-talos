#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json"
kustomization="$repo_root/kubernetes/apps/automation/n8n/app/kustomization.yaml"

[[ -f "$workflow" ]] || {
  echo 'The automation-data provisioning workflow template is missing.' >&2
  exit 1
}

# Use the pinned YAML/JSON parser before the structural graph checks below.
yq -p=json -o=json '.' "$workflow" >/dev/null

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
require(webhook.get("parameters", {}).get("responseMode") == "usingRespondToWebhook", "The webhook must use an explicit response node.")

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

notes = "\n".join(
    node.get("parameters", {}).get("content", "")
    for node in nodes
    if node.get("type") == "n8n-nodes-base.stickyNote"
)
for label in (
    "Automation Data Provisioner",
    "Automation Data n8n API",
    "Automation Data Provisioning Header",
    "full-access Community API key",
    "n8n.lab.supermorphic.com",
):
    require(label in notes, f"Workflow setup note is missing {label!r}.")

print("automation-data workflow contract: PASS")
PY

mapfile -t packaged_workflows < <(
  yq -r '.configMapGenerator[] | select(.name == "n8n-workflow-templates") | .files[]' \
    "$kustomization" | LC_ALL=C sort
)
expected_workflows=(
  'automation-data-provisioner.json=workflows/automation-data-provisioner.json'
  'platform-canary.json=workflows/platform-canary.json'
)
[[ "${packaged_workflows[*]}" == "${expected_workflows[*]}" ]] || {
  echo 'The n8n workflow ConfigMap must package both secret-free templates.' >&2
  exit 1
}
