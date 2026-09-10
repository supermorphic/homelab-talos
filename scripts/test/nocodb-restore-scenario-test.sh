#!/usr/bin/env bash
# Bounded offline control-flow tests for metadata-only NocoDB recovery.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

scenario='scripts/test/scenarios/nocodb-restore-drill.sh'
[[ -x "$scenario" ]] || {
	echo "Missing executable NocoDB restore scenario: $scenario" >&2
	exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-restore-scenario-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"
postgresql_render="$fixture/postgresql.yaml"
kustomize build kubernetes/apps/automation-data/postgresql/app >"$postgresql_render"
backup_configmap="$(yq ea -r '
  select(.kind == "CronJob" and .metadata.name == "automation-data-postgresql-backup") |
  [.spec.jobTemplate.spec.template.spec.volumes[] |
    select(.name == "backup-script") | .configMap.name] |
  select(length == 1) | .[0]
' "$postgresql_render")"
[[ "$backup_configmap" =~ ^automation-data-postgresql-backup-[a-z0-9]+$ ]] || {
	echo 'NocoDB restore scenario test could not resolve the rendered backup ConfigMap.' >&2
	exit 1
}

cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state="${NOCODB_RESTORE_FIXTURE_STATE:?}"
events="$state/events.log"
args=" $* "
printf 'kubectl\n' >>"$events"
namespace='-'
previous=''
for argument in "$@"; do
	if [[ "$previous" == --namespace ]]; then namespace="$argument"; fi
	previous="$argument"
done

key_for() { printf '%s' "$1" | tr '/.' '__'; }
created() { [[ -e "$state/created-$(key_for "$1")" ]]; }
deleted() { [[ -e "$state/deleted-$(key_for "$1")" ]]; }

if [[ "$args" == *' get lease '* ]]; then
	printf 'verify-lease\n' >>"$events"
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == lease-loss ]] && created policy; then
		printf 'lease-lost\n' >>"$events"
		printf '%s\n' '{"spec":{"holderIdentity":"another-run"}}'
		exit 0
	fi
	jq -n --arg holder "${TEST_CAMPAIGN_LEASE_HOLDER:?}" '{
    metadata:{resourceVersion:"7"},
    spec:{holderIdentity:$holder,leaseDurationSeconds:90,
      acquireTime:"2099-01-01T00:00:00.000000Z",renewTime:"2099-01-01T00:00:00.000000Z"}
  }'
	exit 0
fi

if [[ "$args" == *' get httproutes.gateway.networking.k8s.io '* ]]; then
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == cross-namespace-route ]]; then
		jq -n --arg service "nc-restore-${NOCODB_RESTORE_RUN_HASH:?}-nocodb" '{items:[{
			metadata:{namespace:"another-namespace"},spec:{rules:[{backendRefs:[{name:$service,namespace:"automation-data"}]}]}}]}'
		exit 0
	fi
	printf '%s\n' '{"items":[]}'
	exit 0
fi

if [[ "$args" == *' get cronjob automation-data-postgresql-backup '* ]]; then
	case "${NOCODB_RESTORE_VOLUME_CASE:-}" in
		missing-backup-script-volume)
			jq -n '{kind:"CronJob",metadata:{name:"automation-data-postgresql-backup"},spec:{jobTemplate:{spec:{template:{spec:{volumes:[{name:"tmp",emptyDir:{}}]}}}}}}'
			;;
		ambiguous-backup-script-volume)
			jq -n --arg name "${NOCODB_RESTORE_BACKUP_CONFIGMAP:?}" '{kind:"CronJob",metadata:{name:"automation-data-postgresql-backup"},spec:{jobTemplate:{spec:{template:{spec:{volumes:[
				{name:"backup-script",configMap:{name:$name}},
				{name:"backup-script",configMap:{name:$name}}
			]}}}}}}'
			;;
		stale-backup-configmap-reference)
			jq -n '{kind:"CronJob",metadata:{name:"automation-data-postgresql-backup"},spec:{jobTemplate:{spec:{template:{spec:{volumes:[
				{name:"backup-script",configMap:{name:"automation-data-postgresql-backup-stalehash"}}
			]}}}}}}'
			;;
		*)
			jq -n --arg name "${NOCODB_RESTORE_BACKUP_CONFIGMAP:?}" '{kind:"CronJob",metadata:{name:"automation-data-postgresql-backup"},spec:{jobTemplate:{spec:{template:{spec:{volumes:[
				{name:"backup-script",configMap:{name:$name}}
			]}}}}}}'
			;;
	esac
	exit 0
fi

if [[ "$args" == *' get configmap '* && "$args" == *' --output json '* ]]; then
	case "${NOCODB_RESTORE_VOLUME_CASE:-}" in
		missing-backup-configmap) exit 1 ;;
		missing-backup-script-key)
			jq -n --arg name "${NOCODB_RESTORE_BACKUP_CONFIGMAP:?}" '{kind:"ConfigMap",metadata:{name:$name},data:{"update-backup-status.sql":"sql"}}'
			;;
		missing-backup-status-key)
			jq -n --arg name "${NOCODB_RESTORE_BACKUP_CONFIGMAP:?}" '{kind:"ConfigMap",metadata:{name:$name},data:{"backup.sh":"script"}}'
			;;
		*)
			jq -n --arg name "${NOCODB_RESTORE_BACKUP_CONFIGMAP:?}" '{kind:"ConfigMap",metadata:{name:$name},data:{"backup.sh":"script","update-backup-status.sql":"sql"}}'
			;;
	esac
	exit 0
fi

if [[ "$args" == *' get ciliumnetworkpolicy/'* && "$args" != *' --ignore-not-found '* ]]; then
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == unexpected-source-routing ]]; then
		jq '.specs[2].egress[1].toEndpoints[0].matchLabels."homelab-talos/run-id" = "another-run"' "$state/policy.json"
	else
		cat "$state/policy.json"
	fi
	exit 0
fi

if [[ "$args" == *' get service '* && "$args" == *' --output json '* ]]; then
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == wrong-target ]]; then
		jq -n '{kind:"Service",metadata:{name:"automation-data-postgresql",namespace:"automation-data"},spec:{clusterIP:"192.0.2.45",selector:{"app.kubernetes.io/name":"automation-data-postgresql"}}}'
	else
		jq -n --arg name "nc-restore-${NOCODB_RESTORE_RUN_HASH:?}-db" --arg run_hash "${NOCODB_RESTORE_RUN_HASH:?}" '{kind:"Service",metadata:{name:$name,namespace:"automation-data",labels:{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":$run_hash,"homelab-talos/role":"database"}},spec:{clusterIP:"192.0.2.45",selector:{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":$run_hash,"homelab-talos/role":"database"}}}'
	fi
	exit 0
fi

if [[ "$args" == *' get job '* && "$args" == *' --output json '* ]]; then
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == request-failure && "$args" == *-request* ]]; then
		printf '%s\n' '{"status":{"conditions":[{"type":"Failed","status":"True","reason":"CanaryMismatch"}]}}'
		exit 0
	fi
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == invalid-logical && "$args" == *-preflight* ]]; then
		printf '%s\n' '{"status":{"conditions":[{"type":"Failed","status":"True","reason":"InvalidBundle"}]}}'
		exit 0
	fi
	printf '%s\n' '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
	exit 0
fi

if [[ "$args" == *' logs job/'* ]]; then
	job="$(printf '%s\n' "$@" | awk '/^job\// {print; exit}')"
	if [[ "$job" == *-preflight ]]; then
		printf '%s\n' 'selected_bundle=automation-data-20260904T023000Z'
	elif [[ "$job" == *-load ]]; then
		printf '%s\n' \
			'selected_bundle=automation-data-20260904T023000Z' \
			'post_recovery_bundle=automation-data-20260904T030000Z' \
			"source_registry_base64=${NOCODB_RESTORE_SOURCE_REGISTRY_BASE64:?}"
	else
		printf '%s\n' 'nocodb_restore_assertions=passed'
	fi
	exit 0
fi

if [[ "$args" == *' rollout status '* || "$args" == *' wait --for=jsonpath='* ]]; then
	exit 0
fi

if [[ "$args" == *' create --filename '* ]]; then
	filename=''
	previous=''
	for argument in "$@"; do
		if [[ "$previous" == --filename ]]; then filename="$argument"; fi
		previous="$argument"
	done
	manifest="$(mktemp "$state/manifest.XXXXXX")"
	if [[ "$filename" == - ]]; then cat >"$manifest"; else cp "$filename" "$manifest"; fi
	kinds="$(yq ea -r 'select(.kind != null) | .kind' "$manifest")"
	if rg -Fxq CiliumNetworkPolicy <<<"$kinds"; then
		printf '%s\n' create-policy >>"$events"
		: >"$state/created-policy"
		yq ea -o=json 'select(.kind == "CiliumNetworkPolicy")' "$manifest" >"$state/policy.json"
	fi
	if rg -Fxq StatefulSet <<<"$kinds"; then printf '%s\n' create-database >>"$events"; fi
	if rg -Fxq Volume <<<"$kinds" || rg -Fxq PersistentVolume <<<"$kinds"; then
		echo 'NocoDB restore scenario attempted to create attachment storage.' >&2
		exit 65
	fi
	if rg -Fxq Deployment <<<"$kinds"; then
		printf '%s\n' create-app >>"$events"
		: >"$state/created-$(key_for deployment)"
	fi
	if rg -Fxq Job <<<"$kinds"; then
		job_name="$(yq ea -r 'select(.kind == "Job") | .metadata.name' "$manifest")"
		if [[ "$job_name" == *-request ]]; then
			printf '%s\n' create-request >>"$events"
		elif [[ "$job_name" == *-preflight ]]; then
			printf '%s\n' create-preflight >>"$events"
		else
			printf '%s\n' create-restore-job >>"$events"
			yq -o=json '.' "$manifest" | jq -e --arg configmap "${NOCODB_RESTORE_BACKUP_CONFIGMAP:?}" '
          (.spec.template.spec.containers[0].volumeMounts[] | select(.name == "backups") |
            .readOnly == true and .subPath == "automation-data-20260904T023000Z" and
            .mountPath == "/backups/automation-data-20260904T023000Z") and
          ([.spec.template.spec.volumes[] | select(.name == "scripts") |
            select(.configMap.name == $configmap)] | length) == 1
        ' >/dev/null
		fi
	fi
	while IFS=$'\t' read -r kind name; do
		case "$kind" in
			PersistentVolumeClaim) target="pvc/$name" ;;
			Service) target="service/$name" ;;
			StatefulSet) target="statefulset/$name" ;;
			Job) target="job/$name" ;;
			CiliumNetworkPolicy) target="ciliumnetworkpolicy/$name" ;;
			Deployment) target="deployment/$name" ;;
			*) continue ;;
		esac
		: >"$state/created-$(key_for "$target")"
	done < <(yq ea -r 'select(.kind != null) | [.kind,.metadata.name] | @tsv' "$manifest")
	exit 0
fi

if [[ "$args" == *' delete '* ]]; then
	target="$(printf '%s\n' "$@" | awk '/^(job|deployment|service|statefulset|pvc|ciliumnetworkpolicy|persistentvolume|volumes\.longhorn\.io)\// {print; exit}')"
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == cleanup-failure && "$target" == deployment/* ]]; then
		printf 'cleanup-delete-failed %s\n' "$target" >>"$events"
		exit 1
	fi
	: >"$state/deleted-$(key_for "$target")"
	printf 'delete %s\n' "$target" >>"$events"
	exit 0
fi

if [[ "$args" == *' get '* && "$args" == *' --ignore-not-found '* ]]; then
	target="$(printf '%s\n' "$@" | awk '/^(job|deployment|service|statefulset|pvc|ciliumnetworkpolicy|persistentvolume|volumes\.longhorn\.io)\// {print; exit}')"
	if created "$target" && ! deleted "$target"; then
		jq -n --arg run_hash "${NOCODB_RESTORE_RUN_HASH:?}" '{
        kind:"Fixture",metadata:{labels:{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":$run_hash}}
      }'
	fi
	exit 0
fi

echo "Unexpected fake kubectl invocation: namespace=$namespace args=$*" >&2
exit 64
EOF

chmod +x "$fixture/bin/kubectl" "$fixture/bin/sleep"

failures=0
record_failure() {
	echo "NocoDB restore scenario test failed: $*" >&2
	failures=$((failures + 1))
}

event_line() { rg -n -m1 -F "$1" "$2" | cut -d: -f1; }

run_case() { # <case>
	local case_name="$1" state run_id run_hash status
	local confirmation='restore:nocodb:metadata'
	[[ "$case_name" != wrong-confirmation ]] || confirmation='restore:nocodb'
	state="$fixture/$case_name"
	run_id="20260905T010000Z-restore-$case_name"
	run_hash="$(printf '%s' "$run_id" | shasum -a 256 | cut -c1-12)"
	mkdir -p "$state/$run_id/diagnostics"
	: >"$state/events.log"
	source_registry_base64="$(jq -nc '{items:[
    {domain:"issue334_acceptance",accessKind:"reader",state:"ready",baseId:"base-canary",sourceId:"source-reader",integrationId:"integration-reader",valid:true},
    {domain:"issue334_acceptance",accessKind:"operator",state:"ready",baseId:"base-canary",sourceId:"source-operator",integrationId:"integration-operator",valid:true}
  ]}' | base64 | tr -d '\n')"
	if [[ "$case_name" == invalid-registry ]]; then
		source_registry_base64="$(printf '%s' '{"items":[]}' | base64 | tr -d '\n')"
	fi
	set +e
	PATH="$fixture/bin:$PATH" \
		HOMELAB_TEST_RUN_DIR="$state/$run_id" TEST_RUN_ID="$run_id" \
		TEST_CAMPAIGN_LEASE_HOLDER="$run_id" NOCODB_RESTORE_CONFIRM="$confirmation" \
		NOCODB_RESTORE_FIXTURE_STATE="$state" NOCODB_RESTORE_VOLUME_CASE="$case_name" \
		NOCODB_RESTORE_RUN_HASH="$run_hash" \
		NOCODB_RESTORE_BACKUP_CONFIGMAP="$backup_configmap" \
		NOCODB_RESTORE_SOURCE_REGISTRY_BASE64="$source_registry_base64" \
		"$scenario" "$fixture/kubeconfig" >"$state/stdout.log" 2>"$state/stderr.log"
	status="$?"
	set -e
	if [[ "$case_name" != wrong-confirmation && "$case_name" != lease-loss ]]; then
		if [[ "$(jq -r '.status' "$state/$run_id/cleanup.json")" != passed ]]; then
			printf 'cleanup-failed\n' >>"$state/events.log"
		fi
	fi
	printf '%s\t%s\t%s\n' "$case_name" "$status" "$state"
}

IFS=$'\t' read -r case_name status state < <(run_case valid)
if [[ "$status" -ne 0 ]]; then
	record_failure "valid metadata-only lifecycle exited $status: $(tail -n 1 "$state/stderr.log")"
else
	evidence="$state/20260905T010000Z-restore-valid/diagnostics/nocodb-restore-evidence.json"
	[[ -f "$evidence" ]] || record_failure 'restore evidence is missing from diagnostics'
	[[ ! -e "$state/20260905T010000Z-restore-valid/nocodb-restore-evidence.json" ]] ||
		record_failure 'restore evidence polluted the canonical run root'
	if [[ -f "$evidence" ]]; then
		jq -e '.workspaceBaseViewSourcesAndRecordsValidated == true and
		  .productionMutation == false and (.selectedAutomationDataBundle | startswith("automation-data-"))' \
		  "$evidence" >/dev/null || record_failure 'restore diagnostics omitted recovery evidence'
	fi
	preflight="$(event_line create-preflight "$state/events.log")"
	database_create="$(event_line create-database "$state/events.log")"
	restore_create="$(event_line create-restore-job "$state/events.log")"
	app="$(event_line create-app "$state/events.log")"
	request="$(event_line create-request "$state/events.log")"
	if ! ((preflight < database_create && database_create < restore_create && restore_create < app && app < request)); then
		record_failure 'valid lifecycle did not gate logical preflight, isolated restore, fresh NocoDB scratch, and request readback in order'
	fi
	! rg -q 'persistentvolume|volumes\.longhorn\.io|backups\.longhorn\.io|backuptargets\.longhorn\.io|nocodb-data' "$state/events.log" ||
		record_failure 'metadata-only recovery observed or created attachment storage'
fi

IFS=$'\t' read -r case_name status state < <(run_case wrong-confirmation)
[[ "$status" -ne 0 && ! -s "$state/events.log" ]] || record_failure 'wrong confirmation reached Kubernetes'

IFS=$'\t' read -r case_name status state < <(run_case lease-loss)
[[ "$status" -ne 0 ]] || record_failure 'Lease loss was accepted'
[[ "$(rg '^create-' "$state/events.log")" == $'create-preflight\ncreate-policy' ]] || record_failure 'Lease loss allowed the next create'
! awk '/^lease-lost$/ {lost=1} lost && /^(create-|delete )/ {print}' "$state/events.log" | rg -q . || record_failure 'Lease loss allowed a mutation'

IFS=$'\t' read -r case_name status state < <(run_case invalid-logical)
[[ "$status" -ne 0 ]] || record_failure 'invalid logical backup was accepted'
[[ "$(rg '^create-' "$state/events.log")" == create-preflight ]] || record_failure 'invalid logical backup created restoration resources'
! rg -Fxq cleanup-failed "$state/events.log" || record_failure 'invalid logical backup failed preflight cleanup'

for rejected_case in cross-namespace-route wrong-target; do
	IFS=$'\t' read -r case_name status state < <(run_case "$rejected_case")
	[[ "$status" -ne 0 ]] || record_failure "$case_name preflight was accepted"
	if [[ "$case_name" == cross-namespace-route ]]; then
		! rg -q '^(create-|delete )' "$state/events.log" || record_failure "$case_name preflight allowed a mutation"
	else
		! rg -Fxq create-app "$state/events.log" || record_failure "$case_name started NocoDB"
		! rg -Fxq cleanup-failed "$state/events.log" || record_failure "$case_name failed cleanup"
	fi
done

for rejected_case in missing-backup-script-volume ambiguous-backup-script-volume \
	stale-backup-configmap-reference missing-backup-configmap missing-backup-script-key \
	missing-backup-status-key; do
	IFS=$'\t' read -r case_name status state < <(run_case "$rejected_case")
	[[ "$status" -ne 0 ]] || record_failure "$case_name backup script reference was accepted"
	! rg -q '^(create-|delete )' "$state/events.log" || record_failure "$case_name allowed a mutation"
done

for rejected_case in invalid-registry unexpected-source-routing request-failure; do
	IFS=$'\t' read -r case_name status state < <(run_case "$rejected_case")
	[[ "$status" -ne 0 ]] || record_failure "$case_name was accepted"
	! rg -Fxq cleanup-failed "$state/events.log" || record_failure "$case_name failed cleanup"
	if [[ "$case_name" == invalid-registry || "$case_name" == unexpected-source-routing ]]; then
		! rg -Fxq create-app "$state/events.log" || record_failure "$case_name started NocoDB"
	else
		rg -Fxq create-request "$state/events.log" || record_failure 'request failure did not reach the consumer'
	fi
done

IFS=$'\t' read -r case_name status state < <(run_case cleanup-failure)
[[ "$status" -ne 0 ]] || record_failure 'failed run-owned cleanup was accepted'
rg -q '^cleanup-delete-failed deployment/' "$state/events.log" ||
	record_failure 'cleanup-failure did not exercise the run-owned Deployment deletion'
[[ "$(jq -r '.status' "$state"/*/cleanup.json)" == failed ]] ||
	record_failure 'cleanup failure was not recorded as a failed phase'

[[ "$failures" -eq 0 ]] || exit 1
echo 'NocoDB restore scenario tests passed.'
