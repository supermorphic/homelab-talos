package homelab.media

import rego.v1

mutable_tags := {"latest", "main", "master", "stable", "nightly"}

required_dependencies := {
	"flaresolverr": {"media"},
	"lidarr": {"internal-gateway", "media-storage"},
	"plex": {"internal-gateway", "media-storage"},
	"prowlarr": {"internal-gateway", "media"},
	"qbit-manage": {"media-storage", "qbittorrent"},
	"qbittorrent": {"internal-gateway", "media-storage"},
	"radarr": {"internal-gateway", "media-storage"},
	"seerr": {"internal-gateway", "media"},
	"sonarr": {"internal-gateway", "media-storage"},
}

# Stateless, in-cluster-only apps: no persistent config to keep and no operator UI, so
# they are exempt from the config-PVC and HTTPRoute requirements ONLY. Every other rule
# (pinned image, drop-ALL caps, no NET_ADMIN, dependency ordering) still applies. FlareSolverr
# is a headless-Chromium Cloudflare solver Prowlarr reaches over cluster DNS on :8191.
stateless_internal_apps := {"flaresolverr"}

# UI-less scheduled workers: no persistent config, no operator UI/Service, and nothing
# connects to them, so they are exempt from the config-PVC and HTTPRoute requirements ONLY
# (like stateless_internal_apps). Every other rule (pinned image, drop-ALL caps, no
# NET_ADMIN, dependency ordering) still applies. qbit_manage is a qBittorrent seeding-policy
# scheduler that reaches qBittorrent's Web API over the internal Service.
uiless_worker_apps := {"qbit-manage"}

shared_claim_keys := {
	"lidarr": "data",
	"plex": "media",
	"qbittorrent": "data",
	"radarr": "data",
	"sonarr": "data",
}

config_only_apps := {"prowlarr", "seerr"}

media_app(document) := app if {
	endswith(document.path, "/app/values.yaml")
	parts := split(document.path, "/")
	app := parts[count(parts) - 3]
}

document_exists(suffix) if {
	some document in input
	endswith(document.path, suffix)
}

document_contents(suffix) := document.contents if {
	some document in input
	endswith(document.path, suffix)
}

containers(controller) := object.union(
	object.get(controller, "containers", {}),
	object.get(controller, "initContainers", {}),
)

dependency_names(kustomization) := {
name |
	some dependency in object.get(
		object.get(kustomization, "spec", {}),
		"dependsOn",
		[],
	)
	name := object.get(dependency, "name", "")
}

allowed_net_admin(app, controller, container) if {
	app == "qbittorrent"
	controller == "qbittorrent"
	container == "gluetun"
}

deny contains msg if {
	some document in input
	app := media_app(document)
	not required_dependencies[app]
	msg := sprintf("%s: media policy is undefined for app %q", [document.path, app])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	controllers := object.get(document.contents, "controllers", {})
	object.get(controllers, app, null) == null
	msg := sprintf("%s: expected controller %q is missing", [document.path, app])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	some controller_name, controller in object.get(document.contents, "controllers", {})
	some container_name, container in containers(controller)
	tag := object.get(object.get(container, "image", {}), "tag", null)
	tag == null
	msg := sprintf(
		"%s: %s/%s image tag is missing",
		[document.path, controller_name, container_name],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	some controller_name, controller in object.get(document.contents, "controllers", {})
	some container_name, container in containers(controller)
	tag := lower(sprintf("%v", [object.get(object.get(container, "image", {}), "tag", "")]))
	tag in mutable_tags
	msg := sprintf(
		"%s: %s/%s uses mutable image tag %q",
		[document.path, controller_name, container_name, tag],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	some controller_name, controller in object.get(document.contents, "controllers", {})
	some container_name, container in containers(controller)
	capabilities := object.get(object.get(container, "securityContext", {}), "capabilities", {})
	"NET_ADMIN" in object.get(capabilities, "add", [])
	not allowed_net_admin(app, controller_name, container_name)
	msg := sprintf(
		"%s: NET_ADMIN is forbidden for %s/%s; only qbittorrent/qbittorrent/gluetun is allowed",
		[document.path, controller_name, container_name],
	)
}

# Host namespaces defeat pod-level network/process isolation. The media namespace runs
# under privileged PSA (Gluetun needs NET_ADMIN + /dev/net/tun), so PSA does not block
# these — pin them here. No media workload has a legitimate need to join a host namespace.
host_namespaces := {"hostNetwork", "hostPID", "hostIPC"}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	some controller_name, controller in object.get(document.contents, "controllers", {})
	pod := object.get(controller, "pod", {})
	some namespace in host_namespaces
	object.get(pod, namespace, false) == true
	msg := sprintf(
		"%s: media workload %s/%s must not enable host namespace %s",
		[document.path, app, controller_name, namespace],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	controller := object.get(object.get(document.contents, "controllers", {}), app, {})
	app_container := object.get(object.get(controller, "containers", {}), "app", {})
	capabilities := object.get(object.get(app_container, "securityContext", {}), "capabilities", {})
	not "ALL" in object.get(capabilities, "drop", [])
	msg := sprintf("%s: %s application container must drop all Linux capabilities", [document.path, app])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	not app in stateless_internal_apps
	not app in uiless_worker_apps
	persistence := object.get(document.contents, "persistence", {})
	config := object.get(persistence, "config", {})
	mode := object.get(config, "accessMode", "")
	not mode in {"ReadWriteOnce", "ReadWriteOncePod"}
	msg := sprintf(
		"%s: config PVC must use ReadWriteOnce or ReadWriteOncePod, got %q",
		[document.path, mode],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	persistence := object.get(document.contents, "persistence", {})
	config := object.get(persistence, "config", {})
	mode := object.get(config, "accessMode", "")
	mode in {"ReadWriteOnce", "ReadWriteOncePod"}
	controller := object.get(object.get(document.contents, "controllers", {}), app, {})
	strategy := object.get(controller, "strategy", "")
	strategy != "Recreate"
	msg := sprintf(
		"%s: %s controller must use Recreate with config access mode %s, got %q",
		[document.path, app, mode, strategy],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required := required_dependencies[app]
	suffix := sprintf("/%s/ks.yaml", [app])
	not document_exists(suffix)
	msg := sprintf("%s: required Flux Kustomization source is missing", [suffix])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required := required_dependencies[app]
	ks := document_contents(sprintf("/%s/ks.yaml", [app]))
	actual := dependency_names(ks)
	some dependency in required
	not dependency in actual
	msg := sprintf("%s/ks.yaml: required Flux dependency %q is missing", [app, dependency])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	not app in stateless_internal_apps
	not app in uiless_worker_apps
	suffix := sprintf("/%s/app/httproute.yaml", [app])
	not document_exists(suffix)
	msg := sprintf("%s: required HTTPRoute source is missing", [suffix])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	route := document_contents(sprintf("/%s/app/httproute.yaml", [app]))
	parent_refs := object.get(object.get(route, "spec", {}), "parentRefs", [])
	count(parent_refs) == 0
	msg := sprintf("%s/app/httproute.yaml: at least one Gateway parentRef is required", [app])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	route := document_contents(sprintf("/%s/app/httproute.yaml", [app]))
	some parent in object.get(object.get(route, "spec", {}), "parentRefs", [])
	name := object.get(parent, "name", "")
	name != "internal"
	msg := sprintf(
		"%s/app/httproute.yaml: Gateway parentRef must be internal, got %q",
		[app, name],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	required_dependencies[app]
	route := document_contents(sprintf("/%s/app/httproute.yaml", [app]))
	annotations := object.get(object.get(route, "metadata", {}), "annotations", {})
	audience := object.get(annotations, "external-dns.k8s.io/audience", "")
	audience != "internal"
	msg := sprintf(
		"%s/app/httproute.yaml: external-dns audience must be internal, got %q",
		[app, audience],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	claim_key := shared_claim_keys[app]
	persistence := object.get(document.contents, "persistence", {})
	claim := object.get(object.get(persistence, claim_key, {}), "existingClaim", "")
	claim != "media-data"
	msg := sprintf(
		"%s: persistence.%s.existingClaim must be media-data, got %q",
		[document.path, claim_key, claim],
	)
}

deny contains msg if {
	some document in input
	app := media_app(document)
	app in config_only_apps
	persistence := object.get(document.contents, "persistence", {})
	object.get(persistence, "data", null) != null
	msg := sprintf("%s: %s is config-only and must not define persistence.data", [document.path, app])
}

deny contains msg if {
	some document in input
	app := media_app(document)
	app in config_only_apps
	persistence := object.get(document.contents, "persistence", {})
	object.get(persistence, "media", null) != null
	msg := sprintf("%s: %s is config-only and must not define persistence.media", [document.path, app])
}
