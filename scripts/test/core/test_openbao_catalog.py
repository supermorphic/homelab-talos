"""OpenBao assurance stays staged until its durable Flux activation."""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.test import catalog_validator

ROOT = Path(__file__).resolve().parents[3]
CATALOG = ROOT / "tests/catalog.yaml"
MUTATING = {"test.openbao-issuance", "test.openbao-ha", "test.openbao-restore-drill"}


class OpenBaoCatalogTests(unittest.TestCase):
    def test_staged_catalog_registration(self):
        catalog = yaml.safe_load(CATALOG.read_text())
        suites = {entry["metadata"]["id"]: entry for entry in catalog["suites"]}
        for execution in ("ci", "ci-core"):
            self.assertIn("validation.openbao", catalog["executions"][execution])
        self.assertEqual(
            suites["validation.openbao"]["runner"]["implementation"],
            "scripts/validate/openbao.sh",
        )
        verifier = suites["verification.openbao"]
        self.assertEqual(verifier["access"]["tier"], "diagnostic")
        self.assertFalse(verifier["metadata"]["mutates_cluster"])
        self.assertIn("verification.openbao", catalog_validator.campaign_exclusions())
        for campaign in ("verification", "scoped-verification"):
            self.assertNotIn("verification.openbao", catalog["campaigns"][campaign]["members"])
        for suite_id in MUTATING:
            self.assertEqual(suites[suite_id]["metadata"]["execution_owner"], "human")
            self.assertTrue(suites[suite_id]["metadata"]["mutates_cluster"])
            self.assertIn(suite_id, catalog_validator.STANDALONE_SUITES)
            self.assertTrue((ROOT / suites[suite_id]["runner"]["implementation"]).is_file())
            for campaign in catalog["campaigns"].values():
                self.assertNotIn(suite_id, campaign.get("members", []))

    def test_activation_requires_all_six_flux_units_unsuspended(self):
        source = yaml.safe_load_all(
            (ROOT / "kubernetes/apps/security/openbao/ks.yaml").read_text()
        )
        units = list(source)
        self.assertEqual(len(units), 6)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "kubernetes/apps/security/openbao/ks.yaml"
            path.parent.mkdir(parents=True)
            nocodb = root / "kubernetes/apps/automation-data/nocodb/ks.yaml"
            nocodb.parent.mkdir(parents=True)
            nocodb.write_text(
                (ROOT / "kubernetes/apps/automation-data/nocodb/ks.yaml").read_text()
            )
            app = root / "kubernetes/apps/security/openbao/app"
            app.mkdir(parents=True)
            (app / "openbao-seal.sops.yaml").write_text("encrypted fixture\n")
            app_kustomization = app / "kustomization.yaml"
            app_kustomization.write_text("resources: [./openbao-seal.sops.yaml]\n")
            gatus = root / "kubernetes/apps/monitoring/gatus/app/values.yaml"
            gatus.parent.mkdir(parents=True)
            gatus.write_text("config: {endpoints: [{name: openbao}]}\n")
            with patch.object(catalog_validator, "REPO_ROOT", root):
                for index in range(len(units)):
                    active = [yaml.safe_load(yaml.safe_dump(unit)) for unit in units]
                    for unit in active:
                        unit["spec"]["suspend"] = False
                    active[index]["spec"]["suspend"] = True
                    path.write_text(yaml.safe_dump_all(active))
                    self.assertIn("verification.openbao", catalog_validator.campaign_exclusions())
                for unit in units:
                    unit["spec"]["suspend"] = False
                path.write_text(yaml.safe_dump_all(units))
                self.assertNotIn("verification.openbao", catalog_validator.campaign_exclusions())
                gatus.write_text("config: {endpoints: []}\n")
                self.assertIn("verification.openbao", catalog_validator.campaign_exclusions())
                gatus.write_text("config: {endpoints: [{name: openbao}]}\n")
                app_kustomization.write_text("resources: []\n")
                self.assertIn("verification.openbao", catalog_validator.campaign_exclusions())
                app_kustomization.write_text("resources: [./openbao-seal.sops.yaml]\n")
                (app / "openbao-seal.sops.yaml").unlink()
                self.assertIn("verification.openbao", catalog_validator.campaign_exclusions())


if __name__ == "__main__":
    unittest.main()
