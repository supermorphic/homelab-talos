package homelab.agent_access

import rego.v1

ordinary_role_contracts := {
	"homelab-test-news-recovery": {"namespaces": ["news-recovery-test"], "rules": [{"apiGroups": [""], "resources": ["pods", "persistentvolumeclaims", "secrets", "configmaps"], "verbs": ["get", "create", "delete"]}, {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["create"]}, {"apiGroups": [""], "resources": ["resourcequotas"], "resourceNames": ["recovery"], "verbs": ["get"]}, {"apiGroups": ["cilium.io"], "resources": ["ciliumnetworkpolicies"], "resourceNames": ["isolation"], "verbs": ["get"]}]},
	"homelab-test-jobs": {
		"namespaces": [
			"media",
			"automation",
			"automation-data",
			"gatus",
		],
		"rules": [{
			"apiGroups": ["batch"],
			"resources": ["jobs"],
			"verbs": [
				"create",
				"delete",
			],
		}],
	},
	"homelab-test-network-policies": {
		"namespaces": [
			"automation",
			"automation-data",
			"gatus",
		],
		"rules": [{
			"apiGroups": ["cilium.io"],
			"resources": ["ciliumnetworkpolicies"],
			"verbs": [
				"create",
				"delete",
			],
		}],
	},
	"homelab-test-media-runtime": {
		"namespaces": ["media"],
		"rules": [
			{
				"apiGroups": [""],
				"resources": ["pods"],
				"verbs": ["create"],
			},
			{
				"apiGroups": [""],
				"resources": ["pods/exec"],
				"verbs": [
					"get",
					"create",
				],
			},
		],
	},
	"homelab-test-report-read": {
		"namespaces": ["test-reports"],
		"rules": [{
			"apiGroups": [""],
			"resources": ["pods/exec"],
			"verbs": [
				"get",
				"create",
			],
		}],
	},
	"homelab-test-disruption": {
		"namespaces": [
			"automation",
			"media",
			"portainer",
			"tailscale",
			"test-reports",
		],
		"rules": [{
			"apiGroups": [""],
			"resources": ["pods"],
			"verbs": ["delete"],
		}],
	},
	"homelab-test-storage": {
		"namespaces": ["longhorn-system"],
		"rules": [{
			"apiGroups": [""],
			"resources": ["persistentvolumeclaims"],
			"verbs": [
				"create",
				"get",
				"list",
				"watch",
				"delete",
			],
		}],
	},
	"homelab-test-restore-storage": {
		"namespaces": [
			"automation",
			"automation-data",
		],
		"rules": [{
			"apiGroups": [""],
			"resources": ["persistentvolumeclaims"],
			"verbs": [
				"create",
				"delete",
			],
		}],
	},
	"homelab-test-restore-services": {
		"namespaces": ["automation-data"],
		"rules": [{
			"apiGroups": [""],
			"resources": ["services"],
			"verbs": [
				"create",
				"delete",
			],
		}],
	},
	"homelab-test-restore-databases": {
		"namespaces": [
			"automation",
			"automation-data",
		],
		"rules": [{
			"apiGroups": ["apps"],
			"resources": ["statefulsets"],
			"verbs": [
				"create",
				"delete",
			],
		}],
	},
	"homelab-test-restore-applications": {
		"namespaces": ["automation-data"],
		"rules": [{
			"apiGroups": ["apps"],
			"resources": ["deployments"],
			"verbs": [
				"create",
				"delete",
			],
		}],
	},
	"homelab-test-application-fixtures": {
		"namespaces": ["automation"],
		"rules": [
			{
				"apiGroups": ["apps"],
				"resources": ["deployments"],
				"verbs": [
					"create",
					"delete",
				],
			},
			{
				"apiGroups": [""],
				"resources": ["services"],
				"verbs": [
					"create",
					"delete",
				],
			},
		],
	},
	"homelab-test-flux-fixtures": {
		"namespaces": ["flux-system"],
		"rules": [{
			"apiGroups": ["kustomize.toolkit.fluxcd.io"],
			"resources": ["kustomizations"],
			"verbs": [
				"create",
				"delete",
			],
		}],
	},
	"homelab-test-flux-canary": {
		"namespaces": ["flux-system"],
		"rules": [{
			"apiGroups": [""],
			"resources": ["secrets"],
			"verbs": [
				"get",
				"delete",
			],
			"resourceNames": ["flux-canary"],
		}],
	},
	"homelab-test-flux-reconcile": {
		"namespaces": ["flux-system"],
		"rules": [
			{
				"apiGroups": ["source.toolkit.fluxcd.io"],
				"resources": ["gitrepositories"],
				"verbs": [
					"patch",
					"update",
				],
				"resourceNames": ["flux-system"],
			},
			{
				"apiGroups": ["kustomize.toolkit.fluxcd.io"],
				"resources": ["kustomizations"],
				"verbs": [
					"patch",
					"update",
				],
				"resourceNames": ["flux-canary"],
			},
		],
	},
	"homelab-test-nocodb-credential": {
		"namespaces": ["automation-data"],
		"rules": [{
			"apiGroups": [""],
			"resources": ["secrets"],
			"verbs": [
				"get",
				"patch",
				"update",
			],
			"resourceNames": ["nocodb-restore-application-credential"],
		}],
	},
}

ordinary_admission_rules := {
	"homelab-test-news-pods": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["pods"]}],
	"homelab-test-news-inputs": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE", "DELETE"], "resources": ["persistentvolumeclaims", "secrets", "configmaps"]}],
	"homelab-test-news-exec": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CONNECT"], "resources": ["pods/exec"]}],
	"homelab-test-wan-reference-pods": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["pods"],
	}],
	"homelab-test-probe-pods": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["pods"],
	}],
	"homelab-test-media-runtime": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": ["CONNECT"],
		"resources": ["pods/exec"],
	}],
	"homelab-test-report-exec": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": ["CONNECT"],
		"resources": ["pods/exec"],
	}],
	"homelab-test-storage": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["persistentvolumeclaims"],
	}],
	"homelab-test-n8n-restore-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-qbit-manage-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-n8n-persistence-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-n8n-request-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-restore-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-restore-request-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-provisioning-jobs": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-nocodb-application-probe": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-disruption": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": ["DELETE"],
		"resources": ["pods"],
	}],
	"homelab-test-n8n-applications": [{
		"apiGroups": ["apps"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["deployments"],
	}],
	"homelab-test-nocodb-applications": [{
		"apiGroups": ["apps"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["deployments"],
	}],
	"homelab-test-services": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["services"],
	}],
	"homelab-test-network-policies": [{
		"apiGroups": ["cilium.io"],
		"apiVersions": ["v2"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["ciliumnetworkpolicies"],
	}],
	"homelab-test-restore-network-policies": [{
		"apiGroups": ["cilium.io"],
		"apiVersions": ["v2"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["ciliumnetworkpolicies"],
	}],
	"homelab-test-restore-databases": [{
		"apiGroups": ["apps"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
			"DELETE",
		],
		"resources": ["statefulsets"],
	}],
	"homelab-test-flux-fixtures": [{
		"apiGroups": ["kustomize.toolkit.fluxcd.io"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"DELETE",
		],
		"resources": ["kustomizations"],
	}],
	"homelab-test-flux-reconcile": [
		{
			"apiGroups": ["source.toolkit.fluxcd.io"],
			"apiVersions": ["v1"],
			"operations": ["UPDATE"],
			"resources": ["gitrepositories"],
		},
		{
			"apiGroups": ["kustomize.toolkit.fluxcd.io"],
			"apiVersions": ["v1"],
			"operations": ["UPDATE"],
			"resources": ["kustomizations"],
		},
	],
	"homelab-test-workload-security": [
		{
			"apiGroups": ["batch"],
			"apiVersions": ["v1"],
			"operations": [
				"CREATE",
				"UPDATE",
				"DELETE",
			],
			"resources": ["jobs"],
		},
		{
			"apiGroups": ["apps"],
			"apiVersions": ["v1"],
			"operations": [
				"CREATE",
				"UPDATE",
				"DELETE",
			],
			"resources": ["deployments"],
		},
	],
	"homelab-test-ad-restore-hosts": [{
		"apiGroups": ["apps"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
		],
		"resources": ["deployments"],
	}],
	"homelab-test-nc-restore-hosts": [{
		"apiGroups": ["apps"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
		],
		"resources": ["deployments"],
	}],
	"homelab-test-provisioning-backup-source": [{
		"apiGroups": ["batch"],
		"apiVersions": ["v1"],
		"operations": [
			"CREATE",
			"UPDATE",
		],
		"resources": ["jobs"],
	}],
	"homelab-test-nocodb-credential": [{
		"apiGroups": [""],
		"apiVersions": ["v1"],
		"operations": ["UPDATE"],
		"resources": ["secrets"],
	}],
}

ordinary_admission_params := {
	"homelab-test-news-pods": {"binding": {"matchResources": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "news-recovery-test"}}}}},
	"homelab-test-news-inputs": {"binding": {"matchResources": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "news-recovery-test"}}}}},
	"homelab-test-news-exec": {"binding": {"matchResources": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "news-recovery-test"}}}}},
	"homelab-test-ad-restore-hosts": {
		"kind": {
			"apiVersion": "v1",
			"kind": "Service",
		},
		"binding": {
			"matchResources": {
				"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "automation"}},
				"objectSelector": {"matchLabels": {"homelab-talos/test": "automation-data-restore-drill"}},
			},
			"paramRef": {
				"namespace": "automation-data",
				"selector": {"matchLabels": {
					"homelab-talos/test": "automation-data-restore-drill",
					"homelab-talos/role": "ad-database",
				}},
				"parameterNotFoundAction": "Deny",
			},
		},
	},
	"homelab-test-nc-restore-hosts": {
		"kind": {
			"apiVersion": "v1",
			"kind": "Service",
		},
		"binding": {
			"matchResources": {
				"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "automation-data"}},
				"objectSelector": {"matchLabels": {"homelab-talos/test": "nocodb-restore-drill"}},
			},
			"paramRef": {
				"namespace": "automation-data",
				"selector": {"matchLabels": {
					"homelab-talos/test": "nocodb-restore-drill",
					"homelab-talos/role": "database",
				}},
				"parameterNotFoundAction": "Deny",
			},
		},
	},
	"homelab-test-provisioning-backup-source": {
		"kind": {
			"apiVersion": "batch/v1",
			"kind": "CronJob",
		},
		"binding": {
			"paramRef": {
				"name": "automation-data-postgresql-backup",
				"namespace": "automation-data",
				"parameterNotFoundAction": "Deny",
			},
			"matchResources": {
				"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "automation-data"}},
				"objectSelector": {"matchLabels": {
					"homelab-talos/test": "automation-data-provisioning",
					"homelab-talos/role": "backup",
				}},
			},
		},
	},
}

ordinary_role_names := object.keys(ordinary_role_contracts)
controlled_admission_rules := object.union(ordinary_admission_rules, dedicated_admission_rules)
controlled_admission_names := object.keys(controlled_admission_rules)
runner_subjects := [{"kind": "ServiceAccount", "name": "homelab-test-runner", "namespace": "kube-system"}]

ordinary_documents(kind, name, namespace) := [document |
	some document in documents
	document.kind == kind
	metadata_name(document) == name
	metadata_namespace(document) == namespace
]

deny contains "test-runner must be tokenless and exist exactly once" if {
	accounts := ordinary_documents("ServiceAccount", "homelab-test-runner", "kube-system")
	not runner_account_exact(accounts)
}

runner_account_exact(accounts) if {
	count(accounts) == 1
	accounts[0].automountServiceAccountToken == false
}

deny contains msg if {
	some name, contract in ordinary_role_contracts
	some namespace in contract.namespaces
	some kind in {"Role", "RoleBinding"}
	matches := ordinary_documents(kind, name, namespace)
	count(matches) != 1
	msg := sprintf("test-runner %s %s/%s must exist once", [kind, namespace, name])
}

ordinary_role_exact(document, name) if {
	contract := ordinary_role_contracts[name]
	metadata_namespace(document) in contract.namespaces
	object.get(document, "rules", []) == contract.rules
	object.get(document, "aggregationRule", null) == null
}

ordinary_binding_exact(document, name) if {
	metadata_namespace(document) in ordinary_role_contracts[name].namespaces
	object.get(document, "subjects", []) == runner_subjects
	object.get(document, "roleRef", {}) == {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": name}
}

deny contains msg if {
	some document in documents
	document.kind == "Role"
	name := metadata_name(document)
	name in ordinary_role_names
	not ordinary_role_exact(document, name)
	msg := sprintf("test-runner Role %s must match its exact namespace and grants", [name])
}

deny contains msg if {
	some document in documents
	document.kind == "RoleBinding"
	name := metadata_name(document)
	name in ordinary_role_names
	not ordinary_binding_exact(document, name)
	msg := sprintf("test-runner RoleBinding %s must match its exact namespace and subject", [name])
}

runner_observation_bindings := {"homelab-test-runner-view": "view", "homelab-test-runner-observation": "homelab-observer-extra"}

deny contains msg if {
	some name, role_name in runner_observation_bindings
	bindings := publisher_documents("ClusterRoleBinding", name)
	not runner_observation_exact(bindings, name, role_name)
	msg := sprintf("test-runner observation binding %s must exist once with its exact subject", [name])
}

runner_observation_exact(bindings, name, role_name) if {
	count(bindings) == 1
	has_binding(name, role_name, {"ServiceAccount:kube-system:homelab-test-runner"})
	metadata_namespace(bindings[0]) == ""
}

deny contains msg if {
	some name in controlled_admission_names
	some kind in {"ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"}
	guards := publisher_documents(kind, name)
	count(guards) != 1
	msg := sprintf("test-runner %s %s must exist once", [kind, name])
}

ordinary_admission_exact(document, name) if {
	metadata_namespace(document) == ""
	spec := object.get(document, "spec", {})
	spec.failurePolicy == "Fail"
	spec.matchConstraints == {"resourceRules": controlled_admission_rules[name]}
	conditions := object.get(spec, "matchConditions", [])
	count(conditions) >= 1
	conditions[0] == object.get(dedicated_admission_conditions, name, {"name": "test-runner", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-runner'"})
	validations := object.get(spec, "validations", [])
	count(validations) > 0
	every validation in validations { is_string(validation.expression); validation.expression != ""; validation.expression != "true"}
	object.get(spec, "paramKind", null) == object.get(object.get(ordinary_admission_params, name, {}), "kind", null)
}

ordinary_admission_binding_exact(document, name) if {
	metadata_namespace(document) == ""
	document.spec == object.union({"policyName": name, "validationActions": ["Deny"]}, object.get(object.get(ordinary_admission_params, name, {}), "binding", {}))
}

deny contains msg if {
	some document in documents
	document.kind == "ValidatingAdmissionPolicy"
	name := metadata_name(document)
	name in controlled_admission_names
	not ordinary_admission_exact(document, name)
	msg := sprintf("test-runner policy %s must fail closed over its declared API requests", [name])
}

deny contains msg if {
	some document in documents
	document.kind == "ValidatingAdmissionPolicyBinding"
	name := metadata_name(document)
	name in controlled_admission_names
	not ordinary_admission_binding_exact(document, name)
	msg := sprintf("test-runner policy binding %s must deny without bypass selectors", [name])
}
