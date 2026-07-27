#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("junit_report.py")
SPEC = importlib.util.spec_from_file_location("junit_report", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
junit_tools = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(junit_tools)


class JUnitToolsTests(unittest.TestCase):
    def test_merge_recalculates_counts_and_rejects_zero_cases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.xml"
            second = root / "second.xml"
            output = root / "merged.xml"
            first.write_text(
                '<testsuites tests="99"><testsuite name="one">'
                '<testcase name="pass"/></testsuite></testsuites>',
                encoding="utf-8",
            )
            second.write_text(
                '<testsuite name="two"><testcase name="fail">'
                '<failure message="expected"/></testcase></testsuite>',
                encoding="utf-8",
            )
            self.assertEqual(
                junit_tools.merge_reports(output, "combined", [first, second]),
                0,
            )
            document = ET.parse(output).getroot()
            self.assertEqual(document.get("tests"), "2")
            self.assertEqual(document.get("failures"), "1")
            self.assertEqual(len(document.findall("testsuite")), 2)

            empty = root / "empty.xml"
            empty.write_text("<testsuites/>", encoding="utf-8")
            with self.assertRaises(ValueError):
                junit_tools.merge_reports(output, "combined", [empty])

    def test_case_writer_and_inspector_preserve_all_outcomes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = []
            for result in ("passed", "failed", "broken", "skipped"):
                report = root / f"{result}.xml"
                reports.append(report)
                self.assertEqual(
                    junit_tools.write_case(
                        report,
                        "validation.fixture",
                        result,
                        result,
                        "1.25",
                    ),
                    0,
                )
            merged = root / "merged.xml"
            junit_tools.merge_reports(merged, "validation.fixture", reports)
            self.assertEqual(
                junit_tools.inspect_report(merged),
                {
                    "tests": 4,
                    "failures": 1,
                    "errors": 1,
                    "skipped": 1,
                    "passed": 1,
                },
            )
            with self.assertRaises(ValueError):
                junit_tools.write_case(
                    root / "unsafe.xml",
                    "unsafe suite",
                    "case",
                    "passed",
                    "0",
                )

    def test_lifecycle_append_is_structural_and_recalculates_counts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "lifecycle.xml"
            junit_tools.write_case(
                report,
                "chainsaw.e2e.fixture",
                "primary",
                "passed",
                "1",
            )
            self.assertEqual(
                junit_tools.append_lifecycle(
                    report,
                    report,
                    "chainsaw.e2e.fixture",
                    "not-applicable",
                    "failed",
                    "failed",
                    "passed",
                    "broken",
                ),
                0,
            )
            self.assertEqual(
                junit_tools.inspect_report(report),
                {
                    "tests": 6,
                    "failures": 0,
                    "errors": 3,
                    "skipped": 1,
                    "passed": 2,
                },
            )
            document = ET.parse(report).getroot()
            lifecycle = document.findall("testsuite")[-1]
            self.assertEqual(
                lifecycle.get("name"),
                "chainsaw.e2e.fixture.lifecycle",
            )
            self.assertEqual(len(lifecycle.findall("testcase")), 5)

    def test_shellcheck_keeps_clean_files_and_findings_as_cases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            findings = root / "findings.json"
            output = root / "shellcheck.xml"
            findings.write_text(
                json.dumps(
                    [
                        {
                            "file": "bad.sh",
                            "line": 3,
                            "column": 2,
                            "code": 2086,
                            "level": "info",
                            "message": "Double quote to prevent globbing.",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                junit_tools.shellcheck_report(
                    output,
                    "shellcheck",
                    findings,
                    ["good.sh", "bad.sh"],
                ),
                1,
            )
            document = ET.parse(output).getroot()
            self.assertEqual(document.get("tests"), "2")
            self.assertEqual(document.get("failures"), "1")

    def test_unittest_adapter_preserves_individual_outcomes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "unittest.xml"
            (root / "test_fixture.py").write_text(
                "import unittest\n"
                "class Fixture(unittest.TestCase):\n"
                "    def test_pass(self): self.assertTrue(True)\n"
                "    @unittest.skip('fixture')\n"
                "    def test_skip(self): pass\n",
                encoding="utf-8",
            )
            self.assertEqual(
                junit_tools.unittest_report(
                    output,
                    "python-fixture",
                    str(root),
                    "test_*.py",
                ),
                0,
            )
            document = ET.parse(output).getroot()
            self.assertEqual(document.get("tests"), "2")
            self.assertEqual(document.get("skipped"), "1")


if __name__ == "__main__":
    unittest.main()
