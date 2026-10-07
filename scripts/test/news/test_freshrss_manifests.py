"""Restricted FreshRSS workload and private routing invariants."""

import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
NEWS = ROOT / "kubernetes/apps/news"


class FreshRSSManifestsTests(unittest.TestCase):
    def test_metrics_are_separate_from_gateway_and_alerts_are_enabled(self):
        objects = list(
            yaml.safe_load_all(
                subprocess.check_output(
                    ["kustomize", "build", str(NEWS / "freshrss/app")], text=True
                )
            )
        )
        service = next(o for o in objects if o["kind"] == "Service")
        self.assertIn(
            {"name": "metrics", "port": 9090, "targetPort": "metrics"}, service["spec"]["ports"]
        )
        monitor = next(o for o in objects if o["kind"] == "ServiceMonitor")
        self.assertEqual(monitor["spec"]["endpoints"][0]["port"], "metrics")
        policy = next(o for o in objects if o["kind"] == "CiliumNetworkPolicy")["spec"]
        metrics = [
            r
            for r in policy["ingress"]
            if any(p["port"] == "9090" for t in r["toPorts"] for p in t["ports"])
        ]
        self.assertEqual(len(metrics), 1)
        self.assertEqual(
            metrics[0]["fromEndpoints"],
            [
                {
                    "matchLabels": {
                        "k8s:io.kubernetes.pod.namespace": "monitoring",
                        "app.kubernetes.io/name": "prometheus",
                    }
                }
            ],
        )
        for rule in policy["ingress"]:
            if any(
                e["matchLabels"].get("k8s:io.kubernetes.pod.namespace") == "envoy-gateway-system"
                for e in rule["fromEndpoints"]
            ):
                self.assertEqual(
                    [p["port"] for t in rule["toPorts"] for p in t["ports"]], ["8080"]
                )
        self.assertFalse(yaml.safe_load((NEWS / "alerts/ks.yaml").read_text())["spec"]["suspend"])

    def test_private_route_is_monitored_and_verification_is_enrolled(self):
        route = yaml.safe_load((NEWS / "freshrss/app/httproute.yaml").read_text())
        values = yaml.safe_load(
            (ROOT / "kubernetes/apps/monitoring/gatus/app/values.yaml").read_text()
        )
        endpoints = [e for e in values["config"]["endpoints"] if e["name"] == "freshrss"]
        self.assertEqual(len(endpoints), 1)
        endpoint = endpoints[0]
        self.assertEqual(endpoint["group"], "News")
        self.assertEqual(endpoint["url"], "https://" + route["spec"]["hostnames"][0] + "/api/")
        self.assertIn("[STATUS] == 200", endpoint["conditions"])
        self.assertIn("[BODY] == pat(*scripts/api.js*)", endpoint["conditions"])
        catalog = yaml.safe_load((ROOT / "tests/catalog.yaml").read_text())
        for campaign in ("verification", "scoped-verification"):
            self.assertEqual(
                catalog["campaigns"][campaign]["members"].count("verification.news"), 1
            )

    def test_paired_backup_has_read_only_source_and_separate_credentials(self):
        objects = list(
            yaml.safe_load_all(
                subprocess.check_output(
                    ["kustomize", "build", str(NEWS / "freshrss/app")], text=True
                )
            )
        )
        pod = next(o for o in objects if o["kind"] == "Deployment")["spec"]["template"]["spec"]
        helper = next((c for c in pod["containers"] if c["name"] == "backup"), None)
        self.assertIsNotNone(helper, "paired backup helper missing")
        mounts = {m["name"]: m for m in helper["volumeMounts"]}
        self.assertTrue(mounts["data"]["readOnly"])
        self.assertFalse(mounts["backups"].get("readOnly", False))
        self.assertIn("runtime", mounts)
        secrets = [e["valueFrom"]["secretKeyRef"] for e in helper["env"] if "valueFrom" in e]
        self.assertEqual(
            secrets, [{"name": "news-postgresql-credentials", "key": "backup-password"}]
        )
        app = next(c for c in pod["containers"] if c["name"] == "freshrss")
        values = {e["name"]: e["value"] for e in helper["env"] if "value" in e}
        database = yaml.safe_load((NEWS / "postgresql/app/statefulset.yaml").read_text())
        self.assertEqual(values["NEWS_APP_IMAGE"], app["image"])
        self.assertEqual(values["NEWS_DATABASE_IMAGE"], helper["image"])
        self.assertEqual(
            helper["image"], database["spec"]["template"]["spec"]["containers"][0]["image"]
        )
        self.assertIn(
            "exec", app["livenessProbe"], "maintenance must not trip an HTTP liveness probe"
        )

    def test_private_single_writer_and_scoped_network(self):
        app = NEWS / "freshrss/app"
        self.assertTrue(
            (app / "kustomization.yaml").is_file(), "FreshRSS workload assembly missing"
        )
        objects = list(
            yaml.safe_load_all(
                subprocess.check_output(["kustomize", "build", str(app)], text=True)
            )
        )
        deployment = next(o for o in objects if o["kind"] == "Deployment")
        self.assertEqual(deployment["spec"]["replicas"], 1)
        self.assertEqual(deployment["spec"]["strategy"]["type"], "Recreate")
        pod = deployment["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertEqual(pod["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
        for container in pod["containers"]:
            context = container["securityContext"]
            self.assertTrue(context["runAsNonRoot"])
            self.assertGreater(context["runAsUser"], 0)
            self.assertFalse(context["allowPrivilegeEscalation"])
            self.assertTrue(context["readOnlyRootFilesystem"])
            self.assertIn("ALL", context["capabilities"]["drop"])
        image = pod["containers"][0]["image"]
        self.assertRegex(image, r"@sha256:[0-9a-f]{64}$")
        keys = {
            e["valueFrom"]["secretKeyRef"]["key"]
            for e in pod["containers"][0]["env"]
            if "valueFrom" in e
        }
        self.assertEqual(
            keys, {"operator-name", "operator-password", "api-password", "db-password"}
        )
        route = next(o for o in objects if o["kind"] == "HTTPRoute")
        self.assertEqual(route["spec"]["parentRefs"][0]["name"], "internal")
        self.assertEqual(route["spec"]["rules"][0]["backendRefs"][0]["name"], "freshrss")
        policy = next(o for o in objects if o["kind"] == "CiliumNetworkPolicy")["spec"]
        self.assertEqual(
            policy["endpointSelector"]["matchLabels"]["app.kubernetes.io/name"], "freshrss"
        )
        public = next(rule for rule in policy["egress"] if "toCIDRSet" in rule)
        excluded = public["toCIDRSet"][0]["except"]
        for address in (
            "10.0.0.0/8",
            "127.0.0.0/8",
            "169.254.0.0/16",
            "172.16.0.0/12",
            "192.168.0.0/16",
        ):
            self.assertIn(address, excluded)
        endpoints = [
            e["matchLabels"] for rule in policy["egress"] for e in rule.get("toEndpoints", [])
        ]
        self.assertEqual(
            {e.get("app.kubernetes.io/name") for e in endpoints if "app.kubernetes.io/name" in e},
            {"news-postgresql", "news-graby"},
        )
        self.assertFalse(any(o["kind"] == "CronJob" for o in objects))
        ks = yaml.safe_load((NEWS / "freshrss/ks.yaml").read_text())
        self.assertFalse(ks["spec"]["suspend"])
        self.assertIn({"name": "news-postgresql"}, ks["spec"]["dependsOn"])


if __name__ == "__main__":
    unittest.main()
