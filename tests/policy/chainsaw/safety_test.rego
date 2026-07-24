package homelab.chainsaw

import rego.v1

smoke_fixture(operation) := {
	"apiVersion": "chainsaw.kyverno.io/v1alpha1",
	"kind": "Test",
	"metadata": {
		"name": "fixture",
		"labels": {"homelab-talos/tier": "smoke"},
	},
	"spec": {
		"namespace": "flux-system",
		"concurrent": false,
		"steps": [{"try": [operation]}],
	},
}

test_read_only_smoke_is_allowed if {
	messages := deny with input as smoke_fixture({"assert": {"resource": {}}})
	count(messages) == 0
}

test_mutating_smoke_is_denied if {
	messages := deny with input as smoke_fixture({"apply": {"resource": {}}})
	count(messages) == 1
	"smoke test \"fixture\" uses forbidden try operation \"apply\"" in messages
}

test_smoke_requires_existing_namespace if {
	fixture := object.union(
		smoke_fixture({"assert": {"resource": {}}}),
		{"spec": {"namespace": "other", "concurrent": false, "steps": []}},
	)
	messages := deny with input as fixture
	count(messages) == 1
}
