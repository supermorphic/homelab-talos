package homelab.chainsaw

import rego.v1

mutating_operations := {
	"apply",
	"command",
	"create",
	"delete",
	"patch",
	"script",
	"update",
}

is_chainsaw_test if {
	input.apiVersion == "chainsaw.kyverno.io/v1alpha1"
	input.kind == "Test"
}

is_chainsaw_configuration if {
	startswith(input.apiVersion, "chainsaw.kyverno.io/")
	input.kind == "Configuration"
}

operation_names(step, phase) := {
name |
	some operation in object.get(step, phase, [])
	some name in object.keys(operation)
}

deny contains msg if {
	is_chainsaw_test
	labels := object.get(object.get(input, "metadata", {}), "labels", {})
	object.get(labels, "homelab-talos/tier", "") != "smoke"
	msg := sprintf("smoke test %q must set label homelab-talos/tier=smoke", [input.metadata.name])
}

deny contains msg if {
	is_chainsaw_test
	labels := object.get(object.get(input, "metadata", {}), "labels", {})
	some label in {"homelab-talos/target", "homelab-talos/suite"}
	object.get(labels, label, "") == ""
	msg := sprintf("smoke test %q must set non-empty label %s", [input.metadata.name, label])
}

deny contains msg if {
	is_chainsaw_test
	namespace := object.get(object.get(input, "spec", {}), "namespace", "")
	namespace != "flux-system"
	msg := sprintf("smoke test %q must use the existing flux-system namespace", [input.metadata.name])
}

deny contains msg if {
	is_chainsaw_test
	object.get(object.get(input, "spec", {}), "concurrent", null) != false
	msg := sprintf("smoke test %q must set spec.concurrent=false", [input.metadata.name])
}

deny contains msg if {
	is_chainsaw_test
	some step in object.get(object.get(input, "spec", {}), "steps", [])
	some phase in {"try", "catch", "finally", "cleanup"}
	some name in operation_names(step, phase)
	name in mutating_operations
	msg := sprintf("smoke test %q uses forbidden %s operation %q", [input.metadata.name, phase, name])
}

deny contains msg if {
	is_chainsaw_test
	spec := object.get(input, "spec", {})
	some name in operation_names(spec, "catch")
	name in mutating_operations
	msg := sprintf("smoke test %q uses forbidden test-level catch operation %q", [input.metadata.name, name])
}

deny contains msg if {
	is_chainsaw_configuration
	error_options := object.get(object.get(input, "spec", {}), "error", {})
	some name in operation_names(error_options, "catch")
	name in mutating_operations
	msg := sprintf("Chainsaw configuration uses forbidden global catch operation %q", [name])
}
