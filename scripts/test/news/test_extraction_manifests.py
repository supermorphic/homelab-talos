"""Independent rendered worker and release-delivery safety invariants."""

from __future__ import annotations

import copy
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
NEWS = ROOT / "kubernetes/apps/news"


def render(path):
    return list(
        yaml.safe_load_all(subprocess.check_output(["kustomize", "build", str(path)], text=True))
    )


class ExtractionManifestsTests(unittest.TestCase):
    def invariants(self, objects, release):
        pod = next(o for o in objects if o["kind"] == "Deployment")["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertFalse(any("persistentVolumeClaim" in v for v in pod["volumes"]))
        for volume in pod["volumes"]:
            if "emptyDir" in volume:
                self.assertIn("sizeLimit", volume["emptyDir"])
        self.assertFalse(
            any(
                o["kind"] in ("HTTPRoute", "Ingress", "Secret", "PersistentVolumeClaim")
                for o in objects
            )
        )
        worker = pod["containers"][0]
        self.assertEqual(worker["image"], release["image"])
        self.assertRegex(worker["image"], r"@sha256:[a-f0-9]{64}$")
        self.assertEqual(worker["resources"]["limits"]["memory"], "512Mi")
        self.assertTrue(
            next(m for m in worker["volumeMounts"] if m["mountPath"] == "/work")["readOnly"]
        )
        for container in [*pod["containers"], *pod["initContainers"]]:
            self.assertFalse(any("valueFrom" in e for e in container.get("env", [])))
            context = container["securityContext"]
            self.assertTrue(context["runAsNonRoot"])
            self.assertTrue(context["readOnlyRootFilesystem"])
            self.assertFalse(context["allowPrivilegeEscalation"])
            self.assertIn("ALL", context["capabilities"]["drop"])
        for cm in [o for o in objects if o["kind"] == "ConfigMap"]:
            self.assertTrue(cm["immutable"])
            self.assertLess(len(json.dumps(cm).encode()), 1048576)
        policy = next(o for o in objects if o["kind"] == "CiliumNetworkPolicy")["spec"]
        allowed = {
            p["port"]: entry["matchLabels"]
            for rule in policy["ingress"]
            for entry in rule["fromEndpoints"]
            for ports in rule["toPorts"]
            for p in ports["ports"]
        }
        self.assertEqual(allowed["8080"]["app.kubernetes.io/name"], "freshrss")
        self.assertEqual(allowed["9090"]["app.kubernetes.io/name"], "prometheus")
        self.assertFalse(
            any("fromEntities" in rule or "fromCIDR" in rule for rule in policy["ingress"])
        )

    def test_worker_and_negative_boundaries(self):
        app = NEWS / "graby/app"
        self.assertTrue((app / "kustomization.yaml").is_file(), "staged worker assembly missing")
        objects = render(app)
        release = json.loads((app / "release.json").read_text())
        self.invariants(objects, release)
        for mutation in ("image", "memory", "dependencies", "token"):
            invalid = copy.deepcopy(objects)
            pod = next(o for o in invalid if o["kind"] == "Deployment")["spec"]["template"]["spec"]
            if mutation == "image":
                pod["containers"][0]["image"] = "php:latest"
            elif mutation == "memory":
                del pod["containers"][0]["resources"]["limits"]["memory"]
            elif mutation == "dependencies":
                next(m for m in pod["containers"][0]["volumeMounts"] if m["mountPath"] == "/work")[
                    "readOnly"
                ] = False
            else:
                pod["automountServiceAccountToken"] = True
            with self.assertRaises((AssertionError, KeyError)):
                self.invariants(invalid, release)

    def test_freshrss_preservation_is_independent_and_release_bound(self):
        objects = render(NEWS / "freshrss/app")
        pod = next(o for o in objects if o["kind"] == "Deployment")["spec"]["template"]["spec"]
        app = next(c for c in pod["containers"] if c["name"] == "freshrss")
        self.assertIn({"name": "NEWS_EXTRACTION_REQUESTS_ENABLED", "value": "false"}, app["env"])
        self.assertTrue(
            next(
                m
                for m in app["volumeMounts"]
                if m["mountPath"].endswith("xExtension-CommunityExtraction")
            )["readOnly"]
        )
        for container in pod["containers"]:
            self.assertTrue(
                next(
                    m
                    for m in container["volumeMounts"]
                    if m["mountPath"] == "/opt/news-extraction"
                )["readOnly"]
            )
        declared = json.loads((NEWS / "graby/app/release.json").read_text())
        self.assertEqual(app["image"], declared["freshrss_image"])
        extension = NEWS / "freshrss/app/extensions/xExtension-CommunityExtraction"
        self.assertEqual(
            declared["extension_files"],
            {
                p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in extension.iterdir()
                if p.is_file()
            },
        )
        for name in ("freshrss", "graby"):
            ks = yaml.safe_load((NEWS / name / "ks.yaml").read_text())
            self.assertTrue(ks["spec"]["suspend"])
            if name == "freshrss":
                self.assertNotIn({"name": "news-graby"}, ks["spec"]["dependsOn"])

    def test_code_changes_alter_rollout_and_every_declared_worker_file_is_mounted(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "news"
            shutil.copytree(NEWS, target)
            before = render(target / "graby/app")
            code = target / "graby/app/src/Server.php"
            code.write_text(code.read_text() + "\n// Synthetic rollout probe.\n")
            after = render(target / "graby/app")
            names = lambda objects: {
                o["metadata"]["name"] for o in objects if o["kind"] == "ConfigMap"
            }
            self.assertNotEqual(names(before), names(after))
        objects = render(NEWS / "graby/app")
        pod = next(o for o in objects if o["kind"] == "Deployment")["spec"]["template"]["spec"]
        code = next(v for v in pod["volumes"] if v["name"] == "code")["configMap"]
        paths = {item["path"] for item in code["items"]}
        declared = json.loads((NEWS / "graby/app/release.json").read_text())
        self.assertTrue(set(declared["files"]).issubset(paths))
        self.assertIn("release.json", paths)


if __name__ == "__main__":
    unittest.main()


class CandidateIngestionTests(unittest.TestCase):
    def test_different_candidate_runtime_fails_before_any_container_start(self):
        import importlib
        import os
        import sys
        import tempfile
        from unittest.mock import patch

        with patch.object(sys, "path", [str(ROOT / "scripts/test/news"), *sys.path]):
            integration = importlib.import_module("freshrss_integration")
        metadata = json.loads((ROOT / "kubernetes/apps/news/graby/app/release.json").read_text())
        metadata["freshrss_image"] = "docker.io/freshrss/freshrss@sha256:" + "0" * 64
        with tempfile.TemporaryDirectory(dir=ROOT / ".tmp") as temporary:
            Path(temporary, "release.json").write_text(json.dumps(metadata))
            with (
                patch.dict(os.environ, {"NEWS_EXTRACTION_CANDIDATE": temporary}),
                patch.object(
                    integration.subprocess,
                    "run",
                    side_effect=AssertionError("container operation before compatibility check"),
                ),
                self.assertRaisesRegex(ValueError, "FreshRSS.*image"),
            ):
                integration.main(extraction=True)
