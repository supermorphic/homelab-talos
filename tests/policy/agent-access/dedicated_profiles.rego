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

dedicated_role_contracts := {
	"homelab-test-cilium-copy-diagnostics": {"namespace": "kube-system", "rules": [{"apiGroups": [""], "resources": ["pods"], "verbs": ["create", "delete"]}], "subjects": [{"kind": "ServiceAccount", "name": "homelab-test-cilium-connectivity", "namespace": "kube-system"}]},
	"homelab-test-cilium-system-runtime": {"namespace": "kube-system", "rules": [{"apiGroups": [""], "resources": ["pods/exec", "pods/portforward"], "verbs": ["get", "create"]}, {"apiGroups": [""], "resources": ["pods/proxy"], "verbs": ["get"]}], "subjects": [{"kind": "ServiceAccount", "name": "homelab-test-cilium-connectivity", "namespace": "kube-system"}]},
	"homelab-test-cilium-ephemeral-diagnostics": {"namespace": "kube-system", "rules": [{"apiGroups": [""], "resources": ["pods/ephemeralcontainers"], "verbs": ["patch"]}], "subjects": [{"kind": "ServiceAccount", "name": "homelab-test-cilium-connectivity", "namespace": "kube-system"}]},
	"homelab-test-cilium-helm-observation": {"namespace": "kube-system", "rules": [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["list"]}, {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["cilium-etcd-secrets"], "verbs": ["get"]}], "subjects": [{"kind": "ServiceAccount", "name": "homelab-test-cilium-connectivity", "namespace": "kube-system"}]},
	"homelab-test-openbao-restore-runtime": {"namespace": "openbao-restore-test", "rules": [{"apiGroups": ["apps"], "resources": ["statefulsets"], "verbs": ["create"]}, {"apiGroups": ["apps"], "resources": ["statefulsets"], "resourceNames": ["scratch"], "verbs": ["delete"]}, {"apiGroups": [""], "resources": ["persistentvolumeclaims", "secrets", "configmaps"], "verbs": ["create"]}, {"apiGroups": [""], "resources": ["persistentvolumeclaims"], "resourceNames": ["scratch-data"], "verbs": ["delete"]}, {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["scratch-seal"], "verbs": ["get", "delete"]}, {"apiGroups": [""], "resources": ["secrets"], "verbs": ["list"]}, {"apiGroups": [""], "resources": ["configmaps"], "resourceNames": ["scratch-config"], "verbs": ["delete"]}, {"apiGroups": [""], "resources": ["pods"], "resourceNames": ["scratch-0"], "verbs": ["delete"]}, {"apiGroups": [""], "resources": ["pods/exec"], "resourceNames": ["scratch-0"], "verbs": ["get", "create"]}], "subjects": [{"kind": "ServiceAccount", "name": "homelab-test-openbao-restore", "namespace": "kube-system"}]},
	"homelab-test-openbao-issuer-runtime": {"namespace": "openbao", "rules": [{"apiGroups": [""], "resources": ["pods"], "verbs": ["create", "delete"]}, {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]}], "subjects": [{"kind": "ServiceAccount", "name": "homelab-test-openbao-issuance", "namespace": "kube-system"}]},
	"homelab-test-openbao-acceptance-runtime": {"namespace": "openbao-acceptance", "rules": [{"apiGroups": [""], "resources": ["pods"], "verbs": ["create", "delete"]}, {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]}], "subjects": [{"kind": "ServiceAccount", "name": "homelab-test-openbao-issuance", "namespace": "kube-system"}, {"kind": "ServiceAccount", "name": "homelab-test-openbao-ha", "namespace": "kube-system"}]},
	"homelab-test-openbao-ha-eviction": {
		"namespace": "openbao",
		"rules": [{"apiGroups": [""], "resources": ["pods/eviction"], "resourceNames": ["openbao-0", "openbao-1", "openbao-2"], "verbs": ["create"]}],
		"subjects": [{"kind": "ServiceAccount", "name": "homelab-test-openbao-ha", "namespace": "kube-system"}],
	},
	"homelab-test-openbao-member-tunnels": {
		"namespace": "openbao",
		"rules": [{"apiGroups": [""], "resources": ["pods/portforward"], "resourceNames": ["openbao-0", "openbao-1", "openbao-2"], "verbs": ["get", "create"]}],
		"subjects": [
			{"kind": "ServiceAccount", "name": "homelab-test-openbao-ha", "namespace": "kube-system"},
			{"kind": "ServiceAccount", "name": "homelab-test-openbao-lifecycle", "namespace": "kube-system"},
		],
	},
	"homelab-test-node-reschedule-runtime": {
		"namespace": "media",
		"rules": [
			{"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]},
			{"apiGroups": [""], "resources": ["pods"], "verbs": ["delete"]},
		],
		"subjects": [{"kind": "ServiceAccount", "name": "homelab-test-node-reschedule", "namespace": "kube-system"}],
	},
	"homelab-test-flux-restart": {
		"namespace": "flux-system",
		"rules": [
			{"apiGroups": ["apps"], "resources": ["deployments"], "resourceNames": ["source-controller", "kustomize-controller", "helm-controller", "notification-controller"], "verbs": ["patch", "update"]},
			{"apiGroups": ["source.toolkit.fluxcd.io"], "resources": ["gitrepositories"], "resourceNames": ["flux-system"], "verbs": ["patch", "update"]},
			{"apiGroups": ["kustomize.toolkit.fluxcd.io"], "resources": ["kustomizations"], "resourceNames": ["flux-canary", "cluster-apps"], "verbs": ["patch", "update"]},
		],
		"subjects": [{"kind": "ServiceAccount", "name": "homelab-test-flux-restart", "namespace": "kube-system"}],
	},
}

dedicated_observation_contracts := {
	"homelab-test-cilium-connectivity-observation": {"role": "homelab-observer-extra", "account": "homelab-test-cilium-connectivity"},
	"homelab-test-cilium-connectivity-view": {"role": "view", "account": "homelab-test-cilium-connectivity"},
	"homelab-test-openbao-restore-view": {"role": "view", "account": "homelab-test-openbao-restore"},
	"homelab-test-openbao-restore-observation": {"role": "homelab-observer-extra", "account": "homelab-test-openbao-restore"},
	"homelab-test-openbao-issuance-observation": {"role": "homelab-observer-extra", "account": "homelab-test-openbao-issuance"},
	"homelab-test-openbao-issuance-view": {"role": "view", "account": "homelab-test-openbao-issuance"},
	"homelab-test-openbao-lifecycle-observation": {"role": "homelab-observer-extra", "account": "homelab-test-openbao-lifecycle"},
	"homelab-test-openbao-lifecycle-view": {"role": "view", "account": "homelab-test-openbao-lifecycle"},
	"homelab-test-openbao-ha-observation": {"role": "homelab-observer-extra", "account": "homelab-test-openbao-ha"},
	"homelab-test-openbao-ha-view": {"role": "view", "account": "homelab-test-openbao-ha"},
	"homelab-test-node-reschedule-view": {"role": "view", "account": "homelab-test-node-reschedule"},
	"homelab-test-node-reschedule-observation": {"role": "homelab-observer-extra", "account": "homelab-test-node-reschedule"},
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
	"homelab-test-cilium-copy-diagnostics": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["pods"]}],
	"homelab-test-cilium-cluster-policies": [{"apiGroups": ["cilium.io"], "apiVersions": ["v2"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["ciliumclusterwidenetworkpolicies"]}],
	"homelab-test-cilium-system-connect": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/exec", "pods/portforward"]}],
	"homelab-test-cilium-ephemeral-diagnostics": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["pods/ephemeralcontainers"]}],
	"homelab-test-cilium-namespaces": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["namespaces"]}],
	"homelab-test-openbao-restore-pod-delete": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["DELETE"], "resources": ["pods"]}],
	"homelab-test-openbao-restore-exec": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/exec"]}],
	"homelab-test-openbao-restore-private": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["secrets", "configmaps"]}],
	"homelab-test-openbao-restore-storage": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["persistentvolumeclaims"]}],
	"homelab-test-openbao-restore-statefulset": [{"apiGroups": ["apps"], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["statefulsets"]}],
	"homelab-test-openbao-probe-exec": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/exec"]}],
	"homelab-test-openbao-probe-pods": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["pods"]}],
	"homelab-test-openbao-ha-eviction": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE"], "resources": ["pods/eviction"]}],
	"homelab-test-openbao-member-tunnels": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/portforward"]}],
	"homelab-test-node-plex-disruption": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["DELETE"], "resources": ["pods"]}],
	"homelab-test-node-plex-runtime": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/exec"]}],
	"homelab-test-node-scheduling": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["nodes"]}],
	"homelab-test-flux-restart": [{"apiGroups": ["apps"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["deployments"]}],
	"homelab-test-flux-restart-reconcile": [
		{"apiGroups": ["source.toolkit.fluxcd.io"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["gitrepositories"]},
		{"apiGroups": ["kustomize.toolkit.fluxcd.io"], "apiVersions": ["v1"], "operations": ["UPDATE"], "resources": ["kustomizations"]},
	],
}

dedicated_admission_conditions := {
	"homelab-test-cilium-copy-diagnostics": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"},
	"homelab-test-cilium-cluster-policies": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"},
	"homelab-test-cilium-system-connect": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"},
	"homelab-test-cilium-ephemeral-diagnostics": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"},
	"homelab-test-cilium-namespaces": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-cilium-connectivity'"},
	"homelab-test-openbao-restore-pod-delete": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-restore'"},
	"homelab-test-openbao-restore-exec": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-restore'"},
	"homelab-test-openbao-restore-private": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-restore'"},
	"homelab-test-openbao-restore-storage": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-restore'"},
	"homelab-test-openbao-restore-statefulset": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-restore'"},
	"homelab-test-openbao-probe-exec": {"name": "dedicated-profile", "expression": "request.userInfo.username in ['system:serviceaccount:kube-system:homelab-test-openbao-issuance', 'system:serviceaccount:kube-system:homelab-test-openbao-ha']"},
	"homelab-test-openbao-probe-pods": {"name": "dedicated-profile", "expression": "request.userInfo.username in ['system:serviceaccount:kube-system:homelab-test-openbao-issuance', 'system:serviceaccount:kube-system:homelab-test-openbao-ha']"},
	"homelab-test-openbao-ha-eviction": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-openbao-ha'"},
	"homelab-test-openbao-member-tunnels": {"name": "dedicated-profile", "expression": "request.userInfo.username in ['system:serviceaccount:kube-system:homelab-test-openbao-ha', 'system:serviceaccount:kube-system:homelab-test-openbao-lifecycle']"},
	"homelab-test-node-plex-disruption": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-node-reschedule'"},
	"homelab-test-node-plex-runtime": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-node-reschedule'"},
	"homelab-test-node-scheduling": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-node-reschedule'"},
	"homelab-test-flux-restart": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-flux-restart'"},
	"homelab-test-flux-restart-reconcile": {"name": "dedicated-profile", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-flux-restart'"},
}

dedicated_cluster_contracts := {"homelab-test-cilium-diagnostic-observation": {"rules": [{"apiGroups": ["cilium.io"], "resources": ["ciliumcidrgroups", "ciliumegressgatewaypolicies", "ciliumlocalredirectpolicies", "ciliumendpointslices", "ciliumnodeconfigs", "ciliumpodippools", "ciliuml2announcementpolicies", "ciliumenvoyconfigs", "ciliumclusterwideenvoyconfigs", "ciliumgatewayclassconfigs", "ciliumbgppeeringpolicies", "ciliumbgpclusterconfigs", "ciliumbgppeerconfigs", "ciliumbgpadvertisements", "ciliumbgpnodeconfigs", "ciliumbgpnodeconfigoverrides", "podinfo", "tracingpolicies", "tracingpoliciesnamespaced"], "verbs": ["get", "list"]}, {"apiGroups": ["gateway.networking.k8s.io"], "resources": ["listenersets", "backendtlspolicies", "tlsroutes", "tcproutes", "udproutes", "grpcroutes"], "verbs": ["get", "list"]}, {"apiGroups": ["networking.k8s.io"], "resources": ["ingressclasses"], "verbs": ["get", "list"]}, {"apiGroups": ["policy.networking.k8s.io"], "resources": ["clusternetworkpolicies"], "verbs": ["get", "list"]}], "account": "homelab-test-cilium-connectivity"}, "homelab-test-cilium-cluster-policies": {"rules": [{"apiGroups": ["cilium.io"], "resources": ["ciliumclusterwidenetworkpolicies"], "resourceNames": ["allow-ingress-specific-namespace-ccnp", "allow-egress-specific-namespace-ccnp", "host-firewall-ingress", "host-firewall-egress"], "verbs": ["get", "patch", "delete"]}], "account": "homelab-test-cilium-connectivity"}, "homelab-test-cilium-namespaces": {"rules": [{"apiGroups": [""], "resources": ["namespaces"], "verbs": ["create"]}, {"apiGroups": [""], "resources": ["namespaces"], "resourceNames": ["cilium-test-1", "cilium-test-ccnp1", "cilium-test-ccnp2"], "verbs": ["update", "delete"]}], "account": "homelab-test-cilium-connectivity"}, "homelab-test-node-scheduling": {
	"rules": [{"apiGroups": [""], "resources": ["nodes"], "resourceNames": ["nuc1", "nuc2", "nuc3"], "verbs": ["patch"]}],
	"account": "homelab-test-node-reschedule",
}}

dedicated_cluster_role_exact(roles, contract) if {
	count(roles) == 1
	metadata_namespace(roles[0]) == ""
	object.get(roles[0], "rules", []) == contract.rules
	object.get(roles[0], "aggregationRule", null) == null
}

deny contains msg if {
	some name, contract in dedicated_cluster_contracts
	not dedicated_cluster_role_exact(publisher_documents("ClusterRole", name), contract)
	msg := sprintf("dedicated ClusterRole %s must match its named grants once", [name])
}

deny contains msg if {
	some name, contract in dedicated_cluster_contracts
	binding := {"role": name, "account": contract.account}
	not dedicated_observation_exact(publisher_documents("ClusterRoleBinding", name), name, binding)
	msg := sprintf("dedicated ClusterRoleBinding %s must bind its declared account once", [name])
}

dedicated_binding_names := object.keys(object.union(dedicated_observation_contracts, dedicated_cluster_contracts))
