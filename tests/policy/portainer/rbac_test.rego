package homelab.portainer

import rego.v1

role(rules) := {
	"apiVersion": "rbac.authorization.k8s.io/v1",
	"kind": "ClusterRole",
	"metadata": {"name": "portainer-readonly"},
	"rules": rules,
}

messages_matching(messages, fragment) := {
message |
	some message in messages
	contains(message, fragment)
}

test_valid_read_only_role if {
	messages := deny with input as role([{
		"apiGroups": [""],
		"resources": ["pods"],
		"verbs": ["get", "list", "watch"],
	}])
	count(messages) == 0
}

test_mutating_verb_is_denied if {
	messages := deny with input as role([{
		"apiGroups": [""],
		"resources": ["pods"],
		"verbs": ["get", "patch"],
	}])
	count(messages_matching(messages, "forbidden verb")) == 1
}

test_wildcard_is_denied if {
	messages := deny with input as role([{
		"apiGroups": ["*"],
		"resources": ["pods"],
		"verbs": ["get"],
	}])
	count(messages_matching(messages, "wildcard")) == 1
}

test_secret_access_is_denied if {
	messages := deny with input as role([{
		"apiGroups": [""],
		"resources": ["secrets"],
		"verbs": ["get"],
	}])
	count(messages_matching(messages, "forbidden resource")) == 1
}

test_pod_exec_is_denied if {
	messages := deny with input as role([{
		"apiGroups": [""],
		"resources": ["pods/exec"],
		"verbs": ["get"],
	}])
	count(messages_matching(messages, "forbidden resource")) == 1
}

test_cluster_admin_binding_is_denied if {
	binding := {
		"apiVersion": "rbac.authorization.k8s.io/v1",
		"kind": "ClusterRoleBinding",
		"metadata": {"name": "portainer-readonly"},
		"roleRef": {
			"apiGroup": "rbac.authorization.k8s.io",
			"kind": "ClusterRole",
			"name": "cluster-admin",
		},
	}
	messages := deny with input as binding
	count(messages_matching(messages, "must reference only portainer-readonly")) == 1
}
