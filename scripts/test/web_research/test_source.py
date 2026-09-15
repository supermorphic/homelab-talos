"""Regressions for platform boundaries, not upstream chart implementation details."""

import copy
import importlib.util
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "web_research_source", ROOT / "scripts/validate/web_research.py"
)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)
BASE = ROOT / "kubernetes/apps/web-research"


def read(relative):
    return yaml.safe_load((BASE / relative).read_text())


class SourceBoundaryTests(unittest.TestCase):
    def test_search_policy_enables_only_the_private_pair(self):
        # Retaining another engine permits explicit automated selection and
        # discloses queries beyond the approved pair.
        settings = {
            "use_default_settings": {
                "engines": {"keep_only": ["brave", "duckduckgo"]}
            },
            "engines": [
                {"name": "brave", "disabled": False},
                {"name": "duckduckgo", "disabled": False},
            ],
        }
        self.assertEqual(validator.search_engine_errors(settings), [])
        for name in ("brave", "duckduckgo"):
            for field, value in (("disabled", True), ("inactive", True)):
                changed = copy.deepcopy(settings)
                next(e for e in changed["engines"] if e["name"] == name)[field] = value
                with self.subTest(name=name, field=field):
                    self.assertTrue(validator.search_engine_errors(changed))
        for name in ("google", "bing", "startpage", "mojeek"):
            changed = copy.deepcopy(settings)
            changed["use_default_settings"]["engines"]["keep_only"].append(name)
            changed["engines"].append({"name": name, "disabled": True})
            with self.subTest(excluded=name):
                self.assertTrue(validator.search_engine_errors(changed))

    def test_deployed_search_settings_follow_policy_and_reject_malformed_entries(self):
        settings = read("searxng/app/settings.yml")
        self.assertEqual(validator.search_engine_errors(settings), [])
        for changed in (
            {},
            {**settings, "engines": settings["engines"][:-1]},
            {**settings, "engines": [{"name": {}, "disabled": False}] * 2},
            {**settings, "engines": [settings["engines"][0]] * 2},
            {
                **settings,
                "use_default_settings": {
                    "engines": {"keep_only": ["brave", {}]}
                },
            },
        ):
            with self.subTest(changed=changed):
                self.assertTrue(validator.search_engine_errors(changed))

    def test_credentials_are_monitored_from_native_activation(self):
        resources = ["./credentials.yaml"]
        self.assertEqual(validator.monitoring_errors(False, False, resources, [], []), [])
        self.assertEqual(validator.monitoring_errors(True, True, resources, [], []), [])
        for alerts_active, native_active in ((True, False), (False, True)):
            self.assertTrue(
                validator.monitoring_errors(alerts_active, native_active, resources, [], [])
            )
        self.assertTrue(validator.monitoring_errors(True, True, [], [], []))

    def test_gatus_endpoints_and_alert_rules_activate_as_one_change(self):
        expected = read("monitoring/gatus-endpoints.yaml")["config"]["endpoints"]
        resources = ["./credentials.yaml", "./gatus.yaml"]
        self.assertEqual(
            validator.monitoring_errors(True, True, resources, expected, expected), []
        )
        self.assertTrue(validator.monitoring_errors(True, True, resources, [], expected))
        self.assertTrue(
            validator.monitoring_errors(True, True, resources, expected[:-1], expected)
        )
        self.assertTrue(validator.monitoring_errors(False, False, resources, expected, expected))
        self.assertTrue(validator.monitoring_errors(True, True, resources[:1], expected, expected))

    def test_proxy_xds_selector_must_match_rendered_controller(self):
        policy = read("crawl4ai/proxy/ciliumnetworkpolicy.yaml")
        controller = {
            "kind": "Deployment",
            "metadata": {"namespace": "envoy-gateway-system"},
            "spec": {
                "template": {
                    "metadata": {
                        "labels": {
                            "app.kubernetes.io/name": "gateway-helm",
                            "app.kubernetes.io/instance": "envoy-gateway",
                            "control-plane": "envoy-gateway",
                        }
                    }
                }
            },
        }
        self.assertEqual(validator.controller_access_errors(policy, [controller]), [])
        controller["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] = "changed"
        self.assertTrue(validator.controller_access_errors(policy, [controller]))

    def test_private_ui_cannot_move_to_public_gateway(self):
        route = read("searxng/app/httproute.yaml")
        self.assertEqual(validator.ui_errors(route), [])
        route["spec"]["parentRefs"][0]["name"] = "public-webhooks"
        self.assertIn("SearXNG must use the private HTTPS Gateway", validator.ui_errors(route))

    def test_agent_must_not_mount_signing_key(self):
        deployment = read("crawl4ai/app/deployment.yaml")
        self.assertEqual(validator.credential_mount_errors(deployment), [])
        mounts = deployment["spec"]["template"]["spec"]["containers"][1]["volumeMounts"]
        mounts[-1]["name"] = "native-bootstrap"
        self.assertIn(
            "credential agent must receive only api_token",
            validator.credential_mount_errors(deployment),
        )

    def test_key_rotation_must_not_mix_native_replicas(self):
        deployment = read("crawl4ai/app/deployment.yaml")
        deployment["spec"]["strategy"]["type"] = "RollingUpdate"
        self.assertIn(
            "native key cutover requires one Recreate replica",
            validator.credential_mount_errors(deployment),
        )

    def test_missing_or_fail_open_auth_policy_is_rejected(self):
        policy = read("crawl4ai/proxy/securitypolicy.yaml")
        self.assertEqual(validator.auth_errors(policy), [])
        policy["spec"]["extAuth"]["failOpen"] = True
        self.assertIn("authentication must fail closed with 503", validator.auth_errors(policy))
        self.assertTrue(validator.auth_errors({}))

    def test_memory_budget_counts_all_concurrent_response_caps(self):
        policy = read("crawl4ai/proxy/clienttrafficpolicy.yaml")
        proxy = read("crawl4ai/proxy/envoyproxy.yaml")
        sizing = {
            "response_cap_bytes": 8388608,
            "loaded_overhead_budget_bytes": 100663296,
            "safety_margin_bytes": 67108864,
            "shutdown_manager_memory_limit_bytes": 67108864,
            "proxy_pod_memory_limit_bytes": 335544320,
        }
        self.assertEqual(validator.buffer_errors(policy, proxy, sizing), [])
        policy["spec"]["connection"]["connectionLimit"]["value"] = 64
        self.assertIn(
            "aggregate buffering exceeds Envoy memory limit",
            validator.buffer_errors(policy, proxy, sizing),
        )

    def test_missing_connection_limit_and_extra_streams_are_rejected(self):
        policy = read("crawl4ai/proxy/clienttrafficpolicy.yaml")
        proxy = read("crawl4ai/proxy/envoyproxy.yaml")
        sizing = {
            "response_cap_bytes": 8388608,
            "loaded_overhead_budget_bytes": 100663296,
            "safety_margin_bytes": 67108864,
            "shutdown_manager_memory_limit_bytes": 67108864,
            "proxy_pod_memory_limit_bytes": 335544320,
        }
        changed = copy.deepcopy(policy)
        del changed["spec"]["connection"]["connectionLimit"]
        self.assertTrue(validator.buffer_errors(changed, proxy, sizing))
        policy["spec"]["http2"]["maxConcurrentStreams"] = 100
        self.assertIn(
            "one request and one HTTP/2 stream per connection required",
            validator.buffer_errors(policy, proxy, sizing),
        )


if __name__ == "__main__":
    unittest.main()
