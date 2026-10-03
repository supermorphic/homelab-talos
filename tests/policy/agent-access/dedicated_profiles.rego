package homelab.agent_access

import rego.v1

dedicated_account_names := {
	"homelab-test-flux-restart", "homelab-test-cilium-connectivity",
	"homelab-test-node-reschedule", "homelab-test-conformance",
	"homelab-test-openbao-issuance", "homelab-test-openbao-ha",
	"homelab-test-openbao-restore", "homelab-test-openbao-lifecycle",
}

dedicated_account_exact(accounts) if {
	count(accounts) == 1
	metadata_namespace(accounts[0]) == "kube-system"
	accounts[0].automountServiceAccountToken == false
	object.get(accounts[0], "secrets", []) == []
}

deny contains msg if {
	some name in dedicated_account_names
	accounts := publisher_documents("ServiceAccount", name)
	not dedicated_account_exact(accounts)
	msg := sprintf("dedicated account %s must exist once, tokenless in kube-system", [name])
}

conformance_binding_exact(bindings) if {
	count(bindings) == 1
	metadata_namespace(bindings[0]) == ""
	object.get(bindings[0], "roleRef", {}) == {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cluster-admin"}
	object.get(bindings[0], "subjects", []) == [{"kind": "ServiceAccount", "name": "homelab-test-conformance", "namespace": "kube-system"}]
}

deny contains "conformance administrator exception must bind only its dedicated account once" if {
	not conformance_binding_exact(publisher_documents("ClusterRoleBinding", "homelab-test-conformance"))
}
