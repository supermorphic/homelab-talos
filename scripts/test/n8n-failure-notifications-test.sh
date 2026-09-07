#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
handler="$repo_root/kubernetes/apps/automation/n8n/app/workflows/platform-workflow-failure.json"
fixture_dir="$repo_root/tests/fixtures/n8n-failure-notifications"
fixture_one="$fixture_dir/platform-failure-fixture-one.json"
fixture_two="$fixture_dir/platform-failure-fixture-two.json"
behavior_test="$repo_root/scripts/test/n8n-failure-notifications-test.js"

for required_file in "$handler" "$fixture_one" "$fixture_two" "$behavior_test"; do
  [[ -f "$required_file" ]] || {
    echo "Required n8n failure-notification artifact is missing: $required_file" >&2
    exit 1
  }
done

for workflow in "$handler" "$fixture_one" "$fixture_two"; do
  yq -p=json -o=json '.' "$workflow" >/dev/null
done

python - "$handler" "$fixture_one" "$fixture_two" <<'PY'
import json
import re
import sys
from pathlib import Path


handler_path, *fixture_paths = map(Path, sys.argv[1:])
handler = json.loads(handler_path.read_text())
fixtures = [json.loads(path.read_text()) for path in fixture_paths]
uuid_pattern = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def contains_key(value, target):
    if isinstance(value, dict):
        return target in value or any(contains_key(child, target) for child in value.values())
    if isinstance(value, list):
        return any(contains_key(child, target) for child in value)
    return False


def exact_connection(workflow, source, target):
    return workflow.get("connections", {}).get(source) == {
        "main": [[{"node": target, "type": "main", "index": 0}]]
    }


require(handler.get("name") == "Platform Workflow Failure Handler", "Unexpected handler name.")
require(handler.get("active") is False, "The handler template must be inactive.")
require("id" not in handler, "The handler template must not bind an instance workflow ID.")
require(not contains_key(handler, "credentials"), "The handler template must not bind credentials.")
handler_nodes = handler.get("nodes", [])
handler_by_name = {node.get("name"): node for node in handler_nodes}
require(len(handler_by_name) == len(handler_nodes), "Handler node names must be unique.")
require(
    sorted((node.get("name"), node.get("type")) for node in handler_nodes)
    == sorted(
        [
            ("Failure Event", "n8n-nodes-base.errorTrigger"),
            ("Format Failure Notification", "n8n-nodes-base.code"),
            ("Publish Failure Notification", "n8n-nodes-base.httpRequest"),
        ]
    ),
    "The handler must contain only the exact three-node inventory.",
)
require(
    handler_by_name["Failure Event"].get("parameters") == {},
    "The Error Trigger must not accept configurable input.",
)
require(
    set(handler_by_name["Format Failure Notification"].get("parameters", {})) == {"jsCode"},
    "The formatter must contain only code parameters.",
)
publish = handler_by_name["Publish Failure Notification"]
require(publish.get("typeVersion") == 4.4, "The ntfy request must use the pinned HTTP node version.")
require(publish.get("executeOnce") is True, "The ntfy request must execute once.")
require(publish.get("retryOnFail") is False, "The ntfy request must disable retries.")
require("maxTries" not in publish and "waitBetweenTries" not in publish, "Retry controls must be absent.")
publish_parameters = publish.get("parameters", {})
require(
    set(publish_parameters)
    == {
        "method",
        "url",
        "authentication",
        "genericAuthType",
        "sendBody",
        "contentType",
        "specifyBody",
        "jsonBody",
        "options",
    },
    "The ntfy request has parameters outside its bounded publish contract.",
)
require(publish_parameters.get("method") == "POST", "The ntfy request must use POST.")
require(
    publish_parameters.get("url") == "http://ntfy.ntfy.svc.cluster.local",
    "The ntfy request URL must use the fixed cluster service.",
)
require(
    publish_parameters.get("authentication") == "genericCredentialType"
    and publish_parameters.get("genericAuthType") == "httpHeaderAuth",
    "The ntfy request must use the Platform Failure ntfy Header Auth contract.",
)
require(
    publish_parameters.get("sendBody") is True
    and publish_parameters.get("contentType") == "json"
    and publish_parameters.get("specifyBody") == "json"
    and publish_parameters.get("jsonBody") == "={{ JSON.stringify($json) }}",
    "The ntfy request must publish only the formatter JSON.",
)
require(
    publish_parameters.get("options")
    == {
        "redirect": {"redirect": {"followRedirects": False}},
        "timeout": 10000,
        "sendCredentialsOnCrossOriginRedirect": False,
    },
    "The ntfy request must disable redirects and use a ten-second timeout.",
)
require(
    exact_connection(handler, "Failure Event", "Format Failure Notification")
    and exact_connection(handler, "Format Failure Notification", "Publish Failure Notification")
    and set(handler.get("connections", {})) == {"Failure Event", "Format Failure Notification"},
    "The handler must be one linear three-node path.",
)
require(
    handler.get("settings")
    == {
        "executionOrder": "v1",
        "saveDataErrorExecution": "none",
        "saveDataSuccessExecution": "none",
        "saveManualExecutions": False,
        "saveExecutionProgress": False,
        "callerPolicy": "workflowsFromSameOwner",
    },
    "The handler settings must disable retained input and downstream chaining.",
)

expected_fixtures = [
    (
        "Platform Failure Fixture One",
        "platform-failure-fixture-one",
        "SYNTHETIC_SENSITIVE_MARKER_ONE_DO_NOT_PUBLISH",
    ),
    (
        "Platform Failure Fixture Two",
        "platform-failure-fixture-two",
        "SYNTHETIC_SENSITIVE_MARKER_TWO_DO_NOT_PUBLISH",
    ),
]
for fixture, (expected_name, expected_path, expected_marker) in zip(
    fixtures, expected_fixtures, strict=True
):
    require(fixture.get("name") == expected_name, "Unexpected failure fixture name.")
    require(fixture.get("active") is False, f"{expected_name} must be inactive.")
    require("id" not in fixture, f"{expected_name} must not bind an instance workflow ID.")
    require(not contains_key(fixture, "credentials"), f"{expected_name} must not bind credentials.")
    nodes = fixture.get("nodes", [])
    by_name = {node.get("name"): node for node in nodes}
    require(len(by_name) == len(nodes), f"{expected_name} node names must be unique.")
    require(
        sorted((node.get("name"), node.get("type")) for node in nodes)
        == sorted(
            [
                ("Synthetic Failure Webhook", "n8n-nodes-base.webhook"),
                ("Raise Synthetic Failure", "n8n-nodes-base.stopAndError"),
            ]
        ),
        f"{expected_name} must contain only Webhook and Stop And Error.",
    )
    webhook = by_name["Synthetic Failure Webhook"]
    require(
        webhook.get("parameters")
        == {
            "httpMethod": "POST",
            "path": expected_path,
            "authentication": "headerAuth",
            "responseMode": "onReceived",
            "options": {},
        },
        f"{expected_name} must use its exact private Header Auth webhook.",
    )
    stop = by_name["Raise Synthetic Failure"]
    require(
        stop.get("parameters")
        == {"errorType": "errorMessage", "errorMessage": expected_marker},
        f"{expected_name} must raise only its fixed synthetic marker.",
    )
    require(
        exact_connection(fixture, "Synthetic Failure Webhook", "Raise Synthetic Failure")
        and set(fixture.get("connections", {})) == {"Synthetic Failure Webhook"},
        f"{expected_name} must contain one linear failure path.",
    )
    require(
        fixture.get("settings")
        == {
            "executionOrder": "v1",
            "saveDataErrorExecution": "all",
            "saveDataSuccessExecution": "none",
            "saveManualExecutions": False,
            "saveExecutionProgress": False,
            "callerPolicy": "workflowsFromSameOwner",
        },
        f"{expected_name} must retain only its synthetic failed execution.",
    )
    require("errorWorkflow" not in fixture.get("settings", {}), f"{expected_name} must be bound at setup.")

all_workflows = [handler, *fixtures]
all_ids = [
    value
    for workflow in all_workflows
    for value in [workflow.get("versionId"), *(node.get("id") for node in workflow.get("nodes", []))]
]
require(all(isinstance(value, str) and uuid_pattern.fullmatch(value) for value in all_ids), "Template IDs must be valid UUIDv4 values.")
require(len(all_ids) == len(set(all_ids)), "Template IDs must be unique.")

handler_serialized = json.dumps(handler)
for marker in ("SYNTHETIC_SENSITIVE_MARKER_ONE_DO_NOT_PUBLISH", "SYNTHETIC_SENSITIVE_MARKER_TWO_DO_NOT_PUBLISH"):
    require(marker not in handler_serialized, "The handler must not encode synthetic or application payloads.")
require("instanceId" not in handler_serialized, "The handler template must not bind an n8n instance.")
PY

mise exec -- node "$behavior_test" "$handler"
