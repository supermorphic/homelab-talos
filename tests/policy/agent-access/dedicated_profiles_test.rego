package homelab.agent_access

import rego.v1

dedicated_identity_fixture := array.concat(
	[
	object.union(service_account(name), {"automountServiceAccountToken": false}) |
		some name in {
			"homelab-test-flux-restart", "homelab-test-cilium-connectivity",
			"homelab-test-node-reschedule", "homelab-test-conformance",
			"homelab-test-openbao-issuance", "homelab-test-openbao-ha",
			"homelab-test-openbao-restore", "homelab-test-openbao-lifecycle",
		}
	],
	[cluster_role_binding("homelab-test-conformance", ["homelab-test-conformance"], "cluster-admin")],
)

test_dedicated_account_cannot_automount_token if {
	fixture := runner_change("ServiceAccount", "homelab-test-openbao-issuance", [{"op": "replace", "path": "/automountServiceAccountToken", "value": true}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_dedicated_account_cannot_reference_secret if {
	fixture := runner_change("ServiceAccount", "homelab-test-openbao-ha", [{"op": "add", "path": "/secrets", "value": [{"name": "runtime-credential"}]}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_conformance_cannot_grant_administrator_to_ordinary_runner if {
	fixture := runner_change("ClusterRoleBinding", "homelab-test-conformance", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-runner"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_dedicated_account_must_be_precreated if {
	messages := deny with input as fixture_without("homelab-test-openbao-lifecycle")
	count(messages) > 0
}

test_conformance_binding_cannot_be_removed if {
	messages := deny with input as fixture_without("homelab-test-conformance")
	count(messages) > 0
}

dedicated_flux_fixture := [
	cluster_role_binding("homelab-test-flux-restart-view", ["homelab-test-flux-restart"], "view"),
	cluster_role_binding("homelab-test-flux-restart-observation", ["homelab-test-flux-restart"], "homelab-observer-extra"),
	role("homelab-test-flux-restart", "flux-system", [
		{"apiGroups": ["apps"], "resources": ["deployments"], "resourceNames": ["source-controller", "kustomize-controller", "helm-controller", "notification-controller"], "verbs": ["patch", "update"]},
		{"apiGroups": ["source.toolkit.fluxcd.io"], "resources": ["gitrepositories"], "resourceNames": ["flux-system"], "verbs": ["patch", "update"]},
		{"apiGroups": ["kustomize.toolkit.fluxcd.io"], "resources": ["kustomizations"], "resourceNames": ["flux-canary", "cluster-apps"], "verbs": ["patch", "update"]},
	]),
	role_binding("homelab-test-flux-restart", "flux-system", "homelab-test-flux-restart", "kube-system", "homelab-test-flux-restart"),
	flux_guard("homelab-test-flux-restart", [{"apiGroups": ["apps"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["deployments"]}]),
	flux_guard("homelab-test-flux-restart-reconcile", [
		{"apiGroups": ["source.toolkit.fluxcd.io"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["gitrepositories"]},
		{"apiGroups": ["kustomize.toolkit.fluxcd.io"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["kustomizations"]},
	]),
	flux_guard_binding("homelab-test-flux-restart"),
	flux_guard_binding("homelab-test-flux-restart-reconcile"),
]

flux_guard(name, rules) := {
	"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": name},
	"spec": {
		"failurePolicy": "Fail", "matchConstraints": {"resourceRules": rules},
		"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-flux-restart'"}],
		"validations": [{"expression": "object.metadata.name == 'fixture'"}],
	},
}

flux_guard_binding(name) := {
	"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicyBinding", "metadata": {"name": name},
	"spec": {"policyName": name, "validationActions": ["Deny"]},
}

test_flux_restart_cannot_receive_unbounded_deployment_patch if {
	fixture := runner_change("Role", "homelab-test-flux-restart", [{"op": "remove", "path": "/rules/0/resourceNames"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_flux_restart_cannot_receive_other_profile_observation if {
	fixture := runner_change("ClusterRoleBinding", "homelab-test-flux-restart-view", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-openbao-issuance"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_flux_restart_requires_template_patch_guard if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-flux-restart"]]
	count(messages) > 0
}

dedicated_node_fixture := [
	cluster_role("homelab-test-node-scheduling", [{"apiGroups": [""], "resources": ["nodes"], "resourceNames": ["nuc1", "nuc2", "nuc3"], "verbs": ["patch"]}]),
	cluster_role_binding("homelab-test-node-scheduling", ["homelab-test-node-reschedule"], "homelab-test-node-scheduling"),
	cluster_role_binding("homelab-test-node-reschedule-view", ["homelab-test-node-reschedule"], "view"),
	cluster_role_binding("homelab-test-node-reschedule-observation", ["homelab-test-node-reschedule"], "homelab-observer-extra"),
	role("homelab-test-node-reschedule-runtime", "media", [
		{"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]},
		{"apiGroups": [""], "resources": ["pods"], "verbs": ["delete"]},
	]),
	role_binding("homelab-test-node-reschedule-runtime", "media", "homelab-test-node-reschedule", "kube-system", "homelab-test-node-reschedule-runtime"),
	node_guard("homelab-test-node-scheduling", "UPDATE", "nodes"),
	node_guard("homelab-test-node-plex-runtime", "CONNECT", "pods/exec"),
	node_guard("homelab-test-node-plex-disruption", "DELETE", "pods"),
	flux_guard_binding("homelab-test-node-scheduling"),
	flux_guard_binding("homelab-test-node-plex-runtime"),
	flux_guard_binding("homelab-test-node-plex-disruption"),
]

node_guard(name, operation, resource) := {
	"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": name},
	"spec": {
		"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": [operation], "resources": [resource]}]},
		"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-node-reschedule'"}],
		"validations": [{"expression": "object.metadata.name == 'fixture'"}],
	},
}

test_node_scheduling_cannot_patch_unnamed_nodes if {
	fixture := runner_change("ClusterRole", "homelab-test-node-scheduling", [{"op": "remove", "path": "/rules/0/resourceNames"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_node_scheduling_cannot_receive_other_profile_subject if {
	fixture := runner_change("ClusterRoleBinding", "homelab-test-node-scheduling", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-runner"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_node_scheduling_cluster_role_cannot_be_removed if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ClusterRole", "homelab-test-node-scheduling"]]
	count(messages) > 0
}

test_node_scheduling_guard_cannot_be_removed if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-node-scheduling"]]
	count(messages) > 0
}

dedicated_member_fixture := [
	cluster_role_binding("homelab-test-openbao-ha-view", ["homelab-test-openbao-ha"], "view"),
	cluster_role_binding("homelab-test-openbao-ha-observation", ["homelab-test-openbao-ha"], "homelab-observer-extra"),
	cluster_role_binding("homelab-test-openbao-lifecycle-view", ["homelab-test-openbao-lifecycle"], "view"),
	cluster_role_binding("homelab-test-openbao-lifecycle-observation", ["homelab-test-openbao-lifecycle"], "homelab-observer-extra"),
	role("homelab-test-openbao-member-tunnels", "openbao", [{"apiGroups": [""], "resources": ["pods/portforward"], "resourceNames": ["openbao-0", "openbao-1", "openbao-2"], "verbs": ["get", "create"]}]),
	{
		"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {"name": "homelab-test-openbao-member-tunnels", "namespace": "openbao"},
		"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "homelab-test-openbao-member-tunnels"},
		"subjects": [
			{"kind": "ServiceAccount", "name": "homelab-test-openbao-ha", "namespace": "kube-system"},
			{"kind": "ServiceAccount", "name": "homelab-test-openbao-lifecycle", "namespace": "kube-system"},
		],
	},
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-openbao-member-tunnels"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/portforward"]}]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username in ['system:serviceaccount:kube-system:homelab-test-openbao-ha', 'system:serviceaccount:kube-system:homelab-test-openbao-lifecycle']"}],
			"validations": [{"expression": "object.ports == [8200]"}],
		},
	},
	flux_guard_binding("homelab-test-openbao-member-tunnels"),
]

test_member_tunnels_cannot_include_debugger_subject if {
	fixture := runner_change("RoleBinding", "homelab-test-openbao-member-tunnels", [{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "homelab-diagnostic", "namespace": "kube-system"}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_member_tunnels_cannot_forward_unnamed_pods if {
	fixture := runner_change("Role", "homelab-test-openbao-member-tunnels", [{"op": "remove", "path": "/rules/0/resourceNames"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_member_tunnels_cannot_add_issuer_exec if {
	fixture := fixture_with_rule("homelab-test-openbao-member-tunnels", [""], ["pods/exec"], ["get", "create"])
	messages := deny with input as fixture
	count(messages) > 0
}

test_member_tunnels_cannot_remove_connect_guard if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-openbao-member-tunnels"]]
	count(messages) > 0
}

dedicated_ha_eviction_fixture := [
	role("homelab-test-openbao-ha-eviction", "openbao", [{"apiGroups": [""], "resources": ["pods/eviction"], "resourceNames": ["openbao-0", "openbao-1", "openbao-2"], "verbs": ["create"]}]),
	role_binding("homelab-test-openbao-ha-eviction", "openbao", "homelab-test-openbao-ha", "kube-system", "homelab-test-openbao-ha-eviction"),
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-openbao-ha-eviction"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["pods/eviction"]}]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-ha'"}],
			"validations": [{"expression": "object.kind == 'Eviction'"}],
		},
	},
	flux_guard_binding("homelab-test-openbao-ha-eviction"),
]

test_ha_eviction_cannot_bind_lifecycle if {
	fixture := runner_change("RoleBinding", "homelab-test-openbao-ha-eviction", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-openbao-lifecycle"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_ha_eviction_cannot_gain_production_pod_deletion if {
	fixture := fixture_with_rule("homelab-test-openbao-ha-eviction", [""], ["pods"], ["delete"])
	messages := deny with input as fixture
	count(messages) > 0
}

test_ha_eviction_cannot_lose_named_subresource_scope if {
	fixture := runner_change("Role", "homelab-test-openbao-ha-eviction", [{"op": "remove", "path": "/rules/0/resourceNames"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_ha_eviction_cannot_remove_guard if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-openbao-ha-eviction"]]
	count(messages) > 0
}

dedicated_probe_fixture := [
	cluster_role_binding("homelab-test-openbao-issuance-view", ["homelab-test-openbao-issuance"], "view"),
	cluster_role_binding("homelab-test-openbao-issuance-observation", ["homelab-test-openbao-issuance"], "homelab-observer-extra"),
	role("homelab-test-openbao-acceptance-runtime", "openbao-acceptance", [
		{"apiGroups": [""], "resources": ["pods"], "verbs": ["create", "delete"]},
		{"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]},
	]),
	{
		"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {"name": "homelab-test-openbao-acceptance-runtime", "namespace": "openbao-acceptance"},
		"roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "homelab-test-openbao-acceptance-runtime"},
		"subjects": [
			{"kind": "ServiceAccount", "name": "homelab-test-openbao-issuance", "namespace": "kube-system"},
			{"kind": "ServiceAccount", "name": "homelab-test-openbao-ha", "namespace": "kube-system"},
		],
	},
	role("homelab-test-openbao-issuer-runtime", "openbao", [
		{"apiGroups": [""], "resources": ["pods"], "verbs": ["create", "delete"]},
		{"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]},
	]),
	role_binding("homelab-test-openbao-issuer-runtime", "openbao", "homelab-test-openbao-issuance", "kube-system", "homelab-test-openbao-issuer-runtime"),
	probe_guard("homelab-test-openbao-probe-pods", ["CREATE", "UPDATE", "DELETE"], "pods"),
	probe_guard("homelab-test-openbao-probe-exec", ["CONNECT"], "pods/exec"),
	flux_guard_binding("homelab-test-openbao-probe-pods"),
	flux_guard_binding("homelab-test-openbao-probe-exec"),
]

probe_guard(name, operations, resource) := {
	"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": name},
	"spec": {
		"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": operations, "resources": [resource]}]},
		"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username in ['system:serviceaccount:kube-system:homelab-test-openbao-issuance', 'system:serviceaccount:kube-system:homelab-test-openbao-ha']"}],
		"validations": [{"expression": "object.kind == 'Pod'"}],
	},
}

test_issuer_runtime_cannot_bind_ha_profile if {
	fixture := runner_change("RoleBinding", "homelab-test-openbao-issuer-runtime", [{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "homelab-test-openbao-ha", "namespace": "kube-system"}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_acceptance_runtime_cannot_bind_lifecycle_profile if {
	fixture := runner_change("RoleBinding", "homelab-test-openbao-acceptance-runtime", [{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "homelab-test-openbao-lifecycle", "namespace": "kube-system"}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_issuer_runtime_cannot_read_secrets_by_api if {
	fixture := fixture_with_rule("homelab-test-openbao-issuer-runtime", [""], ["secrets"], ["get"])
	messages := deny with input as fixture
	count(messages) > 0
}

test_issuer_probe_cannot_remove_creation_guard if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-openbao-probe-pods"]]
	count(messages) > 0
}

test_issuer_probe_cannot_remove_exec_guard if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-openbao-probe-exec"]]
	count(messages) > 0
}

dedicated_restore_fixture := [
	cluster_role_binding("homelab-test-openbao-restore-view", ["homelab-test-openbao-restore"], "view"),
	cluster_role_binding("homelab-test-openbao-restore-observation", ["homelab-test-openbao-restore"], "homelab-observer-extra"),
	role("homelab-test-openbao-restore-runtime", "openbao-restore-test", [
		{"apiGroups": ["apps"], "resources": ["statefulsets"], "verbs": ["create"]},
		{"apiGroups": ["apps"], "resources": ["statefulsets"], "resourceNames": ["scratch"], "verbs": ["delete"]},
		{"apiGroups": [""], "resources": ["persistentvolumeclaims", "secrets", "configmaps"], "verbs": ["create"]},
		{"apiGroups": [""], "resources": ["persistentvolumeclaims"], "resourceNames": ["scratch-data"], "verbs": ["delete"]},
		{"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["scratch-seal"], "verbs": ["get", "delete"]},
		{"apiGroups": [""], "resources": ["secrets"], "verbs": ["list"]},
		{"apiGroups": [""], "resources": ["configmaps"], "resourceNames": ["scratch-config"], "verbs": ["delete"]},
		{"apiGroups": [""], "resources": ["pods"], "resourceNames": ["scratch-0"], "verbs": ["delete"]},
		{"apiGroups": [""], "resources": ["pods/exec"], "resourceNames": ["scratch-0"], "verbs": ["get", "create"]},
	]),
	role_binding("homelab-test-openbao-restore-runtime", "openbao-restore-test", "homelab-test-openbao-restore", "kube-system", "homelab-test-openbao-restore-runtime"),
	restore_guard("homelab-test-openbao-restore-statefulset", "apps", ["statefulsets"], ["CREATE", "UPDATE", "DELETE"]),
	restore_guard("homelab-test-openbao-restore-storage", "", ["persistentvolumeclaims"], ["CREATE", "UPDATE", "DELETE"]),
	restore_guard("homelab-test-openbao-restore-private", "", ["secrets", "configmaps"], ["CREATE", "UPDATE", "DELETE"]),
	restore_guard("homelab-test-openbao-restore-exec", "", ["pods/exec"], ["CONNECT"]),
	restore_guard("homelab-test-openbao-restore-pod-delete", "", ["pods"], ["DELETE"]),
	flux_guard_binding("homelab-test-openbao-restore-statefulset"),
	flux_guard_binding("homelab-test-openbao-restore-storage"),
	flux_guard_binding("homelab-test-openbao-restore-private"),
	flux_guard_binding("homelab-test-openbao-restore-exec"),
	flux_guard_binding("homelab-test-openbao-restore-pod-delete"),
]

restore_guard(name, group, resources, operations) := {
	"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": name},
	"spec": {
		"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [group], "apiVersions": ["v1"], "operations": operations, "resources": resources}]},
		"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-restore'"}],
		"validations": [{"expression": "object.kind == 'StatefulSet'"}],
	},
}

test_restore_cannot_receive_namespace_or_rbac_write if {
	fixture := runner_change("Role", "homelab-test-openbao-restore-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": ["rbac.authorization.k8s.io"], "resources": ["roles"], "verbs": ["create"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_restore_cannot_access_production_secret_namespace if {
	fixture := runner_change("Role", "homelab-test-openbao-restore-runtime", [{"op": "replace", "path": "/metadata/namespace", "value": "openbao"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_restore_cannot_bind_lifecycle_account if {
	fixture := runner_change("RoleBinding", "homelab-test-openbao-restore-runtime", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-openbao-lifecycle"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_restore_requires_full_parent_guard if {
	fixture := [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-openbao-restore-statefulset"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_restore_requires_fixed_exec_guard if {
	fixture := [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-openbao-restore-exec"]]
	messages := deny with input as fixture
	count(messages) > 0
}

dedicated_cilium_namespace_fixture := [
	cluster_role("homelab-test-cilium-namespaces", [
		{"apiGroups": [""], "resources": ["namespaces"], "verbs": ["create"]},
		{"apiGroups": [""], "resources": ["namespaces"], "resourceNames": ["cilium-test-1", "cilium-test-ccnp1", "cilium-test-ccnp2"], "verbs": ["update", "delete"]},
	]),
	cluster_role_binding("homelab-test-cilium-namespaces", ["homelab-test-cilium-connectivity"], "homelab-test-cilium-namespaces"),
	cluster_role_binding("homelab-test-cilium-connectivity-view", ["homelab-test-cilium-connectivity"], "view"),
	cluster_role_binding("homelab-test-cilium-connectivity-observation", ["homelab-test-cilium-connectivity"], "homelab-observer-extra"),
	role("homelab-test-cilium-helm-observation", "kube-system", [
		{"apiGroups": [""], "resources": ["secrets"], "verbs": ["list"]},
		{"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["cilium-etcd-secrets"], "verbs": ["get"]},
	]),
	role_binding("homelab-test-cilium-helm-observation", "kube-system", "homelab-test-cilium-connectivity", "kube-system", "homelab-test-cilium-helm-observation"),
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-cilium-namespaces"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["namespaces"]}]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"}],
			"validations": [{"expression": "object.kind == 'Namespace'"}],
		},
	},
	flux_guard_binding("homelab-test-cilium-namespaces"),
]

test_cilium_cannot_receive_generic_namespace_deletion if {
	fixture := runner_change("ClusterRole", "homelab-test-cilium-namespaces", [{"op": "remove", "path": "/rules/1/resourceNames"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_requires_namespace_parent_guard if {
	fixture := [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-cilium-namespaces"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_cannot_receive_other_namespace_secret_inventory if {
	fixture := runner_change("Role", "homelab-test-cilium-helm-observation", [{"op": "replace", "path": "/metadata/namespace", "value": "openbao"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_secret_inventory_cannot_receive_secret_write if {
	fixture := runner_change("Role", "homelab-test-cilium-helm-observation", [{"op": "add", "path": "/rules/0/verbs/-", "value": "update"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_privileged_namespace_lifecycle_cannot_bind_ordinary_runner if {
	fixture := runner_change("ClusterRoleBinding", "homelab-test-cilium-namespaces", [{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "homelab-test-runner", "namespace": "kube-system"}}])
	messages := deny with input as fixture
	count(messages) > 0
}
