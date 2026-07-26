package homelab.portainer

import rego.v1

allowed_verbs := {"get", "list", "watch"}
forbidden_resources := {"secrets", "pods/attach", "pods/exec", "pods/portforward"}

is_portainer_cluster_role if {
	input.kind == "ClusterRole"
	object.get(object.get(input, "metadata", {}), "name", "") == "portainer-readonly"
}

is_portainer_binding if {
	input.kind == "ClusterRoleBinding"
	object.get(object.get(input, "metadata", {}), "name", "") == "portainer-readonly"
}

deny contains msg if {
	is_portainer_cluster_role
	some rule in object.get(input, "rules", [])
	some verb in object.get(rule, "verbs", [])
	not verb in allowed_verbs
	msg := sprintf("portainer-readonly uses forbidden verb %q", [verb])
}

deny contains msg if {
	is_portainer_cluster_role
	some rule in object.get(input, "rules", [])
	some value in array.concat(
		array.concat(object.get(rule, "apiGroups", []), object.get(rule, "resources", [])),
		object.get(rule, "verbs", []),
	)
	value == "*"
	msg := "portainer-readonly must not use wildcard API groups, resources, or verbs"
}

deny contains msg if {
	is_portainer_cluster_role
	some rule in object.get(input, "rules", [])
	some resource in object.get(rule, "resources", [])
	resource in forbidden_resources
	msg := sprintf("portainer-readonly exposes forbidden resource %q", [resource])
}

deny contains msg if {
	is_portainer_binding
	object.get(object.get(input, "roleRef", {}), "name", "") != "portainer-readonly"
	msg := "portainer-readonly binding must reference only portainer-readonly"
}
