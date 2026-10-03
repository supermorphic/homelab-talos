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

dedicated_role_contracts := {"homelab-test-flux-restart": {
	"namespace": "flux-system",
	"rules": [
		{"apiGroups": ["apps"], "resources": ["deployments"], "resourceNames": ["source-controller", "kustomize-controller", "helm-controller", "notification-controller"], "verbs": ["patch", "update"]},
		{"apiGroups": ["source.toolkit.fluxcd.io"], "resources": ["gitrepositories"], "resourceNames": ["flux-system"], "verbs": ["patch", "update"]},
		{"apiGroups": ["kustomize.toolkit.fluxcd.io"], "resources": ["kustomizations"], "resourceNames": ["flux-canary", "cluster-apps"], "verbs": ["patch", "update"]},
	],
	"subjects": [{"kind": "ServiceAccount", "name": "homelab-test-flux-restart", "namespace": "kube-system"}],
}}

dedicated_observation_contracts := {
	"homelab-test-flux-restart-view": {"role": "view", "account": "homelab-test-flux-restart"},
	"homelab-test-flux-restart-observation": {"role": "homelab-observer-extra", "account": "homelab-test-flux-restart"},
}

dedicated_observation_exact(bindings, name, contract) if {
	count(bindings) == 1
	metadata_namespace(bindings[0]) == ""
	has_binding(name, contract.role, {sprintf("ServiceAccount:kube-system:%s", [contract.account])})
}

deny contains msg if {
	some name, contract in dedicated_observation_contracts
	not dedicated_observation_exact(publisher_documents("ClusterRoleBinding", name), name, contract)
	msg := sprintf("dedicated observation binding %s must match its one declared account", [name])
}

dedicated_admission_rules := {
	"homelab-test-flux-restart": [{"apiGroups": ["apps"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["deployments"]}],
	"homelab-test-flux-restart-reconcile": [
		{"apiGroups": ["source.toolkit.fluxcd.io"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["gitrepositories"]},
		{"apiGroups": ["kustomize.toolkit.fluxcd.io"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["kustomizations"]},
	],
}

dedicated_admission_conditions := {
	"homelab-test-flux-restart": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-flux-restart'"},
	"homelab-test-flux-restart-reconcile": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-flux-restart'"},
}
