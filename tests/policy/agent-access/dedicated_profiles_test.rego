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
