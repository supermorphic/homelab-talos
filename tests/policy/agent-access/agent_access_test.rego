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

role(name, namespace, rules) := {
	"apiVersion": "rbac.authorization.k8s.io/v1",
	"kind": "Role",
	"metadata": {"name": name, "namespace": namespace},
	"rules": rules,
}

role_binding(name, namespace, service_account, service_account_namespace, role_name) := {
	"apiVersion": "rbac.authorization.k8s.io/v1",
	"kind": "RoleBinding",
	"metadata": {"name": name, "namespace": namespace},
	"roleRef": {
		"apiGroup": "rbac.authorization.k8s.io",
		"kind": "Role",
		"name": role_name,
	},
	"subjects": [{
		"kind": "ServiceAccount",
		"name": service_account,
		"namespace": service_account_namespace,
	}],
}

lease(name, namespace) := {
	"apiVersion": "coordination.k8s.io/v1",
	"kind": "Lease",
	"metadata": {"name": name, "namespace": namespace},
}

read_requirements := {
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
	service_account("homelab-report-publisher"),
	cluster_role_binding("homelab-observer-view", ["homelab-observer"], "view"),
	cluster_role_binding("homelab-diagnostic-view", ["homelab-diagnostic"], "view"),
	cluster_role("homelab-observer-extra", array.concat(
		[
			{"apiGroups": [""], "resources": ["pods/log"], "verbs": ["get"]},
			{"apiGroups": [""], "resources": ["nodes"], "verbs": ["get", "list", "watch"]},
		],
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
	role("homelab-report-publisher-test-reports", "test-reports", [
		{
			"apiGroups": ["apps"],
			"resources": ["deployments"],
			"resourceNames": ["test-reports"],
			"verbs": ["get", "list", "watch"],
		},
		{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list"]},
		{"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["create"]},
	]),
	role_binding(
		"homelab-report-publisher-test-reports",
		"test-reports",
		"homelab-report-publisher",
		"kube-system",
		"homelab-report-publisher-test-reports",
	),
	role("homelab-report-publisher-flux-system", "flux-system", [
		{
			"apiGroups": ["source.toolkit.fluxcd.io"],
			"resources": ["gitrepositories"],
			"resourceNames": ["flux-system"],
			"verbs": ["get"],
		},
		{
			"apiGroups": ["coordination.k8s.io"],
			"resources": ["leases"],
			"resourceNames": ["homelab-test-report-publish-lock"],
			"verbs": ["get", "update"],
		},
	]),
	role_binding(
		"homelab-report-publisher-flux-system",
		"flux-system",
		"homelab-report-publisher",
		"kube-system",
		"homelab-report-publisher-flux-system",
	),
	lease("homelab-test-report-publish-lock", "flux-system"),
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

test_publisher_service_account_is_required if {
	messages := deny with input as fixture_without("homelab-report-publisher")
	count(messages_matching(messages, "ServiceAccount homelab-report-publisher is missing")) == 1
}

test_publisher_report_role_rejects_secret_reads if {
	messages := deny with input as fixture_with_rule(
		"homelab-report-publisher-test-reports",
		[""],
		["secrets"],
		["get"],
	)
	count(messages_matching(messages, "publisher test-reports Role contains a forbidden RBAC rule")) == 1
}

test_publisher_report_role_rejects_port_forward if {
	messages := deny with input as fixture_with_rule(
		"homelab-report-publisher-test-reports",
		[""],
		["pods/portforward"],
		["create"],
	)
	count(messages_matching(messages, "publisher test-reports Role contains a forbidden RBAC rule")) == 1
}

test_publisher_report_role_rejects_general_mutation if {
	messages := deny with input as fixture_with_rule(
		"homelab-report-publisher-test-reports",
		[""],
		["configmaps"],
		["create"],
	)
	count(messages_matching(messages, "publisher test-reports Role contains a forbidden RBAC rule")) == 1
}

test_publisher_flux_role_rejects_lease_create if {
	messages := deny with input as fixture_with_rule(
		"homelab-report-publisher-flux-system",
		["coordination.k8s.io"],
		["leases"],
		["create"],
	)
	count(messages_matching(messages, "publisher flux-system Role contains a forbidden RBAC rule")) == 1
}

test_publisher_report_role_and_binding_reject_namespace_mutated_duplicates if {
	fixture_input := array.concat(combined_fixture, [
		{
			"path": "reviewer/misplaced-publisher-role.yaml",
			"contents": role("homelab-report-publisher-test-reports", "kube-system", [
				{
					"apiGroups": ["apps"],
					"resources": ["deployments"],
					"resourceNames": ["test-reports"],
					"verbs": ["get", "list", "watch"],
				},
				{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list"]},
				{"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["create"]},
			]),
		},
		{
			"path": "reviewer/misplaced-publisher-binding.yaml",
			"contents": role_binding(
				"homelab-report-publisher-test-reports",
				"kube-system",
				"homelab-report-publisher",
				"kube-system",
				"homelab-report-publisher-test-reports",
			),
		},
	])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "publisher Role homelab-report-publisher-test-reports must be in namespace test-reports")) == 1
	count(messages_matching(messages, "publisher RoleBinding homelab-report-publisher-test-reports must exactly bind the publisher in namespace test-reports")) == 1
	count(messages_matching(messages, "publisher Role homelab-report-publisher-test-reports must occur exactly once")) == 1
	count(messages_matching(messages, "publisher RoleBinding homelab-report-publisher-test-reports must occur exactly once")) == 1
}

test_publisher_report_role_and_binding_reject_exact_duplicates if {
	fixture_input := array.concat(valid_fixture, [
		role("homelab-report-publisher-test-reports", "test-reports", [
			{
				"apiGroups": ["apps"],
				"resources": ["deployments"],
				"resourceNames": ["test-reports"],
				"verbs": ["get", "list", "watch"],
			},
			{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list"]},
			{"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["create"]},
		]),
		role_binding(
			"homelab-report-publisher-test-reports",
			"test-reports",
			"homelab-report-publisher",
			"kube-system",
			"homelab-report-publisher-test-reports",
		),
	])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "publisher Role homelab-report-publisher-test-reports must occur exactly once")) == 1
	count(messages_matching(messages, "publisher RoleBinding homelab-report-publisher-test-reports must occur exactly once")) == 1
}

test_each_publisher_role_binding_must_be_exact if {
	fixture_input := array.concat(valid_fixture, [role_binding(
		"homelab-report-publisher-test-reports",
		"test-reports",
		"homelab-diagnostic",
		"kube-system",
		"homelab-report-publisher-test-reports",
	)])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "publisher RoleBinding homelab-report-publisher-test-reports must exactly bind the publisher in namespace test-reports")) == 1
}

test_publication_lease_is_precreated if {
	messages := deny with input as fixture_without("homelab-test-report-publish-lock")
	count(messages_matching(messages, "publication Lease flux-system/homelab-test-report-publish-lock is missing")) == 1
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

test_observer_requires_disruption_lease_reads if {
	messages := deny with input as fixture_without_api_group("homelab-observer-extra", "coordination.k8s.io")
	count(messages_matching(messages, "coordination.k8s.io")) == 1
}

test_observer_requires_longhorn_evidence_reads if {
	messages := deny with input as fixture_without_api_group("homelab-observer-extra", "longhorn.io")
	count(messages_matching(messages, "longhorn.io")) == 1
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
		"path": "/5/aggregationRule",
		"value": {"clusterRoleSelectors": [{"matchLabels": {"rbac.example.com/aggregate": "true"}}]},
	}])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "must not use aggregationRule")) == 1
}
