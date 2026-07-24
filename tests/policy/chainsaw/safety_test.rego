package homelab.chainsaw

import rego.v1

smoke_fixture(operation) := {
	"apiVersion": "chainsaw.kyverno.io/v1alpha1",
	"kind": "Test",
	"metadata": {
		"name": "fixture",
		"labels": {
			"homelab-talos/tier": "smoke",
			"homelab-talos/target": "cluster",
			"homelab-talos/suite": "default",
		},
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
	fixture := json.patch(smoke_fixture({"assert": {"resource": {}}}), [{
		"op": "replace",
		"path": "/spec/namespace",
		"value": "other",
	}])
	messages := deny with input as fixture
	count(messages) == 1
}

test_smoke_requires_tier_label if {
	fixture := json.patch(smoke_fixture({"assert": {"resource": {}}}), [{
		"op": "remove",
		"path": "/metadata/labels/homelab-talos~1tier",
	}])
	messages := deny with input as fixture
	count(messages) == 1
}

test_smoke_requires_dispatch_labels if {
	fixture := json.patch(smoke_fixture({"assert": {"resource": {}}}), [{
		"op": "remove",
		"path": "/metadata/labels/homelab-talos~1suite",
	}])
	messages := deny with input as fixture
	count(messages) == 1
}

test_smoke_requires_concurrency_off if {
	fixture := json.patch(smoke_fixture({"assert": {"resource": {}}}), [{
		"op": "replace",
		"path": "/spec/concurrent",
		"value": true,
	}])
	messages := deny with input as fixture
	count(messages) == 1
}

test_mutating_test_level_catch_is_denied if {
	fixture := json.patch(smoke_fixture({"assert": {"resource": {}}}), [{
		"op": "add",
		"path": "/spec/catch",
		"value": [{"script": {"content": "true"}}],
	}])
	messages := deny with input as fixture
	count(messages) == 1
	"smoke test \"fixture\" uses forbidden test-level catch operation \"script\"" in messages
}

test_mutating_step_cleanup_is_denied if {
	fixture := json.patch(smoke_fixture({"assert": {"resource": {}}}), [{
		"op": "add",
		"path": "/spec/steps/0/cleanup",
		"value": [{"delete": {"ref": {}}}],
	}])
	messages := deny with input as fixture
	count(messages) == 1
	"smoke test \"fixture\" uses forbidden cleanup operation \"delete\"" in messages
}

test_mutating_configuration_catch_is_denied if {
	fixture := {
		"apiVersion": "chainsaw.kyverno.io/v1alpha2",
		"kind": "Configuration",
		"metadata": {"name": "fixture"},
		"spec": {"error": {"catch": [{"command": {"entrypoint": "true"}}]}},
	}
	messages := deny with input as fixture
	count(messages) == 1
	"Chainsaw configuration uses forbidden global catch operation \"command\"" in messages
}
