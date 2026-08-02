package homelab.agent_access

import rego.v1

service_account(name) := {
	"apiVersion": "v1",
	"kind": "ServiceAccount",
	"metadata": {"name": name, "namespace": "kube-system"},
}

cluster_role(name, rules) := {
	"apiVersion": "rbac.authorization.k8s.io/v1",
	"kind": "ClusterRole",
	"metadata": {"name": name},
	"rules": rules,
}

cluster_role_binding(name, service_accounts, role_name) := {
	"apiVersion": "rbac.authorization.k8s.io/v1",
	"kind": "ClusterRoleBinding",
	"metadata": {"name": name},
	"roleRef": {
		"apiGroup": "rbac.authorization.k8s.io",
		"kind": "ClusterRole",
		"name": role_name,
	},
	"subjects": [{
		"kind": "ServiceAccount",
		"name": service_account_name,
		"namespace": "kube-system",
	} |
		some service_account_name in service_accounts
	],
}

read_requirements := {
	"apiextensions.k8s.io": {"customresourcedefinitions"},
	"apiregistration.k8s.io": {"apiservices"},
	"aquasecurity.github.io": {"vulnerabilityreports"},
	"cert-manager.io": {"certificates", "clusterissuers"},
	"cilium.io": {"ciliumclusterwidenetworkpolicies", "ciliumendpoints", "ciliumendpointslices", "ciliumidentities", "ciliumnetworkpolicies", "ciliumnodes"},
	"gateway.networking.k8s.io": {"gatewayclasses", "gateways", "httproutes"},
	"gatus.io": {"endpoints"},
	"helm.toolkit.fluxcd.io": {"helmreleases"},
	"kustomize.toolkit.fluxcd.io": {"kustomizations"},
	"longhorn.io": {"backuptargets", "nodes", "recurringjobs", "volumes"},
	"metallb.io": {"ipaddresspools"},
	"metrics.k8s.io": {"nodes", "pods"},
	"monitoring.coreos.com": {"prometheusrules", "servicemonitors"},
	"notification.toolkit.fluxcd.io": {"alerts", "providers", "receivers"},
	"rbac.authorization.k8s.io": {"clusterrolebindings", "clusterroles", "rolebindings", "roles"},
	"source.toolkit.fluxcd.io": {"buckets", "gitrepositories", "helmcharts", "helmrepositories", "ocirepositories"},
	"storage.k8s.io": {"csidrivers", "storageclasses"},
	"tailscale.com": {"connectors", "dnsconfigs", "proxyclasses", "proxygroups"},
}

read_rules := [{
	"apiGroups": [api_group],
	"resources": [resource | some resource in resources],
	"verbs": ["get", "list", "watch"],
} |
	some api_group
	resources := read_requirements[api_group]
]

valid_fixture := [
	service_account("homelab-observer"),
	service_account("homelab-diagnostic"),
	cluster_role_binding("homelab-observer-view", ["homelab-observer"], "view"),
	cluster_role_binding("homelab-diagnostic-view", ["homelab-diagnostic"], "view"),
	cluster_role("homelab-observer-extra", array.concat(
		[{"apiGroups": [""], "resources": ["pods/log"], "verbs": ["get"]}],
		read_rules,
	)),
	cluster_role_binding(
		"homelab-observer-extra",
		["homelab-observer", "homelab-diagnostic"],
		"homelab-observer-extra",
	),
	cluster_role("homelab-diagnostic-extra", [{
		"apiGroups": [""],
		"resources": ["pods/exec", "pods/portforward"],
		"verbs": ["create"],
	}]),
	cluster_role_binding(
		"homelab-diagnostic-extra",
		["homelab-diagnostic"],
		"homelab-diagnostic-extra",
	),
]

combined_fixture := [{
	"path": "kubernetes/apps/kube-system/agent-access/app/rbac.yaml",
	"contents": document,
} |
	some document in valid_fixture
]

document_with_rule(document, role_name, rule) := object.union(
	document,
	{"rules": array.concat(object.get(document, "rules", []), [rule])},
) if {
	object.get(object.get(document, "metadata", {}), "name", "") == role_name
}

document_with_rule(document, role_name, _) := document if {
	object.get(object.get(document, "metadata", {}), "name", "") != role_name
}

fixture_with_rule(role_name, api_groups, resources, verbs) := [
document_with_rule(document, role_name, {
	"apiGroups": api_groups,
	"resources": resources,
	"verbs": verbs,
}) |
	some document in valid_fixture
]

document_without_api_group(document, role_name, api_group) := object.union(
	document,
	{"rules": [rule |
		some rule in object.get(document, "rules", [])
		object.get(rule, "apiGroups", []) != [api_group]
	]},
) if {
	object.get(object.get(document, "metadata", {}), "name", "") == role_name
}

document_without_api_group(document, role_name, _) := document if {
	object.get(object.get(document, "metadata", {}), "name", "") != role_name
}

fixture_without_api_group(role_name, api_group) := [
document_without_api_group(document, role_name, api_group) |
	some document in valid_fixture
]

fixture_without(name) := [
document |
	some document in valid_fixture
	object.get(object.get(document, "metadata", {}), "name", "") != name
]

messages_matching(messages, fragment) := {
message |
	some message in messages
	contains(message, fragment)
}

test_complete_valid_fixture_has_zero_denials if {
	messages := deny with input as valid_fixture
	count(messages) == 0
}

test_complete_combined_fixture_has_zero_denials if {
	messages := deny with input as combined_fixture
	count(messages) == 0
}

test_observer_receives_view if {
	messages := deny with input as fixture_without("homelab-observer-view")
	count(messages_matching(messages, "homelab-observer must be bound to view")) == 1
}

test_diagnostic_receives_view if {
	messages := deny with input as fixture_without("homelab-diagnostic-view")
	count(messages_matching(messages, "homelab-diagnostic must be bound to view")) == 1
}

test_observer_cannot_read_secrets if {
	messages := deny with input as fixture_with_rule("homelab-observer-extra", [""], ["secrets"], ["get"])
	count(messages) == 1
}

test_observer_cannot_exec if {
	messages := deny with input as fixture_with_rule("homelab-observer-extra", [""], ["pods/exec"], ["create"])
	count(messages) == 1
}

test_observer_cannot_receive_wildcard_custom_resources if {
	messages := deny with input as fixture_with_rule("homelab-observer-extra", ["metallb.io"], ["*"], ["get", "list", "watch"])
	count(messages) == 1
}

test_observer_requires_gateway_reads if {
	messages := deny with input as fixture_without_api_group("homelab-observer-extra", "gateway.networking.k8s.io")
	count(messages_matching(messages, "gateway.networking.k8s.io")) == 1
}

test_observer_requires_notification_flux_reads if {
	messages := deny with input as fixture_without_api_group("homelab-observer-extra", "notification.toolkit.fluxcd.io")
	count(messages_matching(messages, "notification.toolkit.fluxcd.io")) == 1
}

test_diagnostic_cannot_patch_flux if {
	messages := deny with input as fixture_with_rule("homelab-diagnostic-extra", ["kustomize.toolkit.fluxcd.io"], ["kustomizations"], ["patch"])
	count(messages) == 1
}

test_observer_cannot_receive_an_additional_binding if {
	fixture_input := array.concat(valid_fixture, [cluster_role_binding("backdoor", ["homelab-observer"], "cluster-admin")])
	messages := deny with input as fixture_input
	count(messages) == 1
}

test_expected_role_cannot_use_aggregation if {
	fixture_input := json.patch(valid_fixture, [{
		"op": "add",
		"path": "/4/aggregationRule",
		"value": {"clusterRoleSelectors": [{"matchLabels": {"rbac.example.com/aggregate": "true"}}]},
	}])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "must not use aggregationRule")) == 1
}
