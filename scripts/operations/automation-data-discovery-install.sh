#!/usr/bin/env bash
# Guarded operator-only installation. Routine clients never invoke this workflow.
set -euo pipefail
set +x
umask 077
source scripts/lib/common.sh
source scripts/lib/rollout.sh
source scripts/lib/lease.sh
source scripts/lib/n8n-verification.sh
source scripts/lib/automation-data-discovery-install.sh
require_bash

[[ "$#" -eq 1 || ("$#" -eq 2 && "$2" == finalize) || ("$#" -eq 3 && "$2" == guard) ]] || exit 2
[[ "${AUTOMATION_DATA_DISCOVERY_INSTALL_CONFIRM:-}" == install:automation-data:discovery ]] || {
	echo 'Operator installation requires AUTOMATION_DATA_DISCOVERY_INSTALL_CONFIRM=install:automation-data:discovery.' >&2
	exit 1
}
kubeconfig="$1"
directory="${AUTOMATION_DATA_DISCOVERY_INSTALL_DIRECTORY:-${XDG_CONFIG_HOME:-$HOME/.config}/homelab/automation-data}"
export AUTOMATION_DATA_DISCOVERY_INSTALL_DIRECTORY="$directory"
[[ -f "$kubeconfig" && "$directory" == /* ]] || exit 2
enrollment() { uv run --locked python scripts/lib/automation_data_enrollment.py "$@"; }
run_id="${3:-$(date -u +%Y%m%dt%H%M%Sz)-$(openssl rand -hex 4)}"
[[ "$run_id" =~ ^[a-z0-9-]{1,40}$ ]] || exit 2
kc() {
	local namespace="$1"
	shift
	kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" "$@"
}

source_guard() {
	local remote_sha state name
	discovery_require_source
	read -r remote_sha _ < <(git ls-remote --exit-code origin refs/heads/main)
	[[ "$remote_sha" =~ ^[a-f0-9]{40}$ ]]
	state="$(kc flux-system get gitrepository flux-system --output json)"
	[[ "$(yq -r '.status.artifact.revision' <<<"$state")" == *"$remote_sha" ]]
	for name in automation-data-postgresql n8n-postgresql n8n nocodb; do
		state="$(kc flux-system get kustomization "$name" --output json)"
		n8n_flux_resource_current_ready <(printf '%s\n' "$state")
		[[ "$(yq -r '.status.lastAppliedRevision' <<<"$state")" == *"$remote_sha" ]]
	done
	for target in automation-data:automation-data-postgresql automation:n8n-postgresql; do
		state="$(kc "${target%:*}" get statefulset "${target#*:}" --output json)"
		n8n_statefulset_current_ready <(printf '%s\n' "$state")
	done
}

mutation_guard() {
	local namespace backup state
	source_guard
	verify_test_lease_holder "$kubeconfig" "$run_id"
	for namespace in automation-data automation; do
		backup="discovery-before-${namespace}-${run_id}"
		state="$(kc "$namespace" get job "$backup" --output json)"
		discovery_backup_ready <(printf '%s\n' "$state") "$run_id"
	done
}

# Called again by the enrollment client immediately before each remote mutation.
if [[ "${2:-}" == guard ]]; then
	mutation_guard
	exit
fi

source_guard
enrollment initialize
if [[ "${2:-}" == finalize ]]; then
	enrollment finalize
	enrollment report
	exit
fi
enrollment prepare
native_project="${AUTOMATION_DATA_DISCOVERY_N8N_PROJECT_ID:-}"
if [[ -z "$native_project" ]]; then
	# Fail before reader mutation when the selected API path lacks authentication.
	if [[ ! -f "$directory/n8n-api-key" ]]; then
		echo 'Select the existing n8n project ID from native n8n metadata with AUTOMATION_DATA_DISCOVERY_N8N_PROJECT_ID; no API-key file is needed for native enrollment.' >&2
		exit 1
	fi
	enrollment api-preflight
fi
temp_dir="$(mktemp -d "$directory/run.XXXXXXXX")"
lease_acquired=false
created=()
cleanup() {
	local result="$?" target namespace kind name state cleanup_ok=true
	trap - EXIT INT TERM
	set +e
	for target in "${created[@]}"; do
		IFS=: read -r namespace kind name <<<"$target"
		state="$(kc "$namespace" get "$kind" "$name" --ignore-not-found --output json)" || {
			cleanup_ok=false
			continue
		}
		if [[ -n "$state" ]]; then
			discovery_resource_owned <(printf '%s\n' "$state") "$run_id" || {
				cleanup_ok=false
				continue
			}
			kc "$namespace" delete "$kind" "$name" --wait=true --timeout=2m >/dev/null || cleanup_ok=false
		fi
		[[ -z "$(kc "$namespace" get "$kind" "$name" --ignore-not-found --output name)" ]] || cleanup_ok=false
	done
	if [[ "$lease_acquired" == true ]]; then release_test_lease "$kubeconfig" "$run_id" >/dev/null || cleanup_ok=false; fi
	rm -r -- "$temp_dir"
	if [[ "$cleanup_ok" != true ]]; then
		echo 'Discovery installation cleanup failed; inspect the run-owned resources and Lease.' >&2
		exit 1
	fi
	exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$native_project" ]]; then
	enrollment native-input "$native_project" "$temp_dir/native-input.json"
fi
acquire_test_lease "$kubeconfig" "$run_id" >/dev/null
lease_acquired=true
start_test_lease_renewal "$kubeconfig" "$run_id" "$temp_dir/lease-failed"
for namespace in automation-data automation; do
	host=automation-data-postgresql
	[[ "$namespace" != automation ]] || host=n8n-postgresql
	source_guard
	discovery_require_lease "$kubeconfig" "$run_id" "$temp_dir"
	[[ "$(kc "$namespace" get jobs --selector "app.kubernetes.io/name=$host-backup" --output json | yq '[.items[] | select((.status.active // 0) > 0)] | length')" == 0 ]]
	backup="discovery-before-${namespace}-${run_id}"
	[[ -z "$(kc "$namespace" get job "$backup" --ignore-not-found --output name)" ]]
	kc "$namespace" create job "$backup" --from="cronjob/$host-backup" --dry-run=client --output json |
		RUN_ID="$run_id" yq -o=json '.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID) | .spec.template.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID)' >"$temp_dir/backup.json"
	created+=("$namespace:job:$backup")
	kc "$namespace" create --filename "$temp_dir/backup.json" >/dev/null
	discovery_wait_job "$kubeconfig" "$namespace" "$backup" 1800
done

if [[ -n "$native_project" ]]; then
	mutation_guard
	discovery_require_lease "$kubeconfig" "$run_id" "$temp_dir"
	config="discovery-native-${run_id}"
	secret="discovery-native-input-${run_id}"
	for target in "configmap:$config" "secret:$secret"; do
		[[ -z "$(kc automation get "${target%:*}" "${target#*:}" --ignore-not-found --output name)" ]]
	done
	kc automation create configmap "$config" --from-file=enroll.cjs=scripts/lib/automation-data-discovery-enroll.cjs --dry-run=client --output json |
		RUN_ID="$run_id" yq -o=json '.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID)' >"$temp_dir/native-config.json"
	kc automation create secret generic "$secret" --from-file="bundle.json=$temp_dir/native-input.json" --dry-run=client --output json |
		RUN_ID="$run_id" yq -o=json '.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID)' >"$temp_dir/native-secret.json"
	created+=("automation:configmap:$config" "automation:secret:$secret")
	kc automation create --filename "$temp_dir/native-config.json" >/dev/null
	kc automation create --filename "$temp_dir/native-secret.json" >/dev/null
	native_job() {
		local mode="$1" job="discovery-native-${1}-${run_id}"
		[[ -z "$(kc automation get job "$job" --ignore-not-found --output name)" ]]
		mutation_guard
		discovery_require_lease "$kubeconfig" "$run_id" "$temp_dir"
		enrollment native-manifest "$job" "$run_id" "$config" "$secret" "$mode" >"$temp_dir/native-job.json"
		if [[ "$mode" == import ]]; then enrollment native-start; fi
		created+=("automation:job:$job")
		kc automation create --filename "$temp_dir/native-job.json" >/dev/null
		discovery_wait_job "$kubeconfig" automation "$job" 330
		local expected=discovery_native_enrollment=verified
		[[ "$mode" != preflight ]] || expected=discovery_native_preflight=verified
		[[ "$(kc automation logs "job/$job" --tail=1)" == "$expected" ]]
	}
	# Resolve project, Secret mounts, DB authentication, and collisions before DDL.
	native_job preflight
fi

for source in platform nocodb n8n; do
	namespace=automation-data
	base=kubernetes/apps/automation-data/postgresql/app
	sql=credential-discovery.sql
	config_prefix=automation-data-postgresql-upgrade
	[[ "$source" != nocodb ]] || sql=nocodb-discovery.sql
	if [[ "$source" == n8n ]]; then
		namespace=automation
		base=kubernetes/apps/automation/n8n-postgresql/app
		config_prefix=n8n-postgresql-discovery
	fi
	mutation_guard
	discovery_require_lease "$kubeconfig" "$run_id" "$temp_dir"
	# Compare the exact published ConfigMap inputs with the reviewed local render.
	kustomize build "$base" | PREFIX="$config_prefix-" yq -o=json 'select(.kind == "ConfigMap" and (.metadata.name | test("^" + strenv(PREFIX))))' >"$temp_dir/expected.json"
	config="$(yq -r '.metadata.name' "$temp_dir/expected.json")"
	[[ "$config" =~ ^[a-z0-9-]+$ ]]
	kc "$namespace" get configmap "$config" --output json >"$temp_dir/deployed.json"
	SQL_KEY="$sql" yq -e '.data[strenv(SQL_KEY)] != null' "$temp_dir/deployed.json" >/dev/null
	uv run --locked python - "$temp_dir/expected.json" "$temp_dir/deployed.json" "$sql" <<'PYTHON'
import json,sys
from pathlib import Path
expected,current=(json.loads(Path(p).read_text()) for p in sys.argv[1:3])
if expected['data'][sys.argv[3]]!=current.get('data',{}).get(sys.argv[3]):
    raise SystemExit('Deployed discovery SQL differs from reviewed source.')
PYTHON
	config="discovery-${source}-${run_id}"
	secret="discovery-candidate-${source}-${run_id}"
	job="discovery-install-${source}-${run_id}"
	for target in "configmap:$config" "secret:$secret" "job:$job"; do
		[[ -z "$(kc "$namespace" get "${target%:*}" "${target#*:}" --ignore-not-found --output name)" ]]
	done
	kc "$namespace" create configmap "$config" --from-file="projection.sql=$base/scripts/$sql" \
		--from-file=install-reader.sh=scripts/lib/automation-data-discovery-reader.sh --dry-run=client --output json |
		RUN_ID="$run_id" yq -o=json '.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID)' >"$temp_dir/configmap.json"
	kc "$namespace" create secret generic "$secret" --from-file="candidate=$directory/pending/$source.candidate" --dry-run=client --output json |
		RUN_ID="$run_id" yq -o=json '.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID)' >"$temp_dir/candidate.json"
	created+=("$namespace:configmap:$config" "$namespace:secret:$secret" "$namespace:job:$job")
	kc "$namespace" create --filename "$temp_dir/configmap.json" >/dev/null
	kc "$namespace" create --filename "$temp_dir/candidate.json" >/dev/null
	mutation_guard
	discovery_require_lease "$kubeconfig" "$run_id" "$temp_dir"
	enrollment manifest "$source" "$job" "$run_id" "$config" "$secret" >"$temp_dir/job.json"
	kc "$namespace" create --filename "$temp_dir/job.json" >/dev/null
	discovery_wait_job "$kubeconfig" "$namespace" "$job" 150
	[[ "$(kc "$namespace" logs "job/$job" --tail=1)" == discovery_installation=applied ]]
done
if [[ -n "$native_project" ]]; then
	# Reader loops change config/secret variables; use the retained native inputs.
	config="discovery-native-${run_id}"
	secret="discovery-native-input-${run_id}"
	native_job import
	enrollment native-complete
	enrollment publication
	echo 'Publish the retained inventory workflow with native n8n, then run automation-data-discovery-install finalize.'
	exit
fi
for source in platform nocodb n8n header; do
	mutation_guard
	enrollment enroll "$source" "$kubeconfig" "$run_id"
done
enrollment workflow "$kubeconfig" "$run_id"
mutation_guard
enrollment finalize
enrollment report
echo 'discovery_installation=complete; protected receipt retained; routine discovery uses inventory-only access'
