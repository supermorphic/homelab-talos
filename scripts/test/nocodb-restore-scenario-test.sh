#!/usr/bin/env bash
# Bounded offline control-flow tests for Longhorn restore gating in the NocoDB drill.
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

if [[ "$args" == *' get persistentvolumeclaim nocodb-data '* ]]; then
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == missing-pvc ]]; then exit 1; fi
	printf '%s\n' '{"metadata":{"uid":"claim-uid"},"spec":{"volumeName":"pvc-nocodb-volume","resources":{"requests":{"storage":"10Gi"}},"storageClassName":"longhorn","accessModes":["ReadWriteOnce"]},"status":{"phase":"Bound"}}'
	exit 0
fi

if [[ "$args" == *' get persistentvolume pvc-nocodb-volume '* ]]; then
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == mismatched-pv ]]; then printf '%s\n' '{}'; exit 0; fi
	printf '%s\n' '{"spec":{"capacity":{"storage":"10Gi"},"accessModes":["ReadWriteOnce"],"claimRef":{"namespace":"automation-data","name":"nocodb-data","uid":"claim-uid"},"csi":{"driver":"driver.longhorn.io","volumeHandle":"pvc-nocodb-volume"}}}'
	exit 0
fi

if [[ "$args" == *' get backuptargets.longhorn.io default '* ]]; then
	if [[ "${NOCODB_RESTORE_VOLUME_CASE:-}" == unavailable-target ]]; then printf '%s\n' '{}'; exit 0; fi
	printf '%s\n' '{"metadata":{"name":"default"},"spec":{"backupTargetURL":"s3://off-cluster"},"status":{"available":true}}'
	exit 0
fi

if [[ "$args" == *' get backups.longhorn.io '* ]]; then
	case "${NOCODB_RESTORE_VOLUME_CASE:-}" in
		missing-backup) printf '%s\n' '{"items":[]}'; exit 0 ;;
		incomplete-backup|wrong-backup-size|missing-backup-url)
			backup_state=Completed; backup_size=10737418240; backup_url='s3://off-cluster/backup-closest'
			[[ "$NOCODB_RESTORE_VOLUME_CASE" != incomplete-backup ]] || backup_state=Pending
			[[ "$NOCODB_RESTORE_VOLUME_CASE" != wrong-backup-size ]] || backup_size=5368709120
			[[ "$NOCODB_RESTORE_VOLUME_CASE" != missing-backup-url ]] || backup_url=''
			jq -n --arg state "$backup_state" --arg size "$backup_size" --arg url "$backup_url" '{items:[{
				metadata:{name:"backup-closest"},spec:{backupTargetName:"default"},status:{state:$state,
				volumeName:"pvc-nocodb-volume",backupCreatedAt:"2026-09-04T02:31:00Z",url:$url,volumeSize:$size}}]}'
			exit 0 ;;
	esac
	printf '%s\n' '{"items":[{"metadata":{"name":"backup-closest"},"spec":{"backupTargetName":"default"},"status":{"state":"Completed","volumeName":"pvc-nocodb-volume","backupCreatedAt":"2026-09-04T02:31:00Z","url":"s3://off-cluster/backup-closest","volumeSize":"10737418240"}}]}'
	exit 0
fi

if [[ "$args" == *' get volumes.longhorn.io/'* ]]; then
	target="$(printf '%s\n' "$@" | awk '/^volumes\.longhorn\.io\// {print; exit}')"
	if ! created "$target" || deleted "$target"; then exit 0; fi
	if created deployment; then phase=post; else phase=pre; fi
	printf 'observe-volume-%s\n' "$phase" >>"$events"
	volume_case="${NOCODB_RESTORE_VOLUME_CASE:-valid}"
	backup='s3://off-cluster/backup-closest'
	size='10737418240'
	state_name='detached'
	robustness='unknown'
	replicas='{}'
	if [[ "$phase" == post ]]; then
		state_name='attached'
		robustness='healthy'
		replicas='{"replica-a":"RW","replica-b":"RW"}'
	fi
	case "$volume_case:$phase" in
		attached-before-bind:pre)
			state_name='attached'; robustness='healthy'; replicas='{"replica-a":"RW","replica-b":"RW"}' ;;
		wrong-backup:pre)
			backup='s3://off-cluster/different-backup'; state_name='attached'; robustness='healthy'; replicas='{"replica-a":"RW","replica-b":"RW"}' ;;
		wrong-size:pre)
			size='5368709120'; state_name='attached'; robustness='healthy'; replicas='{"replica-a":"RW","replica-b":"RW"}' ;;
		post-detached:post)
			state_name='detached'; robustness='unknown'; replicas='{}' ;;
	esac
	jq -n --arg name "${target#*/}" --arg backup "$backup" --arg size "$size" \
		--arg state_name "$state_name" --arg robustness "$robustness" --argjson replicas "$replicas" \
		--arg run_hash "${NOCODB_RESTORE_RUN_HASH:?}" '{
			kind:"Volume",metadata:{name:$name,labels:{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":$run_hash}},
      spec:{numberOfReplicas:2,fromBackup:$backup,size:$size},
      status:{state:$state_name,robustness:$robustness,restoreRequired:false,replicaModeMap:$replicas}
    }'
	exit 0
fi

if [[ "$args" == *' get ciliumnetworkpolicy/'* && "$args" != *' --ignore-not-found '* ]]; then
	cat "$state/policy.json"
	exit 0
fi

if [[ "$args" == *' get service '* && "$args" == *'jsonpath={.spec.clusterIP}'* ]]; then
	printf '192.0.2.45'
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
	if rg -Fxq Volume <<<"$kinds"; then printf '%s\n' create-volume >>"$events"; fi
	if rg -Fxq PersistentVolume <<<"$kinds"; then printf '%s\n' create-binding >>"$events"; fi
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
			yq -o=json '.' "$manifest" | jq -e '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "backups") |
          .readOnly == true and .subPath == "automation-data-20260904T023000Z" and
          .mountPath == "/backups/automation-data-20260904T023000Z"' >/dev/null
		fi
	fi
	while IFS=$'\t' read -r kind name; do
		case "$kind" in
			PersistentVolumeClaim) target="pvc/$name" ;;
			Service) target="service/$name" ;;
			StatefulSet) target="statefulset/$name" ;;
			Job) target="job/$name" ;;
			CiliumNetworkPolicy) target="ciliumnetworkpolicy/$name" ;;
			Volume) target="volumes.longhorn.io/$name" ;;
			PersistentVolume) target="persistentvolume/$name" ;;
			Deployment) target="deployment/$name" ;;
			*) continue ;;
		esac
		: >"$state/created-$(key_for "$target")"
	done < <(yq ea -r 'select(.kind != null) | [.kind,.metadata.name] | @tsv' "$manifest")
	exit 0
fi

if [[ "$args" == *' delete '* ]]; then
	target="$(printf '%s\n' "$@" | awk '/^(job|deployment|service|statefulset|pvc|ciliumnetworkpolicy|persistentvolume|volumes\.longhorn\.io)\// {print; exit}')"
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
	record_failure "valid detached pre-bind and attached post-mount lifecycle exited $status: $(tail -n 1 "$state/stderr.log")"
else
	pre="$(event_line observe-volume-pre "$state/events.log")"
	binding="$(event_line create-binding "$state/events.log")"
	app="$(event_line create-app "$state/events.log")"
	post="$(event_line observe-volume-post "$state/events.log")"
	request="$(event_line create-request "$state/events.log")"
	if ! ((pre < binding && binding < app && app < post && post < request)); then
		record_failure 'valid lifecycle did not gate binding before attach and the request consumer after attached health'
	fi
fi

for rejected_case in attached-before-bind wrong-backup wrong-size; do
	IFS=$'\t' read -r case_name status state < <(run_case "$rejected_case")
	[[ "$status" -ne 0 ]] || record_failure "$case_name was accepted before static binding"
	! rg -Fxq create-binding "$state/events.log" || record_failure "$case_name created the static binding"
	! rg -Fxq cleanup-failed "$state/events.log" || record_failure "$case_name failed cleanup"
done

IFS=$'\t' read -r case_name status state < <(run_case post-detached)
[[ "$status" -ne 0 ]] || record_failure 'post-detached volume was accepted after the application mount'
rg -Fxq create-app "$state/events.log" || record_failure 'post-detached did not reach the post-mount gate'
rg -Fxq observe-volume-post "$state/events.log" || record_failure 'post-detached was not observed after mount'
! rg -Fxq create-request "$state/events.log" || record_failure 'post-detached started the request consumer'
! rg -Fxq cleanup-failed "$state/events.log" || record_failure 'post-detached failed cleanup'

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

for rejected_case in missing-pvc mismatched-pv unavailable-target missing-backup incomplete-backup wrong-backup-size missing-backup-url cross-namespace-route; do
	IFS=$'\t' read -r case_name status state < <(run_case "$rejected_case")
	[[ "$status" -ne 0 ]] || record_failure "$case_name preflight was accepted"
	! rg -q '^(create-|delete )' "$state/events.log" || record_failure "$case_name preflight allowed a mutation"
done

for rejected_case in invalid-registry request-failure; do
	IFS=$'\t' read -r case_name status state < <(run_case "$rejected_case")
	[[ "$status" -ne 0 ]] || record_failure "$case_name was accepted"
	! rg -Fxq cleanup-failed "$state/events.log" || record_failure "$case_name failed cleanup"
	if [[ "$case_name" == invalid-registry ]]; then
		! rg -Fxq create-app "$state/events.log" || record_failure 'invalid registry started NocoDB'
	else
		rg -Fxq create-request "$state/events.log" || record_failure 'request failure did not reach the consumer'
	fi
done

[[ "$failures" -eq 0 ]] || exit 1
echo 'NocoDB restore scenario tests passed.'
