"""Rendered database contracts; the unfinished news stack remains unselected."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "kubernetes/apps/news"


class DatabaseManifestsTests(unittest.TestCase):
    def test_database_is_private_restricted_and_recoverable(self):
        self.assertTrue(BASE.is_dir(), "news database foundation is missing")
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "news"
            shutil.copytree(BASE, target)
            app = target / "postgresql/app"
            # Never read a real Secret: this render has disposable, synthetic data.
            (app / "postgresql-credentials.sops.yaml").write_text(
                "apiVersion: v1\nkind: Secret\nmetadata:\n"
                "  name: news-postgresql-credentials\nstringData:\n"
                "  postgres-superuser-password: synthetic\n"
                "  freshrss-password: synthetic\n"
                "  backup-password: synthetic\n"
                "  monitoring-password: synthetic\n"
            )
            kustomization = yaml.safe_load((app / "kustomization.yaml").read_text())
            resource = "./postgresql-credentials.sops.yaml"
            if resource not in kustomization["resources"]:
                kustomization["resources"].append(resource)
            (app / "kustomization.yaml").write_text(yaml.safe_dump(kustomization))
            render = subprocess.run(
                ["kustomize", "build", str(app)], capture_output=True, text=True, check=True
            ).stdout
            objects = list(yaml.safe_load_all(render))
        stateful = [o for o in objects if o["kind"] == "StatefulSet"]
        self.assertEqual(len(stateful), 1)
        stateful = stateful[0]
        self.assertEqual(stateful["spec"]["replicas"], 1)
        pod = stateful["spec"]["template"]["spec"]
        self.assertIs(pod["automountServiceAccountToken"], False)
        self.assertEqual(pod["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
        database = pod["containers"][0]
        context = database["securityContext"]
        self.assertIs(context["runAsNonRoot"], True)
        self.assertGreater(context["runAsUser"], 0)
        self.assertIs(context["allowPrivilegeEscalation"], False)
        self.assertIs(context["readOnlyRootFilesystem"], True)
        self.assertIn("ALL", context["capabilities"]["drop"])
        self.assertIn("requests", database["resources"])
        self.assertIn("limits", database["resources"])
        for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
            self.assertIn("exec", database[probe])
        keys = {
            env["valueFrom"]["secretKeyRef"]["key"]
            for env in database["env"]
            if "valueFrom" in env
        }
        self.assertEqual(
            keys,
            {
                "postgres-superuser-password",
                "freshrss-password",
                "backup-password",
                "monitoring-password",
            },
        )
        self.assertTrue(
            all(
                env["valueFrom"]["secretKeyRef"]["name"] == "news-postgresql-credentials"
                for env in database["env"]
                if "valueFrom" in env
            )
        )
        service = next(o for o in objects if o["kind"] == "Service")
        self.assertEqual(service["spec"]["type"], "ClusterIP")
        self.assertEqual([p["port"] for p in service["spec"]["ports"]], [5432])
        self.assertEqual(service["spec"]["selector"], stateful["spec"]["selector"]["matchLabels"])
        pvcs = [o for o in objects if o["kind"] == "PersistentVolumeClaim"]
        fs = list(
            yaml.safe_load_all((BASE / "freshrss/app/persistentvolumeclaims.yaml").read_text())
        )
        capacities = {
            "news-postgresql-data": "10Gi",
            "news-backups": "10Gi",
            "freshrss-data": "2Gi",
        }
        self.assertEqual({p["metadata"]["name"] for p in pvcs + fs}, set(capacities))
        for pvc in pvcs + fs:
            self.assertEqual(
                pvc["metadata"]["annotations"]["kustomize.toolkit.fluxcd.io/prune"], "disabled"
            )
            self.assertEqual(pvc["spec"]["accessModes"], ["ReadWriteOnce"])
            self.assertEqual(pvc["spec"]["storageClassName"], "longhorn")
            self.assertEqual(
                pvc["spec"]["resources"]["requests"]["storage"],
                capacities[pvc["metadata"]["name"]],
            )
        policy = next(o for o in objects if o["kind"] == "CiliumNetworkPolicy")["spec"]
        self.assertEqual(policy["egress"], [])
        self.assertEqual(policy["endpointSelector"]["matchLabels"], service["spec"]["selector"])
        self.assertEqual(len(policy["ingress"]), 1)
        rule = policy["ingress"][0]
        self.assertEqual(
            rule["fromEndpoints"],
            [
                {
                    "matchLabels": {
                        "k8s:io.kubernetes.pod.namespace": "news",
                        "app.kubernetes.io/name": "freshrss",
                    }
                }
            ],
        )
        self.assertEqual(rule["toPorts"], [{"ports": [{"port": "5432", "protocol": "TCP"}]}])

    def test_flux_cannot_activate_incomplete_news(self):
        self.assertTrue(BASE.is_dir(), "news Flux definitions are missing")
        root = yaml.safe_load((ROOT / "kubernetes/apps/kustomization.yaml").read_text())
        self.assertNotIn("./news", root["resources"])
        for path in (BASE / "namespace/ks.yaml", BASE / "postgresql/ks.yaml"):
            spec = yaml.safe_load(path.read_text())["spec"]
            self.assertIs(spec["suspend"], True)
            self.assertIs(spec["wait"], True)
        namespace = yaml.safe_load((BASE / "namespace/app/namespace.yaml").read_text())
        for mode in ("enforce", "warn", "audit"):
            self.assertEqual(
                namespace["metadata"]["labels"][f"pod-security.kubernetes.io/{mode}"], "restricted"
            )
        database = yaml.safe_load((BASE / "postgresql/ks.yaml").read_text())["spec"]
        self.assertTrue(
            {"news", "longhorn", "cilium"} <= {d["name"] for d in database["dependsOn"]}
        )
        self.assertEqual(
            database["decryption"], {"provider": "sops", "secretRef": {"name": "sops-age"}}
        )


if __name__ == "__main__":
    unittest.main()
