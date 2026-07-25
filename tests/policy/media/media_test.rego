package homelab.media

import rego.v1

fixture(tag, strategy, app_capabilities, dependencies, gateway, audience, claim) := [
	{
		"path": "kubernetes/apps/media/qbittorrent/app/values.yaml",
		"contents": {
			"controllers": {"qbittorrent": {
				"strategy": strategy,
				"initContainers": {"gluetun": {
					"image": {"tag": "v3.41.1"},
					"securityContext": {"capabilities": {"add": ["NET_ADMIN"]}},
				}},
				"containers": {"app": {
					"image": {"tag": tag},
					"securityContext": {"capabilities": app_capabilities},
				}},
			}},
			"persistence": {
				"config": {"accessMode": "ReadWriteOnce"},
				"data": {"existingClaim": claim},
			},
		},
	},
	{
		"path": "kubernetes/apps/media/qbittorrent/ks.yaml",
		"contents": {"spec": {"dependsOn": [{"name": dependency} | some dependency in dependencies]}},
	},
	{
		"path": "kubernetes/apps/media/qbittorrent/app/httproute.yaml",
		"contents": {
			"metadata": {"annotations": {"external-dns.k8s.io/audience": audience}},
			"spec": {"parentRefs": [{"name": gateway}]},
		},
	},
]

valid_fixture := fixture(
	"5.2.3",
	"Recreate",
	{"drop": ["ALL"]},
	{"media-storage", "internal-gateway"},
	"internal",
	"internal",
	"media-data",
)

config_only_fixture(extra_persistence) := [
	{
		"path": "kubernetes/apps/media/prowlarr/app/values.yaml",
		"contents": {
			"controllers": {"prowlarr": {
				"strategy": "Recreate",
				"containers": {"app": {
					"image": {"tag": "2.1.5.5216"},
					"securityContext": {"capabilities": {"drop": ["ALL"]}},
				}},
			}},
			"persistence": object.union(
				{"config": {"accessMode": "ReadWriteOnce"}},
				extra_persistence,
			),
		},
	},
	{
		"path": "kubernetes/apps/media/prowlarr/ks.yaml",
		"contents": {"spec": {"dependsOn": [
			{"name": "media"},
			{"name": "internal-gateway"},
		]}},
	},
	{
		"path": "kubernetes/apps/media/prowlarr/app/httproute.yaml",
		"contents": {
			"metadata": {"annotations": {"external-dns.k8s.io/audience": "internal"}},
			"spec": {"parentRefs": [{"name": "internal"}]},
		},
	},
]

messages_matching(messages, fragment) := {
message |
	some message in messages
	contains(message, fragment)
}

test_valid_media_app_has_no_violations if {
	messages := deny with input as valid_fixture
	count(messages) == 0
}

host_namespace_fixture(namespace) := [{
	"path": "kubernetes/apps/media/qbittorrent/app/values.yaml",
	"contents": {"controllers": {"qbittorrent": {"pod": {namespace: true}}}},
}]

test_host_network_is_denied if {
	messages := deny with input as host_namespace_fixture("hostNetwork")
	count(messages_matching(messages, "must not enable host namespace hostNetwork")) == 1
}

test_host_pid_is_denied if {
	messages := deny with input as host_namespace_fixture("hostPID")
	count(messages_matching(messages, "must not enable host namespace hostPID")) == 1
}

test_host_ipc_is_denied if {
	messages := deny with input as host_namespace_fixture("hostIPC")
	count(messages_matching(messages, "must not enable host namespace hostIPC")) == 1
}

test_host_namespace_false_is_allowed if {
	fixture_input := [{
		"path": "kubernetes/apps/media/qbittorrent/app/values.yaml",
		"contents": {"controllers": {"qbittorrent": {"pod": {"hostNetwork": false}}}},
	}]
	messages := deny with input as fixture_input
	count(messages_matching(messages, "host namespace")) == 0
}

test_mutable_tag_is_denied if {
	fixture_input := fixture(
		"latest",
		"Recreate",
		{"drop": ["ALL"]},
		{"media-storage", "internal-gateway"},
		"internal",
		"internal",
		"media-data",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "uses mutable image tag")) == 1
}

test_rwo_requires_recreate if {
	fixture_input := fixture(
		"5.2.3",
		"RollingUpdate",
		{"drop": ["ALL"]},
		{"media-storage", "internal-gateway"},
		"internal",
		"internal",
		"media-data",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "must use Recreate")) == 1
}

test_net_admin_is_denied_outside_gluetun if {
	fixture_input := fixture(
		"5.2.3",
		"Recreate",
		{"add": ["NET_ADMIN"], "drop": ["ALL"]},
		{"media-storage", "internal-gateway"},
		"internal",
		"internal",
		"media-data",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "NET_ADMIN is forbidden")) == 1
}

test_missing_dependency_is_denied if {
	fixture_input := fixture(
		"5.2.3",
		"Recreate",
		{"drop": ["ALL"]},
		{"media-storage"},
		"internal",
		"internal",
		"media-data",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "required Flux dependency")) == 1
}

test_public_gateway_is_denied if {
	fixture_input := fixture(
		"5.2.3",
		"Recreate",
		{"drop": ["ALL"]},
		{"media-storage", "internal-gateway"},
		"public",
		"internal",
		"media-data",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "Gateway parentRef must be internal")) == 1
}

test_public_dns_audience_is_denied if {
	fixture_input := fixture(
		"5.2.3",
		"Recreate",
		{"drop": ["ALL"]},
		{"media-storage", "internal-gateway"},
		"internal",
		"external",
		"media-data",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "external-dns audience must be internal")) == 1
}

test_application_container_must_drop_all_capabilities if {
	fixture_input := fixture(
		"5.2.3",
		"Recreate",
		{"drop": []},
		{"media-storage", "internal-gateway"},
		"internal",
		"internal",
		"media-data",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "must drop all Linux capabilities")) == 1
}

test_shared_media_claim_is_required if {
	fixture_input := fixture(
		"5.2.3",
		"Recreate",
		{"drop": ["ALL"]},
		{"media-storage", "internal-gateway"},
		"internal",
		"internal",
		"other-claim",
	)
	messages := deny with input as fixture_input
	count(messages_matching(messages, "existingClaim must be media-data")) == 1
}

test_unknown_media_app_is_denied if {
	fixture_input := [{
		"path": "kubernetes/apps/media/unknown/app/values.yaml",
		"contents": {},
	}]
	messages := deny with input as fixture_input
	count(messages_matching(messages, "media policy is undefined")) == 1
}

test_missing_controller_is_denied if {
	fixture_input := json.patch(valid_fixture, [{
		"op": "remove",
		"path": "/0/contents/controllers/qbittorrent",
	}])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "expected controller")) == 1
}

test_missing_image_tag_is_denied if {
	fixture_input := json.patch(valid_fixture, [{
		"op": "remove",
		"path": "/0/contents/controllers/qbittorrent/containers/app/image/tag",
	}])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "image tag is missing")) == 1
}

test_config_access_mode_must_be_single_writer if {
	fixture_input := json.patch(valid_fixture, [{
		"op": "replace",
		"path": "/0/contents/persistence/config/accessMode",
		"value": "ReadWriteMany",
	}])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "config PVC must use")) == 1
}

test_missing_flux_kustomization_is_denied if {
	fixture_input := [
	document |
		some document in valid_fixture
		not endswith(document.path, "/ks.yaml")
	]
	messages := deny with input as fixture_input
	count(messages_matching(messages, "Flux Kustomization source is missing")) == 1
}

test_missing_http_route_is_denied if {
	fixture_input := [
	document |
		some document in valid_fixture
		not endswith(document.path, "/httproute.yaml")
	]
	messages := deny with input as fixture_input
	count(messages_matching(messages, "HTTPRoute source is missing")) == 1
}

test_route_requires_gateway_parent if {
	fixture_input := json.patch(valid_fixture, [{
		"op": "replace",
		"path": "/2/contents/spec/parentRefs",
		"value": [],
	}])
	messages := deny with input as fixture_input
	count(messages_matching(messages, "at least one Gateway parentRef")) == 1
}

test_config_only_app_must_not_define_data if {
	fixture_input := config_only_fixture({"data": {"existingClaim": "media-data"}})
	messages := deny with input as fixture_input
	count(messages_matching(messages, "must not define persistence.data")) == 1
}

test_config_only_app_must_not_define_media if {
	fixture_input := config_only_fixture({"media": {"existingClaim": "media-data"}})
	messages := deny with input as fixture_input
	count(messages_matching(messages, "must not define persistence.media")) == 1
}
