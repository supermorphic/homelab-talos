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
			"validations": [{"expression": "request.name in ['openbao-0', 'openbao-1', 'openbao-2']"}],
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

dedicated_cilium_ephemeral_fixture := [
	role("homelab-test-cilium-ephemeral-diagnostics", "kube-system", [{"apiGroups": [""], "resources": ["pods/ephemeralcontainers"], "verbs": ["patch"]}]),
	role_binding("homelab-test-cilium-ephemeral-diagnostics", "kube-system", "homelab-test-cilium-connectivity", "kube-system", "homelab-test-cilium-ephemeral-diagnostics"),
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-cilium-ephemeral-diagnostics"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["pods/ephemeralcontainers"]}]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"}],
			"validations": [{"expression": "object.kind == 'Pod'"}],
		},
	},
	flux_guard_binding("homelab-test-cilium-ephemeral-diagnostics"),
]

test_cilium_ephemeral_grant_cannot_patch_whole_production_pods if {
	fixture := runner_change("Role", "homelab-test-cilium-ephemeral-diagnostics", [{"op": "replace", "path": "/rules/0/resources", "value": ["pods"]}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_ephemeral_grant_cannot_bind_debugger if {
	fixture := runner_change("RoleBinding", "homelab-test-cilium-ephemeral-diagnostics", [{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "homelab-diagnostic", "namespace": "kube-system"}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_ephemeral_diagnostics_requires_complete_parent_guard if {
	fixture := [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-cilium-ephemeral-diagnostics"]]
	messages := deny with input as fixture
	count(messages) > 0
}

dedicated_cilium_connect_fixture := [
	role("homelab-test-cilium-system-runtime", "kube-system", [
		{"apiGroups": [""], "resources": ["pods/exec", "pods/portforward"], "verbs": ["get", "create"]},
		{"apiGroups": [""], "resources": ["pods/proxy"], "verbs": ["get"]},
	]),
	role_binding("homelab-test-cilium-system-runtime", "kube-system", "homelab-test-cilium-connectivity", "kube-system", "homelab-test-cilium-system-runtime"),
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-cilium-system-connect"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/exec", "pods/portforward"]}]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"}],
			"validations": [{"expression": "request.namespace == 'kube-system'"}],
		},
	},
	flux_guard_binding("homelab-test-cilium-system-connect"),
]

test_cilium_system_runtime_cannot_access_other_namespace if {
	fixture := runner_change("Role", "homelab-test-cilium-system-runtime", [{"op": "replace", "path": "/metadata/namespace", "value": "openbao"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_system_runtime_cannot_bind_ordinary_runner if {
	fixture := runner_change("RoleBinding", "homelab-test-cilium-system-runtime", [{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "homelab-test-runner", "namespace": "kube-system"}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_metric_proxy_cannot_receive_write_verbs if {
	fixture := runner_change("Role", "homelab-test-cilium-system-runtime", [{"op": "add", "path": "/rules/1/verbs/-", "value": "create"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_cilium_system_runtime_requires_connect_guard if {
	fixture := [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-cilium-system-connect"]]
	messages := deny with input as fixture
	count(messages) > 0
}

dedicated_cilium_cluster_policy_fixture := [
	cluster_role("homelab-test-cilium-cluster-policies", [{"apiGroups": ["cilium.io"], "resources": ["ciliumclusterwidenetworkpolicies"], "resourceNames": ["allow-ingress-specific-namespace-ccnp", "allow-egress-specific-namespace-ccnp", "host-firewall-ingress", "host-firewall-egress"], "verbs": ["get", "patch", "delete"]}]),
	cluster_role_binding("homelab-test-cilium-cluster-policies", ["homelab-test-cilium-connectivity"], "homelab-test-cilium-cluster-policies"),
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-cilium-cluster-policies"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": ["cilium.io"], "apiVersions": ["v2"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["ciliumclusterwidenetworkpolicies"]}]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"}],
			"validations": [{"expression": "object.kind == 'CiliumClusterwideNetworkPolicy'"}],
		},
	},
	flux_guard_binding("homelab-test-cilium-cluster-policies"),
]

test_cilium_cluster_policy_names_cannot_be_unbounded if {
	messages := deny with input as runner_change("ClusterRole", "homelab-test-cilium-cluster-policies", [{"op": "remove", "path": "/rules/0/resourceNames"}])
	count(messages) > 0
}

test_cilium_cluster_policy_cannot_bind_ordinary_runner if {
	messages := deny with input as runner_change("ClusterRoleBinding", "homelab-test-cilium-cluster-policies", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-runner"}])
	count(messages) > 0
}

test_cilium_cluster_policy_guard_must_cover_server_side_apply_creation if {
	messages := deny with input as runner_change("ValidatingAdmissionPolicy", "homelab-test-cilium-cluster-policies", [{"op": "replace", "path": "/spec/matchConstraints/resourceRules/0/operations", "value": ["UPDATE", "DELETE"]}])
	count(messages) > 0
}

test_cilium_cluster_policy_requires_parent_guard if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-cilium-cluster-policies"]]
	count(messages) > 0
}

dedicated_cilium_observation_fixture := [
	cluster_role("homelab-test-cilium-diagnostic-observation", [
		{"apiGroups": ["cilium.io"], "resources": ["ciliumcidrgroups", "ciliumegressgatewaypolicies", "ciliumlocalredirectpolicies", "ciliumendpointslices", "ciliumnodeconfigs", "ciliumpodippools", "ciliuml2announcementpolicies", "ciliumenvoyconfigs", "ciliumclusterwideenvoyconfigs", "ciliumgatewayclassconfigs", "ciliumbgppeeringpolicies", "ciliumbgpclusterconfigs", "ciliumbgppeerconfigs", "ciliumbgpadvertisements", "ciliumbgpnodeconfigs", "ciliumbgpnodeconfigoverrides", "podinfo", "tracingpolicies", "tracingpoliciesnamespaced"], "verbs": ["get", "list"]},
		{"apiGroups": ["gateway.networking.k8s.io"], "resources": ["listenersets", "backendtlspolicies", "tlsroutes", "tcproutes", "udproutes", "grpcroutes"], "verbs": ["get", "list"]},
		{"apiGroups": ["networking.k8s.io"], "resources": ["ingressclasses"], "verbs": ["get", "list"]},
		{"apiGroups": ["policy.networking.k8s.io"], "resources": ["clusternetworkpolicies"], "verbs": ["get", "list"]},
	]),
	cluster_role_binding("homelab-test-cilium-diagnostic-observation", ["homelab-test-cilium-connectivity"], "homelab-test-cilium-diagnostic-observation"),
]

test_cilium_diagnostic_inventory_cannot_write_resources if {
	messages := deny with input as runner_change("ClusterRole", "homelab-test-cilium-diagnostic-observation", [{"op": "add", "path": "/rules/0/verbs/-", "value": "patch"}])
	count(messages) > 0
}

test_cilium_diagnostic_inventory_cannot_grant_wildcard_resources if {
	messages := deny with input as runner_change("ClusterRole", "homelab-test-cilium-diagnostic-observation", [{"op": "replace", "path": "/rules/0/resources", "value": ["*"]}])
	count(messages) > 0
}

test_cilium_diagnostic_inventory_cannot_bind_other_profiles if {
	messages := deny with input as runner_change("ClusterRoleBinding", "homelab-test-cilium-diagnostic-observation", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-diagnostic"}])
	count(messages) > 0
}

dedicated_cilium_copy_fixture := [
	role("homelab-test-cilium-copy-diagnostics", "kube-system", [{"apiGroups": [""], "resources": ["pods"], "verbs": ["create", "delete"]}]),
	role_binding("homelab-test-cilium-copy-diagnostics", "kube-system", "homelab-test-cilium-connectivity", "kube-system", "homelab-test-cilium-copy-diagnostics"),
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-cilium-copy-diagnostics"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["pods"]}]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"}],
			"validations": [{"expression": "object.metadata.generateName == 'sysdump-'"}],
		},
	},
	flux_guard_binding("homelab-test-cilium-copy-diagnostics"),
]

test_cilium_copy_recovery_cannot_write_production_openbao if {
	messages := deny with input as runner_change("Role", "homelab-test-cilium-copy-diagnostics", [{"op": "replace", "path": "/metadata/namespace", "value": "openbao"}])
	count(messages) > 0
}

test_cilium_copy_recovery_cannot_patch_pods if {
	messages := deny with input as runner_change("Role", "homelab-test-cilium-copy-diagnostics", [{"op": "add", "path": "/rules/0/verbs/-", "value": "patch"}])
	count(messages) > 0
}

test_cilium_copy_recovery_cannot_bind_other_profile if {
	messages := deny with input as runner_change("RoleBinding", "homelab-test-cilium-copy-diagnostics", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-openbao-ha"}])
	count(messages) > 0
}

test_cilium_copy_recovery_requires_admission if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-cilium-copy-diagnostics"]]
	count(messages) > 0
}

dedicated_cilium_namespaced_fixture := [
	role("homelab-test-cilium-fixtures-1", "cilium-test-1", [{"apiGroups": ["apps"], "resources": ["deployments", "daemonsets"], "verbs": ["create", "delete"]}, {"apiGroups": [""], "resources": ["serviceaccounts", "services", "configmaps", "secrets"], "verbs": ["create"]}, {"apiGroups": [""], "resources": ["serviceaccounts", "services", "configmaps"], "verbs": ["delete"]}, {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["cabundle", "externaltarget-tls", "header-match"], "verbs": ["get", "update", "delete"]}, {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]}, {"apiGroups": ["cilium.io"], "resources": ["ciliumnetworkpolicies"], "resourceNames": ["all-egress-deny", "all-entities-deny", "all-ingress-deny", "allow-all-egress", "allow-all-except-world", "allow-all-ingress", "allow-from-cilium-ingress", "cidr-deny", "client-egress-icmp", "client-egress-l7-http", "client-egress-l7-http-external-node", "client-egress-l7-http-from-any", "client-egress-l7-http-matchheader-secret", "client-egress-l7-http-matchheader-secret-port-range", "client-egress-l7-http-method", "client-egress-l7-http-method-port-range", "client-egress-l7-http-named-port", "client-egress-l7-http-port-range", "client-egress-l7-tls", "client-egress-l7-tls-other-sni", "client-egress-l7-tls-port-range", "client-egress-l7-tls-sni", "client-egress-node-local-dns", "client-egress-only-dns", "client-egress-only-port-53", "client-egress-tls-sni", "client-egress-tls-sni-double-wildcard", "client-egress-tls-sni-other", "client-egress-tls-sni-random-wildcard", "client-egress-tls-sni-wildcard", "client-egress-to-cidr", "client-egress-to-cidr-deny", "client-egress-to-cidr-k8s", "client-egress-to-cidr-lrp-deny", "client-egress-to-cidrgroup-deny", "client-egress-to-cidrgroup-deny-label", "client-egress-to-echo", "client-egress-to-echo-deny", "client-egress-to-echo-deny-port-range", "client-egress-to-echo-expression", "client-egress-to-echo-expression-deny", "client-egress-to-echo-expression-deny-port-range", "client-egress-to-echo-expression-port-range", "client-egress-to-echo-no-cluster-policy", "client-egress-to-echo-service-account", "client-egress-to-echo-service-account-deny", "client-egress-to-echo-service-account-deny-port-range", "client-egress-to-echo-service-account-port-range", "client-egress-to-entities-host", "client-egress-to-entities-k8s", "client-egress-to-entities-world", "client-egress-to-entities-world-port-range", "client-egress-to-fqdns-one.one.one.one", "client-egress-to-fqdns-proxy-one.one.one.one", "client-ingress-from-client2", "client-ingress-from-client2-icmp", "client-ingress-from-other-client-icmp-deny", "client-ingress-to-echo-named-port-deny", "client-with-service-account-egress-to-echo", "client-with-service-account-egress-to-echo-deny", "client-with-service-account-egress-to-echo-deny-port-range", "client-with-service-account-egress-to-echo-port-range", "echo-ingress-from-cidr", "echo-ingress-from-client-tiered-wildcard-pass-l7", "echo-ingress-from-other-client", "echo-ingress-from-other-client-deny", "echo-ingress-l7-http", "echo-ingress-l7-http-from-anywhere", "echo-ingress-l7-http-from-anywhere-port-range", "echo-ingress-l7-http-named-port", "echo-ingress-mutual-authentication", "echo-ingress-mutual-authentication-fail", "echo-ingress-mutual-authentication-fail-port-range", "echo-ingress-mutual-authentication-port-range", "entity-cluster", "host-cluster-egress", "host-cluster-ingress", "ingress-backend-deny", "ingress-entity-deny", "ingress-source-egress-deny-other-node", "world-entity-deny"], "verbs": ["get", "patch", "delete"]}, {"apiGroups": ["cilium.io"], "resources": ["ciliumlocalredirectpolicies"], "resourceNames": ["lrp-address-matcher-skip-redirect-from-backend-v4", "lrp-address-matcher-skip-redirect-from-backend-v6", "lrp-address-matcher-v4", "lrp-address-matcher-v6"], "verbs": ["get", "patch", "delete"]}, {"apiGroups": ["networking.k8s.io"], "resources": ["networkpolicies"], "resourceNames": ["all-egress-deny", "all-ingress-deny", "client-egress-to-cidr", "client-egress-to-cidr-cp-host", "client-egress-to-echo", "client-egress-to-echo-expression", "client-egress-to-echo-expression-port-range", "client-egress-to-node-cidr", "client-ingress-from-client2", "echo-ingress-from-other-client"], "verbs": ["get", "patch", "delete"]}]),
	role_binding("homelab-test-cilium-fixtures-1", "cilium-test-1", "homelab-test-cilium-connectivity", "kube-system", "homelab-test-cilium-fixtures-1"),
	role("homelab-test-cilium-fixtures-ccnp1", "cilium-test-ccnp1", [{"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["create", "delete"]}, {"apiGroups": [""], "resources": ["serviceaccounts"], "verbs": ["create", "delete"]}, {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]}]),
	role_binding("homelab-test-cilium-fixtures-ccnp1", "cilium-test-ccnp1", "homelab-test-cilium-connectivity", "kube-system", "homelab-test-cilium-fixtures-ccnp1"),
	role("homelab-test-cilium-fixtures-ccnp2", "cilium-test-ccnp2", [{"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["create", "delete"]}, {"apiGroups": [""], "resources": ["serviceaccounts"], "verbs": ["create", "delete"]}, {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]}]),
	role_binding("homelab-test-cilium-fixtures-ccnp2", "cilium-test-ccnp2", "homelab-test-cilium-connectivity", "kube-system", "homelab-test-cilium-fixtures-ccnp2"),
	{"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-cilium-fixtures"}, "spec": {"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": ["apps"], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["deployments", "daemonsets"]}, {"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["serviceaccounts", "services", "configmaps", "secrets"]}, {"apiGroups": ["cilium.io"], "apiVersions": ["v2", "v2alpha1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["ciliumnetworkpolicies", "ciliumlocalredirectpolicies"]}, {"apiGroups": ["networking.k8s.io"], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["networkpolicies"]}]}, "matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"}], "validations": [{"expression": "request.namespace == 'cilium-test-1'"}]}},
	flux_guard_binding("homelab-test-cilium-fixtures"),
]

test_cilium_fixtures_cannot_write_system_namespace if {
	messages := deny with input as runner_change("Role", "homelab-test-cilium-fixtures-1", [{"op": "replace", "path": "/metadata/namespace", "value": "kube-system"}])
	count(messages) > 0
}

test_cilium_fixtures_cannot_request_account_tokens if {
	messages := deny with input as runner_change("Role", "homelab-test-cilium-fixtures-1", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["serviceaccounts/token"], "verbs": ["create"]}}])
	count(messages) > 0
}

test_cilium_fixtures_cannot_read_arbitrary_secrets if {
	messages := deny with input as runner_change("Role", "homelab-test-cilium-fixtures-1", [{"op": "remove", "path": "/rules/3/resourceNames"}])
	count(messages) > 0
}

test_cilium_ccnp_namespace_cannot_receive_general_fixture_resources if {
	messages := deny with input as runner_change("Role", "homelab-test-cilium-fixtures-ccnp1", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["secrets"], "verbs": ["create"]}}])
	count(messages) > 0
}

test_cilium_ccnp_namespace_cannot_bind_ordinary_runner if {
	messages := deny with input as runner_change("RoleBinding", "homelab-test-cilium-fixtures-ccnp2", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-runner"}])
	count(messages) > 0
}

test_cilium_fixtures_require_parent_admission if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicy", "homelab-test-cilium-fixtures"]]
	count(messages) > 0
}

dedicated_cilium_global_fixture := [
	cluster_role("homelab-test-cilium-global-fixtures", [
		{"apiGroups": ["cilium.io"], "resources": ["ciliumcidrgroups"], "resourceNames": ["cilium-test-external-cidr", "cilium-test-external-cidr-label"], "verbs": ["get", "patch", "delete"]},
		{"apiGroups": ["cilium.io"], "resources": ["ciliumclusterwideenvoyconfigs"], "resourceNames": ["client-egress-to-fqdns-proxy-one.one.one.one"], "verbs": ["get", "patch", "delete"]},
		{"apiGroups": ["policy.networking.k8s.io"], "resources": ["clusternetworkpolicies"], "resourceNames": ["echo-ingress-from-client-tiered-wildcard-pass-l7"], "verbs": ["get", "patch", "delete"]},
	]),
	cluster_role_binding("homelab-test-cilium-global-fixtures", ["homelab-test-cilium-connectivity"], "homelab-test-cilium-global-fixtures"),
	{
		"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": "homelab-test-cilium-global-fixtures"},
		"spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": [
				{"apiGroups": ["cilium.io"], "apiVersions": ["v2", "v2alpha1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["ciliumcidrgroups", "ciliumclusterwideenvoyconfigs"]},
				{"apiGroups": ["policy.networking.k8s.io"], "apiVersions": ["v1alpha2"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["clusternetworkpolicies"]},
			]},
			"matchConditions": [{"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"}],
			"validations": [{"expression": "request.namespace == ''"}],
		},
	},
	flux_guard_binding("homelab-test-cilium-global-fixtures"),
]

test_cilium_global_fixture_names_cannot_be_unbounded if {
	messages := deny with input as runner_change("ClusterRole", "homelab-test-cilium-global-fixtures", [{"op": "remove", "path": "/rules/0/resourceNames"}])
	count(messages) > 0
}

test_cilium_global_fixture_cannot_bind_ordinary_runner if {
	messages := deny with input as runner_change("ClusterRoleBinding", "homelab-test-cilium-global-fixtures", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-test-runner"}])
	count(messages) > 0
}

test_cilium_global_fixture_requires_complete_admission_coverage if {
	messages := deny with input as runner_change("ValidatingAdmissionPolicy", "homelab-test-cilium-global-fixtures", [{"op": "remove", "path": "/spec/matchConstraints/resourceRules/1"}])
	count(messages) > 0
}

test_cilium_global_fixture_requires_binding if {
	messages := deny with input as [d | some d in valid_fixture; [d.kind, metadata_name(d)] != ["ValidatingAdmissionPolicyBinding", "homelab-test-cilium-global-fixtures"]]
	count(messages) > 0
}
