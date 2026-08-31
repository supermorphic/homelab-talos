#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
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
    def test_console_summary_reports_counts_and_sorted_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.xml"
            report.write_text(
                '<testsuite><testcase classname="z" name="later"><failure>bad</failure></testcase>'
                '<testcase classname="a" name="first"><error>oops</error></testcase>'
                '<testcase classname="a" name="pass"/></testsuite>',
                encoding="utf-8",
            )
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(junit_tools.console_summary(report, "label"), 0)
            text = output.getvalue()
            self.assertIn("label: 3 tests, 1 passed, 1 failures, 1 errors, 0 skipped", text)
            self.assertLess(text.index("a.first"), text.index("z.later"))

    def test_console_summary_policy_failure_does_not_change_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.xml"
            report.write_text('<testsuite><testcase name="bad"><failure/></testcase></testsuite>')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(junit_tools.console_summary(report, "label"), 0)

    def test_console_summary_escapes_xml_text_and_rejects_invalid_xml(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "report.xml"
            report.write_text(
                '<testsuite><testcase classname="a&amp;b" name="x&lt;y"><failure/></testcase></testsuite>'
            )
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(junit_tools.console_summary(report, "label"), 0)
            self.assertIn("a&b.x<y", output.getvalue())
            invalid = root / "invalid.xml"
            invalid.write_text("not xml")
            self.assertEqual(junit_tools.console_summary(invalid, "label"), 2)

    def test_console_summary_returns_two_for_invalid_junit_document(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.xml"
            report.write_text("<root/>")
            self.assertEqual(junit_tools.console_summary(report, "label"), 2)

    def test_repository_shell_returns_two_for_invalid_result_schema(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "result.json"
            result.write_text(json.dumps({"result": {"bash_status": 0}}))
            self.assertEqual(
                junit_tools.repository_shell_report(root / "out.xml", "suite", result), 2
            )

    def test_repository_shell_returns_two_for_nested_invalid_result_schema(self) -> None:
        cases = [
            {"result": {}, "findings": []},
            {"result": {"bash_status": 2}, "findings": []},
            {"result": {"bash_status": 2, "bash_first_failure": {}}, "findings": []},
            {"result": {"bash_status": 0}, "findings": [None]},
            {"result": {"bash_status": 0}, "findings": [{"file": "bad.sh"}]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, payload in enumerate(cases):
                result = root / f"result-{index}.json"
                output = root / f"output-{index}.xml"
                result.write_text(json.dumps(payload))
                self.assertEqual(junit_tools.repository_shell_report(output, "suite", result), 2)
                self.assertFalse(output.exists())

    def test_repository_shell_clean_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "result.json"
            output = root / "output.xml"
            result.write_text(
                json.dumps(
                    {
                        "result": {"bash_status": 0, "shellcheck_status": 0, "sorted_files": []},
                        "findings": [],
                    }
                )
            )
            self.assertEqual(junit_tools.repository_shell_report(output, "suite", result), 0)
            self.assertEqual(len(list(ET.parse(output).getroot().iter("testcase"))), 1)

    def test_repository_shell_bash_failure_keeps_file_and_stderr(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.result = Path(directory) / "result.json"
            self.output = Path(directory) / "output.xml"
            self.result.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "run_id": "run-1",
                        "head_sha": "0" * 40,
                        "source_set_sha256": "1" * 64,
                        "bash_version": "GNU bash 5.3",
                        "shellcheck_version": "ShellCheck 0.11.0",
                        "bash_argv": ["bash", "-n"],
                        "shellcheck_argv": ["shellcheck", "--external-sources", "--format=json"],
                        "producer_suite": "validation.repo-validate",
                        "result": {
                            "bash_status": 2,
                            "bash_first_failure": {
                                "file": "scripts/test/bad.sh",
                                "stderr": "line 4: syntax error",
                            },
                            "shellcheck_status": None,
                            "sorted_files": ["scripts/test/bad.sh"],
                            "completed_at": "2026-08-26T00:00:00Z",
                        },
                        "findings": [],
                    }
                )
            )
            self.assertEqual(
                junit_tools.repository_shell_report(
                    self.output, "validation.repo-validate", self.result
                ),
                0,
            )
            xml = self.output.read_text()
            self.assertIn("scripts/test/bad.sh", xml)
            self.assertIn("line 4: syntax error", xml)

    def test_repository_shell_shellcheck_findings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "result.json"
            output = root / "output.xml"
            result.write_text(
                json.dumps(
                    {
                        "result": {
                            "bash_status": 0,
                            "shellcheck_status": 1,
                            "sorted_files": ["ok.sh"],
                        },
                        "findings": [
                            {
                                "file": "bad.sh",
                                "line": 3,
                                "column": 2,
                                "code": 2086,
                                "level": "warning",
                                "message": "quote & <it>",
                            }
                        ],
                    }
                )
            )
            self.assertEqual(junit_tools.repository_shell_report(output, "suite", result), 0)
            document = ET.parse(output).getroot()
            self.assertEqual(len(list(document.iter("testcase"))), 2)
            parsed = ET.parse(output).getroot()
            failure = parsed.find("testsuite/testcase/failure")
            assert failure is not None
            self.assertEqual(failure.text, "quote & <it>")
            self.assertIn("SC2086", output.read_text())

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
