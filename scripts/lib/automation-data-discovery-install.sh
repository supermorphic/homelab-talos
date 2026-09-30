#!/usr/bin/env bash
# Operator installation guards. No credential values pass through shell output.

discovery_resource_owned() {
	[[ "$#" -eq 2 ]] || return 2
	RUN_ID="$2" yq -e '.metadata.labels."homelab-talos/run-id" == strenv(RUN_ID)' "$1" >/dev/null 2>&1
}

discovery_backup_ready() {
	discovery_resource_owned "$1" "$2" &&
		yq -e '([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length) == 1 and
      ([.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length) == 0' "$1" >/dev/null 2>&1
}

discovery_require_source() {
	require_deployed_source 'credential discovery installation' scripts/lib scripts/operations/automation-data-discovery-install.sh \
		scripts/test/lib/job.sh kubernetes/mod.just kubernetes/apps/automation-data/postgresql \
		kubernetes/apps/automation-data/nocodb kubernetes/apps/automation/n8n kubernetes/apps/automation/n8n-postgresql
}

discovery_require_lease() {
	[[ ! -e "$3/lease-failed" ]] && verify_test_lease_holder "$1" "$2"
}

# Installer Jobs print only their fixed final marker. Never fetch raw failure logs.
discovery_wait_job() {
	local kubeconfig="$1" namespace="$2" name="$3" timeout="$4" deadline="$((SECONDS + $4))" state
	while ((SECONDS < deadline)); do
		state="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job "$name" --output json)" || return 1
		if yq -e '([.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length) > 0' <<<"$state" >/dev/null; then
			echo 'Discovery installation Job failed; retain the protected installation receipt.' >&2
			return 1
		fi
		if yq -e '([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length) == 1' <<<"$state" >/dev/null; then return 0; fi
		sleep 2
	done
	echo "Discovery installation Job exceeded its $timeout second wait." >&2
	return 1
}
