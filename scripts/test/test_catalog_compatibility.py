"""Parity tests for catalog compatibility validator execution paths."""

from __future__ import annotations

import copy
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

MODULE_PATH = Path(__file__).with_name("catalog_compatibility.py")
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("catalog_compatibility", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
catalog_compatibility = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog_compatibility)


class CatalogCompatibilityExecutionTests(unittest.TestCase):
    def assert_execution_parity(self, catalog: Path) -> None:
        direct = catalog_compatibility.run_validator(catalog)
        cli = catalog_compatibility.run_cli_validator(catalog)
        self.assertEqual(direct.returncode, cli.returncode)
        self.assertEqual(direct.stdout, cli.stdout)
        self.assertEqual(direct.stderr, cli.stderr)

    def test_valid_catalog_matches_cli(self) -> None:
        self.assert_execution_parity(catalog_compatibility.CATALOG)

    def test_invalid_top_level_shape_matches_cli(self) -> None:
        canonical = yaml.safe_load(catalog_compatibility.CATALOG.read_text(encoding="utf-8"))
        canonical["schema_version"] = 1
        with tempfile.TemporaryDirectory(prefix="catalog-parity-") as directory:
            fixture = Path(directory) / "invalid-shape.yaml"
            fixture.write_text(yaml.safe_dump(canonical, sort_keys=False), encoding="utf-8")
            self.assert_execution_parity(fixture)

    def test_duplicate_suite_matches_cli_and_literal_contract(self) -> None:
        canonical = yaml.safe_load(catalog_compatibility.CATALOG.read_text(encoding="utf-8"))
        canonical["suites"].append(copy.deepcopy(canonical["suites"][0]))
        with tempfile.TemporaryDirectory(prefix="catalog-parity-") as directory:
            fixture = Path(directory) / "duplicate-suite.yaml"
            fixture.write_text(yaml.safe_dump(canonical, sort_keys=False), encoding="utf-8")
            completed = catalog_compatibility.run_validator(fixture)
            self.assertEqual(completed.returncode, 1)
            self.assertEqual(completed.stdout, "")
            self.assertEqual(completed.stderr, "Duplicate test catalog IDs: validation.ci\n")
            self.assert_execution_parity(fixture)


if __name__ == "__main__":
    unittest.main()
