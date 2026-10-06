"""Restricted FreshRSS workload and private routing invariants."""

import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
NEWS = ROOT / "kubernetes/apps/news"


class FreshRSSManifestsTests(unittest.TestCase):
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
            {"news-postgresql"},
        )
        self.assertFalse(any(o["kind"] == "CronJob" for o in objects))
        ks = yaml.safe_load((NEWS / "freshrss/ks.yaml").read_text())
        self.assertTrue(ks["spec"]["suspend"])
        self.assertIn({"name": "news-postgresql"}, ks["spec"]["dependsOn"])


if __name__ == "__main__":
    unittest.main()
