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
