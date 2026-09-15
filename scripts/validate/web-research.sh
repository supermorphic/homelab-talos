#!/usr/bin/env bash
set -euo pipefail

work="$(mktemp -d /tmp/homelab-web-research-validate.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
controller_source='kubernetes/apps/networking/envoy-gateway/app'
helm template envoy-gateway "$(yq -r '.spec.url' "$controller_source/ocirepository.yaml")" \
	--version "$(yq -r '.spec.ref.tag' "$controller_source/ocirepository.yaml")" \
	--namespace envoy-gateway-system --values "$controller_source/values.yaml" \
	>"$work/controller.yaml"
uv run --locked python scripts/validate/web_research.py --controller-manifest "$work/controller.yaml"

mkdir "$work/manifests"
for package in namespace/app searxng/app crawl4ai/app crawl4ai/proxy alerts/app; do
	# Flux removes SOPS metadata during decryption. Validate the resource shape
	# without decrypting ciphertext or changing the operator's source artifact.
	kustomize build "kubernetes/apps/web-research/$package" |
		yq ea 'del(.sops)' >"$work/manifests/${package//\//-}.yaml"
done
kubeconform -strict -summary -ignore-missing-schemas "$work/manifests"
scripts/validate/alerts.sh web-research
uv run --locked python - <<'PY' >"$work/agent-metrics.txt"
import sys
from pathlib import Path
sys.path.insert(0, "kubernetes/apps/web-research/crawl4ai/runtime")
from credential_agent import CredentialAgent
agent = CredentialAgent(
    upstream_url="http://127.0.0.1:11235",
    admin_token_file=Path("unused-for-metrics"),
    subject="fixture@example.com",
)
# No worker or network call: validate the cold-start exposition format.
print(agent.monitor_response("/metrics").body.decode(), end="")
PY
promtool check metrics <"$work/agent-metrics.txt"
uv run --locked python -m unittest discover -s scripts/test/web_research -p 'test_*.py'
node --test scripts/test/web_research/test_live_contract_node.js
printf '%s\n' 'Web research source, native rendering, Prometheus rules and runtime unit tests passed.'
