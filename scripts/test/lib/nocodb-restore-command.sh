#!/usr/bin/env bash

nocodb_restore_preflight_manifest() { # <job-name> <run-hash>
	local job_name="$1" run_hash="$2"
	JOB_NAME="$job_name" RUN_HASH="$run_hash" \
		yq --null-input --output-format yaml '
      {
        "apiVersion":"batch/v1", "kind":"Job",
        "metadata":{"name":strenv(JOB_NAME),"namespace":"automation-data","labels":{
          "homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"preflight"
        }},
        "spec":{"activeDeadlineSeconds":300,"backoffLimit":0,"template":{
          "metadata":{"labels":{"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH),"homelab-talos/role":"preflight"}},
          "spec":{"automountServiceAccountToken":false,"restartPolicy":"Never",
            "securityContext":{"fsGroup":70,"fsGroupChangePolicy":"OnRootMismatch","runAsNonRoot":true,"runAsUser":70,"runAsGroup":70,"seccompProfile":{"type":"RuntimeDefault"}},
            "containers":[{
              "name":"preflight","image":"postgres:17.11-alpine3.24","imagePullPolicy":"IfNotPresent",
              "command":["/bin/sh","-eu","/helpers/nocodb-restore-preflight.sh"],
              "env":[{"name":"BACKUP_DIR","value":"/backups"}],
              "resources":{"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"memory":"256Mi"}},
              "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true},
              "volumeMounts":[{"name":"backups","mountPath":"/backups","readOnly":true},{"name":"tmp","mountPath":"/tmp"},{"name":"helpers","mountPath":"/helpers","readOnly":true}]
            }],
            "volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"automation-data-postgresql-backups","readOnly":true}},{"name":"tmp","emptyDir":{}},{"name":"helpers","configMap":{"name":"automation-data-test-helpers-v1"}}]
          }
        }}
      }
    '
}

nocodb_restore_request_script() {
  cat kubernetes/apps/automation-data/nocodb/app/test-helpers/nocodb-restore-request.mjs
}

nocodb_restore_bundle_is_complete() { # <bundle-directory>
	local candidate="$1" candidate_name expected_files actual_files
	candidate_name="$(basename "$candidate")"
	[[ "$candidate_name" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ ]] || return 1
	[[ -s "$candidate/globals.sql" && -s "$candidate/registry.tsv" &&
		-s "$candidate/manifest.tsv" && -s "$candidate/SHA256SUMS" &&
		-s "$candidate/COMPLETE" ]] || return 1
	(cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null 2>&1 &&
		sha256sum -c COMPLETE >/dev/null 2>&1) || return 1

	expected_files="$(mktemp "${TMPDIR:-/tmp}/nocodb-restore-expected.XXXXXX")"
	actual_files="$(mktemp "${TMPDIR:-/tmp}/nocodb-restore-actual.XXXXXX")"
	awk 'NF == 2 {print $2}' "$candidate/SHA256SUMS" | LC_ALL=C sort -u >"$expected_files"
	printf '%s\n' COMPLETE SHA256SUMS >>"$expected_files"
	LC_ALL=C sort -u -o "$expected_files" "$expected_files"
	(cd "$candidate" && find . -type f -print | sed 's#^./##' | LC_ALL=C sort -u) \
		>"$actual_files"
	cmp -s "$expected_files" "$actual_files"
	local result="$?"
	rm -f -- "$expected_files" "$actual_files"
	return "$result"
}

nocodb_restore_select_complete_bundle() { # <backup-directory>
	local backup_dir="$1" candidate
	[[ -d "$backup_dir" ]] || return 1
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		if nocodb_restore_bundle_is_complete "$candidate"; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done < <(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d \
		-name 'automation-data-*' -print | LC_ALL=C sort -r)
	return 1
}

nocodb_restore_validate_source_registry() { # <registry-json>
	local registry_json="$1"
	jq -e '
    (.items | type) == "array" and
    (.items | length) >= 2 and
    (.items | all(
      .domain == "automation_data_acceptance" and
      (.pair | type == "string" and (. == "default" or test("^[a-z][a-z0-9_]{0,23}$"))) and
      (.accessKind == "reader" or .accessKind == "operator") and
      .state == "ready" and .valid == true and
      (.baseId | type == "string" and length > 0) and
      (.sourceId | type == "string" and length > 0) and
      (.integrationId | type == "string" and length > 0)
    )) and
    ([.items[] | select(.pair == "default" and .accessKind == "reader")] | length) == 1 and
    ([.items[] | select(.pair == "default" and .accessKind == "operator")] | length) == 1 and
    (.items | group_by(.pair) | all(
      (map(select(.accessKind == "reader")) | length) == 1 and
      (map(select(.accessKind == "operator")) | length) <= 1 and
      (map(.baseId) | unique | length) == 1
    )) and
    ([.items[].baseId] | unique | length) == ([.items[].pair] | unique | length) and
    ([.items[].sourceId] | unique | length) == (.items | length) and
    ([.items[].integrationId] | unique | length) == (.items | length)
  ' "$registry_json" >/dev/null
}

nocodb_restore_application_manifests() { # <app> <service> <database-ip> <run-hash>
	local app_name="$1" service_name="$2" database_ip="$3" run_hash="$4"
	# shellcheck disable=SC2016 # yq evaluates its own variables.
	APP_NAME="$app_name" SERVICE_NAME="$service_name" DATABASE_IP="$database_ip" RUN_HASH="$run_hash" \
		yq --null-input --output-format yaml '
      {
        "homelab-talos/test":"nocodb-restore-drill",
        "homelab-talos/run-id":strenv(RUN_HASH),
        "homelab-talos/role":"nocodb"
      } as $labels |
      [
        {
          "apiVersion":"v1", "kind":"Service",
          "metadata":{"name":strenv(SERVICE_NAME),"namespace":"automation-data","labels":$labels},
          "spec":{"type":"ClusterIP","selector":$labels,"ports":[{"name":"http","port":8080,"targetPort":"http"}]}
        },
        {
          "apiVersion":"apps/v1", "kind":"Deployment",
          "metadata":{"name":strenv(APP_NAME),"namespace":"automation-data","labels":$labels},
          "spec": {
            "replicas":1, "strategy":{"type":"Recreate"}, "selector":{"matchLabels":$labels},
            "template":{"metadata":{"labels":$labels},"spec": {
              "automountServiceAccountToken":false,
              "hostAliases":[{"ip":strenv(DATABASE_IP),"hostnames":[
                "automation-data-postgresql",
                "automation-data-postgresql.automation-data.svc.cluster.local"
              ]}],
              "securityContext":{"fsGroup":1000,"fsGroupChangePolicy":"OnRootMismatch","seccompProfile":{"type":"RuntimeDefault"}},
              "containers":[{
                "name":"nocodb",
                "image":"docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9",
                "imagePullPolicy":"IfNotPresent", "ports":[{"name":"http","containerPort":8080}],
                "env":[
                  {"name":"DATABASE_URL","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"DATABASE_URL"}}},
                  {"name":"NC_AUTH_JWT_SECRET","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"NC_AUTH_JWT_SECRET"}}},
                  {"name":"NC_CONNECTION_ENCRYPT_KEY","valueFrom":{"secretKeyRef":{"name":"nocodb-credentials","key":"NC_CONNECTION_ENCRYPT_KEY"}}},
                  {"name":"NC_SITE_URL","value":("http://" + strenv(SERVICE_NAME) + ".automation-data.svc.cluster.local:8080")},
                  {"name":"NC_ALLOW_LOCAL_EXTERNAL_DBS","value":"true"},
                  {"name":"NC_DISABLE_TELE","value":"true"},
                  {"name":"NC_DISABLE_SUPPORT_CHAT","value":"true"}
                ],
                "readinessProbe":{"httpGet":{"path":"/api/v1/health","port":"http"},"periodSeconds":5,"failureThreshold":120},
                "resources":{"requests":{"cpu":"50m","memory":"256Mi"},"limits":{"memory":"1Gi"}},
                "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"runAsUser":1000,"runAsGroup":1000},
                "volumeMounts":[{"name":"data","mountPath":"/usr/app/data"},{"name":"tmp","mountPath":"/tmp"}]
              }],
              "volumes":[{"name":"data","emptyDir":{}},{"name":"tmp","emptyDir":{}}]
            }}
          }
        }
      ] | .[] | split_doc
    '
}

nocodb_restore_policy_manifest() { # <policy> <database> <app> <request> <run-hash>
	local policy_name="$1" database_name="$2" app_name="$3" request_name="$4" run_hash="$5"
	# shellcheck disable=SC2016 # yq evaluates its own variables.
	POLICY_NAME="$policy_name" DATABASE_NAME="$database_name" APP_NAME="$app_name" \
		REQUEST_NAME="$request_name" RUN_HASH="$run_hash" \
		yq --null-input --output-format yaml '
      {"homelab-talos/test":"nocodb-restore-drill","homelab-talos/run-id":strenv(RUN_HASH)} as $run |
      {"toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s:k8s-app":"kube-dns"}}],"toPorts":[{"ports":[{"port":"53","protocol":"TCP"},{"port":"53","protocol":"UDP"}]}]} as $dns |
      {
        "apiVersion":"cilium.io/v2", "kind":"CiliumNetworkPolicy",
        "metadata":{"name":strenv(POLICY_NAME),"namespace":"automation-data","labels":($run * {"homelab-talos/role":"policy"})},
        "specs":[
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"database"})},"ingress":[{"fromEndpoints":[
            {"matchLabels":($run * {"homelab-talos/role":"restore"})},
            {"matchLabels":($run * {"homelab-talos/role":"nocodb"})}
          ],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}],"egress":[]},
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"restore"})},"ingress":[],"egress":[$dns,{"toEndpoints":[{"matchLabels":($run * {"homelab-talos/role":"database"})}],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}]},
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"nocodb"})},"ingress":[{"fromEndpoints":[
            {"matchLabels":($run * {"homelab-talos/role":"request"})}
          ],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]}],"egress":[$dns,{"toEndpoints":[{"matchLabels":($run * {"homelab-talos/role":"database"})}],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}]},
          {"endpointSelector":{"matchLabels":($run * {"homelab-talos/role":"request"})},"ingress":[],"egress":[$dns,{"toEndpoints":[{"matchLabels":($run * {"homelab-talos/role":"nocodb"})}],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]}]}
        ]
      }
    '
}

nocodb_restore_validate_isolation() { # <app-yaml> <policy-yaml> <database-ip> <run-hash>
	local app_yaml="$1" policy_yaml="$2" database_ip="$3" run_hash="$4"
	DATABASE_IP="$database_ip" RUN_HASH="$run_hash" yq ea -e '
    select(.kind == "Deployment") |
    .spec.replicas == 1 and .spec.strategy.type == "Recreate" and
    .spec.template.metadata.labels."homelab-talos/test" == "nocodb-restore-drill" and
    .spec.template.metadata.labels."homelab-talos/run-id" == strenv(RUN_HASH) and
    (.spec.template.spec.hostAliases | length) == 1 and
    .spec.template.spec.hostAliases[0].ip == strenv(DATABASE_IP) and
    (.spec.template.spec.hostAliases[0].hostnames | length) == 2 and
    .spec.template.spec.hostAliases[0].hostnames[0] == "automation-data-postgresql" and
    .spec.template.spec.hostAliases[0].hostnames[1] == "automation-data-postgresql.automation-data.svc.cluster.local" and
    (.spec.template.spec.containers | length) == 1 and
    .spec.template.spec.containers[0].image == "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"
  ' "$app_yaml" >/dev/null || return 1

	# shellcheck disable=SC2016 # yq evaluates its own variables.
	yq ea -e '
    select(.kind == "Deployment") | [
      ([.spec.template.spec.volumes[]? | select(has("persistentVolumeClaim"))] | length) == 0,
      ([.spec.template.spec.volumes[]? | select(.name == "data" and (.emptyDir | type) == "!!map" and (.emptyDir | length) == 0)] | length) == 1,
      ([.spec.template.spec.volumes[]? | select(.name == "tmp" and (.emptyDir | type) == "!!map" and (.emptyDir | length) == 0)] | length) == 1,
      ([.spec.template.spec.containers[0].volumeMounts[]? | [.name, .mountPath] | join("=")] | sort | join(",")) == "data=/usr/app/data,tmp=/tmp",
      ([.spec.template.spec.containers[0].env[]? | select(.name == "NC_SECURE_ATTACHMENTS")] | length) == 0,
      ([.spec.template.spec.containers[0].env[]? | select(
        .name == "DATABASE_URL" and .valueFrom.secretKeyRef.name == "nocodb-credentials" and
        .valueFrom.secretKeyRef.key == "DATABASE_URL"
      )] | length) == 1,
      ([.spec.template.spec.containers[0].env[]? | select(
        .name == "NC_AUTH_JWT_SECRET" and .valueFrom.secretKeyRef.name == "nocodb-credentials" and
        .valueFrom.secretKeyRef.key == "NC_AUTH_JWT_SECRET"
      )] | length) == 1,
      ([.spec.template.spec.containers[0].env[]? | select(
        .name == "NC_CONNECTION_ENCRYPT_KEY" and .valueFrom.secretKeyRef.name == "nocodb-credentials" and
        .valueFrom.secretKeyRef.key == "NC_CONNECTION_ENCRYPT_KEY"
      )] | length) == 1
    ] | all
  ' "$app_yaml" >/dev/null || return 1

	# shellcheck disable=SC2016 # yq evaluates its own variables.
	RUN_HASH="$run_hash" yq -e '
    .kind == "CiliumNetworkPolicy" and .metadata.namespace == "automation-data" and
    .metadata.labels."homelab-talos/test" == "nocodb-restore-drill" and
    .metadata.labels."homelab-talos/run-id" == strenv(RUN_HASH) and
    (.specs | length) == 4 and
    ([.specs[].endpointSelector.matchLabels."homelab-talos/role"] | sort | join(",")) == "database,nocodb,request,restore" and
    ([.specs[] | select(.endpointSelector.matchLabels."homelab-talos/test" != "nocodb-restore-drill" or .endpointSelector.matchLabels."homelab-talos/run-id" != strenv(RUN_HASH))] | length) == 0 and
    ([.specs[] | select((.endpointSelector.matchLabels | length) != 3)] | length) == 0 and
    ([.specs[].ingress[]?.fromEndpoints[]? | select(
      (.matchLabels | length) != 3 or
      .matchLabels."homelab-talos/test" != "nocodb-restore-drill" or
      .matchLabels."homelab-talos/run-id" != strenv(RUN_HASH)
    )] | length) == 0 and
    ([.specs[].egress[]?.toEndpoints[]? | select(
      ((.matchLabels | length) != 2 or
       .matchLabels."k8s:io.kubernetes.pod.namespace" != "kube-system" or
       .matchLabels."k8s:k8s-app" != "kube-dns") and
      ((.matchLabels | length) != 3 or
       .matchLabels."homelab-talos/test" != "nocodb-restore-drill" or
       .matchLabels."homelab-talos/run-id" != strenv(RUN_HASH))
    )] | length) == 0 and
    ([.. | select(tag == "!!map") | select(has("toCIDR") or has("toCIDRSet") or has("toEntities") or has("toFQDNs"))] | length) == 0 and
    ([.specs[] as $destination | $destination.ingress[]? as $rule |
      $rule.fromEndpoints[]? as $source | $rule.toPorts[]?.ports[]? |
      (($source.matchLabels."homelab-talos/role" // "") + ">" + $destination.endpointSelector.matchLabels."homelab-talos/role" + ":" + .port + "/" + .protocol)
    ] | sort | join(",")) == "nocodb>database:5432/TCP,request>nocodb:8080/TCP,restore>database:5432/TCP" and
    ([.specs[] as $source | $source.egress[]? as $rule |
      $rule.toEndpoints[]? as $destination | $rule.toPorts[]?.ports[]? |
      ($source.endpointSelector.matchLabels."homelab-talos/role" + ">" +
        ($destination.matchLabels."homelab-talos/role" // ($destination.matchLabels."k8s:k8s-app" // "")) +
        ":" + .port + "/" + .protocol)
    ] | sort | join(",")) == "nocodb>database:5432/TCP,nocodb>kube-dns:53/TCP,nocodb>kube-dns:53/UDP,request>kube-dns:53/TCP,request>kube-dns:53/UDP,request>nocodb:8080/TCP,restore>database:5432/TCP,restore>kube-dns:53/TCP,restore>kube-dns:53/UDP"
  ' "$policy_yaml" >/dev/null
}

nocodb_restore_resource_is_owned() { # <run-hash> <resource-json>
	local run_hash="$1" resource_json="$2"
	RUN_HASH="$run_hash" jq -e '
    .metadata.labels."homelab-talos/test" == "nocodb-restore-drill" and
    .metadata.labels."homelab-talos/run-id" == env.RUN_HASH
  ' "$resource_json" >/dev/null
}
