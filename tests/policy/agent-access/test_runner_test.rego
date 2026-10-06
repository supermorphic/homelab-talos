package homelab.agent_access

import rego.v1

runner_fixture_roles := {
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

runner_fixture_rules := {
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

runner_fixture_params := {
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

runner_fixture_rbac := array.concat(
	[
		object.union(service_account("homelab-test-runner"), {"automountServiceAccountToken": false}),
		cluster_role_binding("homelab-test-runner-view", ["homelab-test-runner"], "view"),
		cluster_role_binding("homelab-test-runner-observation", ["homelab-test-runner"], "homelab-observer-extra"),
	],
	array.concat(
		[role(name, namespace, contract.rules) | some name, contract in runner_fixture_roles; some namespace in contract.namespaces],
		[role_binding(name, namespace, "homelab-test-runner", "kube-system", name) | some name, contract in runner_fixture_roles; some namespace in contract.namespaces],
	),
)

runner_fixture_admission := array.concat(
	[{"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": name}, "spec": object.union(
		{
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": rules},
			"matchConditions": [{"name": "test-runner", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-runner'"}],
			"validations": [{"expression": "object.metadata.name == 'fixture'", "message": "fixture guard"}],
		},
		{"paramKind": runner_fixture_params[name].kind},
	)} |
		some name, rules in runner_fixture_rules
		"kind" in object.keys(object.get(runner_fixture_params, name, {}))
	],
	array.concat(
		[{"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicy", "metadata": {"name": name}, "spec": {
			"failurePolicy": "Fail", "matchConstraints": {"resourceRules": rules},
			"matchConditions": [{"name": "test-runner", "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-runner'"}],
			"validations": [{"expression": "object.metadata.name == 'fixture'", "message": "fixture guard"}],
		}} |
			some name, rules in runner_fixture_rules
			not "kind" in object.keys(object.get(runner_fixture_params, name, {}))
		],
		[{"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingAdmissionPolicyBinding", "metadata": {"name": name}, "spec": object.union({"policyName": name, "validationActions": ["Deny"]}, object.get(object.get(runner_fixture_params, name, {}), "binding", {}))} | some name in object.keys(runner_fixture_rules)],
	),
)

runner_fixture := array.concat(runner_fixture_rbac, runner_fixture_admission)

runner_change(kind, name, patches) := [changed |
	some document in valid_fixture
	changed := runner_changed(document, kind, name, patches)
]

runner_changed(document, kind, name, patches) := json.patch(document, patches) if {
	document.kind == kind
	document.metadata.name == name
}

runner_changed(document, kind, name, _) := document if {
	[document.kind, document.metadata.name] != [kind, name]
}

test_runner_fixture_accepted if {
	messages := deny with input as valid_fixture
	count(messages) == 0
}

test_runner_cannot_receive_broader_resource_or_verb_1 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": ["*"], "resources": ["*"], "verbs": ["*"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_cannot_receive_broader_resource_or_verb_2 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": ["rbac.authorization.k8s.io"], "resources": ["roles"], "verbs": ["create"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_cannot_receive_broader_resource_or_verb_3 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["serviceaccounts/token"], "verbs": ["create"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_cannot_receive_broader_resource_or_verb_4 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["namespaces"], "verbs": ["create"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_cannot_receive_broader_resource_or_verb_5 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["nodes"], "verbs": ["patch"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_cannot_receive_broader_resource_or_verb_6 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_cannot_receive_broader_resource_or_verb_7 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["pods"], "verbs": ["deletecollection"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_cannot_receive_broader_resource_or_verb_8 if {
	fixture := runner_change("Role", "homelab-test-media-runtime", [{"op": "add", "path": "/rules/-", "value": {"apiGroups": [""], "resources": ["users"], "verbs": ["impersonate"]}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_1 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["ServiceAccount", "homelab-test-runner", "kube-system"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_2 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["ClusterRoleBinding", "homelab-test-runner-view", ""]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_3 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["Role", "homelab-test-media-runtime", "media"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_4 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["RoleBinding", "homelab-test-media-runtime", "media"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_5 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["Role", "homelab-test-jobs", "media"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_6 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["RoleBinding", "homelab-test-jobs", "media"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_7 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["Role", "homelab-test-jobs", "automation"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_8 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["RoleBinding", "homelab-test-jobs", "automation"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_9 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["Role", "homelab-test-jobs", "automation-data"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_10 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["RoleBinding", "homelab-test-jobs", "automation-data"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_11 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["Role", "homelab-test-jobs", "gatus"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_12 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["RoleBinding", "homelab-test-jobs", "gatus"]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_13 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["ValidatingAdmissionPolicy", "homelab-test-jobs", ""]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_requires_role_or_guard_14 if {
	fixture := [document | some document in valid_fixture; [document.kind, metadata_name(document), metadata_namespace(document)] != ["ValidatingAdmissionPolicyBinding", "homelab-test-jobs", ""]]
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_rejects_wrong_binding_subject if {
	fixture := runner_change("RoleBinding", "homelab-test-jobs", [{"op": "replace", "path": "/subjects/0/name", "value": "homelab-observer"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_rejects_extra_namespace if {
	fixture := array.concat(valid_fixture, [role("homelab-test-jobs", "openbao", [{"apiGroups": ["batch"], "resources": ["jobs"], "verbs": ["create", "delete"]}])])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_guards_fail_closed_1 if {
	fixture := runner_change("ValidatingAdmissionPolicy", "homelab-test-jobs", [{"op": "replace", "path": "/spec/failurePolicy", "value": "Ignore"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_guards_fail_closed_2 if {
	fixture := runner_change("ValidatingAdmissionPolicy", "homelab-test-jobs", [{"op": "replace", "path": "/spec/matchConditions/0/expression", "value": "false"}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_guards_fail_closed_3 if {
	fixture := runner_change("ValidatingAdmissionPolicy", "homelab-test-jobs", [{"op": "add", "path": "/spec/matchConstraints/namespaceSelector", "value": {"matchLabels": {"skip": "true"}}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_guards_fail_closed_4 if {
	fixture := runner_change("ValidatingAdmissionPolicy", "homelab-test-jobs", [{"op": "replace", "path": "/spec/matchConstraints/resourceRules/0/operations", "value": ["CREATE"]}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_guards_fail_closed_5 if {
	fixture := runner_change("ValidatingAdmissionPolicy", "homelab-test-jobs", [{"op": "replace", "path": "/spec/validations", "value": []}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_binding_cannot_warn_or_skip_1 if {
	fixture := runner_change("ValidatingAdmissionPolicyBinding", "homelab-test-jobs", [{"op": "replace", "path": "/spec/validationActions", "value": ["Warn"]}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_binding_cannot_warn_or_skip_2 if {
	fixture := runner_change("ValidatingAdmissionPolicyBinding", "homelab-test-jobs", [{"op": "add", "path": "/spec/matchResources", "value": {"namespaceSelector": {"matchLabels": {"skip": "true"}}}}])
	messages := deny with input as fixture
	count(messages) > 0
}

test_runner_parameter_lookup_must_deny_missing if {
	fixture := runner_change("ValidatingAdmissionPolicyBinding", "homelab-test-provisioning-backup-source", [{"op": "replace", "path": "/spec/paramRef/parameterNotFoundAction", "value": "Allow"}])
	messages := deny with input as fixture
	count(messages) > 0
}
