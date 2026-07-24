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

is_smoke_test if {
	object.get(object.get(input, "metadata", {}), "labels", {})["homelab-talos/tier"] == "smoke"
}

operation_names(step, phase) := {
name |
	some operation in object.get(step, phase, [])
	some name in object.keys(operation)
}

deny contains msg if {
	is_smoke_test
	namespace := object.get(object.get(input, "spec", {}), "namespace", "")
	namespace != "flux-system"
	msg := sprintf("smoke test %q must use the existing flux-system namespace", [input.metadata.name])
}

deny contains msg if {
	is_smoke_test
	object.get(object.get(input, "spec", {}), "concurrent", null) != false
	msg := sprintf("smoke test %q must set spec.concurrent=false", [input.metadata.name])
}

deny contains msg if {
	is_smoke_test
	some step in object.get(object.get(input, "spec", {}), "steps", [])
	some phase in {"try", "catch", "finally", "cleanup"}
	some name in operation_names(step, phase)
	name in mutating_operations
	msg := sprintf("smoke test %q uses forbidden %s operation %q", [input.metadata.name, phase, name])
}
