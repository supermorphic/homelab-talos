package homelab.agent_access

import rego.v1

agent_role_names := {"homelab-observer-extra", "homelab-diagnostic-extra"}
publisher_role_names := {
	"homelab-report-publisher-flux-system",
	"homelab-report-publisher-test-reports",
}

publisher_role_namespace(role_name) := trim_prefix(role_name, "homelab-report-publisher-")

expected_document_names := {
	"ClusterRole": agent_role_names,
	"ClusterRoleBinding": {
		"homelab-observer-view",
		"homelab-diagnostic-view",
		"homelab-observer-extra",
		"homelab-diagnostic-extra",
	},
	"Lease": {"homelab-test-report-publish-lock"},
	"Role": publisher_role_names,
	"RoleBinding": publisher_role_names,
	"ServiceAccount": {"homelab-observer", "homelab-diagnostic", "homelab-report-publisher"},
}

required_read_rules := {
	"apiextensions.k8s.io": {"customresourcedefinitions"},
	"apiregistration.k8s.io": {"apiservices"},
	"aquasecurity.github.io": {"vulnerabilityreports"},
	"cert-manager.io": {"certificates", "clusterissuers"},
	"cilium.io": {"ciliumclusterwidenetworkpolicies", "ciliumendpoints", "ciliumidentities", "ciliumnetworkpolicies", "ciliumnodes"},
	"coordination.k8s.io": {"leases"},
	"externaldns.k8s.io": {"dnsendpoints"},
	"gateway.networking.k8s.io": {"gatewayclasses", "gateways", "httproutes", "referencegrants"},
	"helm.toolkit.fluxcd.io": {"helmreleases"},
	"kustomize.toolkit.fluxcd.io": {"kustomizations"},
	"longhorn.io": {"backuptargets", "nodes", "recurringjobs", "replicas", "settings", "volumes"},
	"metallb.io": {"ipaddresspools"},
	"metrics.k8s.io": {"nodes", "pods"},
	"monitoring.coreos.com": {"prometheusrules", "servicemonitors"},
	"notification.toolkit.fluxcd.io": {"alerts", "providers", "receivers"},
	"rbac.authorization.k8s.io": {"clusterrolebindings", "clusterroles", "rolebindings", "roles"},
	"scheduling.k8s.io": {"priorityclasses"},
	"source.toolkit.fluxcd.io": {"buckets", "gitrepositories", "helmcharts", "helmrepositories", "ocirepositories"},
	"storage.k8s.io": {"csidrivers", "storageclasses"},
	"tailscale.com": {"connectors", "dnsconfigs", "proxyclasses", "proxygroups"},
}

values_set(values) := {value | some value in values}

metadata_name(document) := object.get(object.get(document, "metadata", {}), "name", "")
metadata_namespace(document) := object.get(object.get(document, "metadata", {}), "namespace", "")

documents := [object.get(item, "contents", item) | some item in input]

has_service_account(name) if {
	some document in documents
	object.get(document, "kind", "") == "ServiceAccount"
	metadata_name(document) == name
	object.get(object.get(document, "metadata", {}), "namespace", "") == "kube-system"
}

binding_subjects(document) := {
sprintf("%s:%s:%s", [
	object.get(subject, "kind", ""),
	object.get(subject, "namespace", ""),
	object.get(subject, "name", ""),
]) |
	some subject in object.get(document, "subjects", [])
}

has_binding(name, role_name, subjects) if {
	some document in documents
	object.get(document, "kind", "") == "ClusterRoleBinding"
	metadata_name(document) == name
	role_ref := object.get(document, "roleRef", {})
	object.get(role_ref, "apiGroup", "") == "rbac.authorization.k8s.io"
	object.get(role_ref, "kind", "") == "ClusterRole"
	object.get(role_ref, "name", "") == role_name
	binding_subjects(document) == subjects
}

has_role_binding(name, namespace, role_name, subjects) if {
	some document in documents
	object.get(document, "kind", "") == "RoleBinding"
	metadata_name(document) == name
	metadata_namespace(document) == namespace
	role_ref := object.get(document, "roleRef", {})
	object.get(role_ref, "apiGroup", "") == "rbac.authorization.k8s.io"
	object.get(role_ref, "kind", "") == "Role"
	object.get(role_ref, "name", "") == role_name
	binding_subjects(document) == subjects
}

has_cluster_role(name) if {
	some document in documents
	object.get(document, "kind", "") == "ClusterRole"
	metadata_name(document) == name
}

has_role(name, namespace) if {
	some document in documents
	object.get(document, "kind", "") == "Role"
	metadata_name(document) == name
	metadata_namespace(document) == namespace
}

publisher_documents(kind, name) := [document |
	some document in documents
	object.get(document, "kind", "") == kind
	metadata_name(document) == name
]

publisher_role_binding_is_exact(document, role_name, namespace) if {
	metadata_namespace(document) == namespace
	role_ref := object.get(document, "roleRef", {})
	object.get(role_ref, "apiGroup", "") == "rbac.authorization.k8s.io"
	object.get(role_ref, "kind", "") == "Role"
	object.get(role_ref, "name", "") == role_name
	binding_subjects(document) == {"ServiceAccount:kube-system:homelab-report-publisher"}
}

rule_matches(rule, api_groups, resources, verbs) if {
	values_set(object.get(rule, "apiGroups", [])) == api_groups
	values_set(object.get(rule, "resources", [])) == resources
	values_set(object.get(rule, "verbs", [])) == verbs
}

rule_matches_named(rule, api_groups, resources, resource_names, verbs) if {
	rule_matches(rule, api_groups, resources, verbs)
	values_set(object.get(rule, "resourceNames", [])) == resource_names
}

allowed_rule("homelab-observer-extra", rule) if {
	rule_matches(rule, {""}, {"pods/log"}, {"get"})
}

allowed_rule("homelab-observer-extra", rule) if {
	rule_matches(rule, {""}, {"nodes"}, {"get", "list", "watch"})
}

allowed_rule("homelab-observer-extra", rule) if {
	some api_group
	resources := required_read_rules[api_group]
	rule_matches(rule, {api_group}, resources, {"get", "list", "watch"})
}

allowed_rule("homelab-diagnostic-extra", rule) if {
	rule_matches(rule, {""}, {"pods/exec", "pods/portforward"}, {"create"})
}

allowed_publisher_rule("homelab-report-publisher-test-reports", rule) if {
	rule_matches_named(rule, {"apps"}, {"deployments"}, {"test-reports"}, {"get", "list", "watch"})
}

allowed_publisher_rule("homelab-report-publisher-test-reports", rule) if {
	rule_matches_named(rule, {""}, {"pods"}, set(), {"get", "list"})
}

allowed_publisher_rule("homelab-report-publisher-test-reports", rule) if {
	rule_matches_named(rule, {""}, {"pods/exec"}, set(), {"create"})
}

allowed_publisher_rule("homelab-report-publisher-flux-system", rule) if {
	rule_matches_named(rule, {"source.toolkit.fluxcd.io"}, {"gitrepositories"}, {"flux-system"}, {"get"})
}

allowed_publisher_rule("homelab-report-publisher-flux-system", rule) if {
	rule_matches_named(
		rule,
		{"coordination.k8s.io"},
		{"leases"},
		{"homelab-test-report-publish-lock"},
		{"get", "update"},
	)
}

has_allowed_rule(role_name, api_groups, resources, verbs) if {
	some document in documents
	object.get(document, "kind", "") == "ClusterRole"
	metadata_name(document) == role_name
	some rule in object.get(document, "rules", [])
	rule_matches(rule, api_groups, resources, verbs)
}

deny contains msg if {
	some name in expected_document_names.ServiceAccount
	not has_service_account(name)
	msg := sprintf("required kube-system ServiceAccount %s is missing", [name])
}

deny contains "homelab-observer must be bound to view" if {
	not has_binding(
		"homelab-observer-view",
		"view",
		{"ServiceAccount:kube-system:homelab-observer"},
	)
}

deny contains "homelab-diagnostic must be bound to view" if {
	not has_binding(
		"homelab-diagnostic-view",
		"view",
		{"ServiceAccount:kube-system:homelab-diagnostic"},
	)
}

deny contains "observer extras must be bound to observer and diagnostic" if {
	not has_binding(
		"homelab-observer-extra",
		"homelab-observer-extra",
		{
			"ServiceAccount:kube-system:homelab-observer",
			"ServiceAccount:kube-system:homelab-diagnostic",
		},
	)
}

deny contains "diagnostic extras must be bound only to diagnostic" if {
	not has_binding(
		"homelab-diagnostic-extra",
		"homelab-diagnostic-extra",
		{"ServiceAccount:kube-system:homelab-diagnostic"},
	)
}

deny contains msg if {
	some role_name in publisher_role_names
	namespace := publisher_role_namespace(role_name)
	not has_role(role_name, namespace)
	msg := sprintf("required publisher Role %s/%s is missing", [namespace, role_name])
}

deny contains msg if {
	some role_name in publisher_role_names
	namespace := publisher_role_namespace(role_name)
	not has_role_binding(
		role_name,
		namespace,
		role_name,
		{"ServiceAccount:kube-system:homelab-report-publisher"},
	)
	msg := sprintf("publisher RoleBinding %s/%s must bind only the publisher ServiceAccount", [namespace, role_name])
}

deny contains msg if {
	some document in documents
	object.get(document, "kind", "") == "Role"
	role_name := metadata_name(document)
	role_name in publisher_role_names
	expected_namespace := publisher_role_namespace(role_name)
	metadata_namespace(document) != expected_namespace
	msg := sprintf("publisher Role %s must be in namespace %s", [role_name, expected_namespace])
}

deny contains msg if {
	some document in documents
	object.get(document, "kind", "") == "RoleBinding"
	role_name := metadata_name(document)
	role_name in publisher_role_names
	expected_namespace := publisher_role_namespace(role_name)
	not publisher_role_binding_is_exact(document, role_name, expected_namespace)
	msg := sprintf("publisher RoleBinding %s must exactly bind the publisher in namespace %s", [role_name, expected_namespace])
}

deny contains msg if {
	some role_name in publisher_role_names
	count(publisher_documents("Role", role_name)) > 1
	msg := sprintf("publisher Role %s must occur exactly once", [role_name])
}

deny contains msg if {
	some role_name in publisher_role_names
	count(publisher_documents("RoleBinding", role_name)) > 1
	msg := sprintf("publisher RoleBinding %s must occur exactly once", [role_name])
}

deny contains msg if {
	some role_name in agent_role_names
	not has_cluster_role(role_name)
	msg := sprintf("required ClusterRole %s is missing", [role_name])
}

deny contains "observer extras must grant only pod logs" if {
	not has_allowed_rule("homelab-observer-extra", {""}, {"pods/log"}, {"get"})
}

deny contains "observer extras must grant core node reads" if {
	not has_allowed_rule(
		"homelab-observer-extra",
		{""},
		{"nodes"},
		{"get", "list", "watch"},
	)
}

deny contains msg if {
	some api_group
	resources := required_read_rules[api_group]
	not has_allowed_rule("homelab-observer-extra", {api_group}, resources, {"get", "list", "watch"})
	msg := sprintf("observer extras must grant required %s reads", [api_group])
}

deny contains "diagnostic extras must grant only pod exec and port-forward" if {
	not has_allowed_rule(
		"homelab-diagnostic-extra",
		{""},
		{"pods/exec", "pods/portforward"},
		{"create"},
	)
}

deny contains "publisher test-reports Role must grant only named deployment rollout reads, Pod reads, and Pod exec" if {
	not has_publisher_rule(
		"homelab-report-publisher-test-reports",
		{"apps"},
		{"deployments"},
		{"test-reports"},
		{"get", "list", "watch"},
	)
}

deny contains "publisher test-reports Role must grant Pod get and list" if {
	not has_publisher_rule(
		"homelab-report-publisher-test-reports",
		{""},
		{"pods"},
		set(),
		{"get", "list"},
	)
}

deny contains "publisher test-reports Role must grant Pod exec" if {
	not has_publisher_rule(
		"homelab-report-publisher-test-reports",
		{""},
		{"pods/exec"},
		set(),
		{"create"},
	)
}

deny contains "publisher flux-system Role must grant only named Flux source get" if {
	not has_publisher_rule(
		"homelab-report-publisher-flux-system",
		{"source.toolkit.fluxcd.io"},
		{"gitrepositories"},
		{"flux-system"},
		{"get"},
	)
}

deny contains "publisher flux-system Role must grant only named publication Lease get and update" if {
	not has_publisher_rule(
		"homelab-report-publisher-flux-system",
		{"coordination.k8s.io"},
		{"leases"},
		{"homelab-test-report-publish-lock"},
		{"get", "update"},
	)
}

has_publisher_rule(role_name, api_groups, resources, resource_names, verbs) if {
	some document in documents
	object.get(document, "kind", "") == "Role"
	metadata_name(document) == role_name
	metadata_namespace(document) == publisher_role_namespace(role_name)
	some rule in object.get(document, "rules", [])
	rule_matches_named(rule, api_groups, resources, resource_names, verbs)
}

deny contains msg if {
	some document in documents
	object.get(document, "kind", "") == "Role"
	role_name := metadata_name(document)
	role_name in publisher_role_names
	some rule in object.get(document, "rules", [])
	not allowed_publisher_rule(role_name, rule)
	namespace := metadata_namespace(document)
	msg := sprintf("publisher %s Role contains a forbidden RBAC rule", [namespace])
}

deny contains msg if {
	some document in documents
	object.get(document, "kind", "") == "Role"
	role_name := metadata_name(document)
	role_name in publisher_role_names
	object.get(document, "aggregationRule", null) != null
	msg := sprintf("%s must not use aggregationRule", [role_name])
}

deny contains "publication Lease flux-system/homelab-test-report-publish-lock is missing or declares runtime spec" if {
	not publication_lease_is_precreated
}

publication_lease_is_precreated if {
	some document in documents
	object.get(document, "kind", "") == "Lease"
	metadata_name(document) == "homelab-test-report-publish-lock"
	metadata_namespace(document) == "flux-system"
	object.get(document, "spec", null) == null
}

deny contains msg if {
	some document in documents
	object.get(document, "kind", "") == "ClusterRole"
	role_name := metadata_name(document)
	role_name in agent_role_names
	object.get(document, "aggregationRule", null) != null
	msg := sprintf("%s must not use aggregationRule", [role_name])
}

deny contains msg if {
	some document in documents
	object.get(document, "kind", "") == "ClusterRole"
	role_name := metadata_name(document)
	role_name in agent_role_names
	some rule in object.get(document, "rules", [])
	not allowed_rule(role_name, rule)
	msg := sprintf("%s contains a forbidden RBAC rule", [role_name])
}

deny contains msg if {
	some document in documents
	kind := object.get(document, "kind", "")
	name := metadata_name(document)
	not expected_document_names[kind][name]
	msg := sprintf("unexpected agent-access %s %s", [kind, name])
}
