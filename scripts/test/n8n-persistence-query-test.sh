#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/test/lib/n8n-persistence-query.sh
source scripts/test/lib/n8n-persistence-query.sh

single_pod='{"items":[{"metadata":{"name":"n8n-abc","uid":"uid-1"},"spec":{"nodeName":"nuc1"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
not_ready_pod='{"items":[{"metadata":{"name":"n8n-abc","uid":"uid-1"},"spec":{"nodeName":"nuc1"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}'
multiple_pods='{"items":[{"metadata":{"name":"n8n-a","uid":"uid-1"},"spec":{"nodeName":"nuc1"}},{"metadata":{"name":"n8n-b","uid":"uid-2"},"spec":{"nodeName":"nuc2"}}]}'

[[ "$(n8n_single_pod_identity <<<"$single_pod")" == $'n8n-abc\tuid-1\tnuc1' ]]
[[ -z "$(n8n_single_pod_identity <<<'{"items":[]}')" ]]
[[ -z "$(n8n_single_pod_identity <<<"$multiple_pods")" ]]
[[ "$(n8n_single_ready_node <<<"$single_pod")" == 'nuc1' ]]
[[ -z "$(n8n_single_ready_node <<<"$not_ready_pod")" ]]
[[ -z "$(n8n_single_ready_node <<<"$multiple_pods")" ]]

echo 'n8n persistence JSON query tests passed.'
