#!/usr/bin/env python3
"""Small stdlib-only JUnit adapters used by the test result coordinator."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


def _counts(root: ET.Element) -> dict[str, int]:
    cases = list(root.iter("testcase"))
    failures = sum(case.find("failure") is not None for case in cases)
    errors = sum(case.find("error") is not None for case in cases)
    skipped = sum(case.find("skipped") is not None for case in cases)
    return {
        "tests": len(cases),
        "failures": failures,
        "errors": errors,
        "skipped": skipped,
    }


def _set_counts(element: ET.Element) -> None:
    for name, value in _counts(element).items():
        element.set(name, str(value))


def _validated_counts(root: ET.Element) -> dict[str, int]:
    if root.tag not in {"testsuite", "testsuites"}:
        raise ValueError("expected testsuite/testsuites root")
    counts = _counts(root)
    classified = counts["failures"] + counts["errors"] + counts["skipped"]
    if counts["tests"] == 0:
        raise ValueError("refusing a vacuous JUnit report")
    if classified > counts["tests"]:
        raise ValueError("JUnit test cases contain overlapping outcomes")
    counts["passed"] = counts["tests"] - classified
    return counts


def _write_xml(root: ET.Element, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


def merge_reports(output: Path, suite_name: str, inputs: list[Path]) -> int:
    root = ET.Element("testsuites", {"name": suite_name})
    for input_path in inputs:
        document = ET.parse(input_path).getroot()
        _validated_counts(document)
        if document.tag == "testsuite":
            suites = [document]
        elif document.tag == "testsuites":
            suites = list(document.findall("testsuite"))
        else:
            raise ValueError(f"{input_path}: expected testsuite/testsuites root")
        for suite in suites:
            copied = copy.deepcopy(suite)
            _set_counts(copied)
            root.append(copied)
    _set_counts(root)
    _validated_counts(root)
    _write_xml(root, output)
    return 0


def inspect_report(input_path: Path) -> dict[str, int]:
    return _validated_counts(ET.parse(input_path).getroot())


def write_case(
    output: Path,
    suite_name: str,
    case_name: str,
    result: str,
    duration: str,
) -> int:
    safe_name = re.compile(r"^[A-Za-z0-9_.:-]+$")
    if not safe_name.fullmatch(suite_name) or not safe_name.fullmatch(case_name):
        raise ValueError("suite and case names must use stable identifier characters")
    try:
        duration_value = float(duration)
    except ValueError as error:
        raise ValueError("case duration must be numeric") from error
    if duration_value < 0:
        raise ValueError("case duration must not be negative")

    suite = ET.Element(
        "testsuite",
        {"name": suite_name, "time": duration},
    )
    case = ET.SubElement(
        suite,
        "testcase",
        {
            "classname": suite_name,
            "name": case_name,
            "time": duration,
        },
    )
    if result == "failed":
        ET.SubElement(
            case,
            "failure",
            {"message": "command assertion failed"},
        )
    elif result == "broken":
        ET.SubElement(
            case,
            "error",
            {"message": "test harness failed"},
        )
    elif result == "skipped":
        ET.SubElement(
            case,
            "skipped",
            {"message": "not executed after fail-fast stop"},
        )
    elif result != "passed":
        raise ValueError(f"unsupported case result: {result}")

    _set_counts(suite)
    root = ET.Element("testsuites", {"name": suite_name, "time": duration})
    root.append(suite)
    _set_counts(root)
    _write_xml(root, output)
    return 0


def append_lifecycle(
    input_path: Path,
    output: Path,
    suite_name: str,
    external_dependency: str,
    cleanup: str,
    recovery: str,
    diagnostics: str,
    run_result: str,
) -> int:
    document = ET.parse(input_path).getroot()
    _validated_counts(document)
    if document.tag == "testsuite":
        root = ET.Element("testsuites", {"name": suite_name})
        root.append(document)
    else:
        root = document

    lifecycle = ET.Element("testsuite", {"name": f"{suite_name}.lifecycle"})
    finalization = "failed" if run_result == "broken" else "passed"
    phases = (
        ("external-dependency", external_dependency),
        ("cleanup", cleanup),
        ("recovery", recovery),
        ("diagnostics", diagnostics),
        ("finalization", finalization),
    )
    for name, status in phases:
        case = ET.SubElement(
            lifecycle,
            "testcase",
            {
                "classname": f"{suite_name}.lifecycle",
                "name": name,
                "time": "0",
            },
        )
        if status in {"failed", "not-classified"}:
            ET.SubElement(
                case,
                "error",
                {"message": f"phase status: {status}"},
            )
        elif status in {"not-applicable", "not-required"}:
            ET.SubElement(
                case,
                "skipped",
                {"message": f"phase status: {status}"},
            )
        elif status != "passed":
            raise ValueError(f"unsupported lifecycle status: {status}")

    if run_result not in {"passed", "failed", "broken"}:
        raise ValueError(f"unsupported run result: {run_result}")
    _set_counts(lifecycle)
    root.append(lifecycle)
    _set_counts(root)
    _write_xml(root, output)
    return 0


def shellcheck_report(
    output: Path,
    suite_name: str,
    findings_path: Path,
    checked_files: list[str],
) -> int:
    findings = json.loads(findings_path.read_text(encoding="utf-8"))
    if not isinstance(findings, list):
        raise TypeError("ShellCheck JSON must be an array")

    suite = ET.Element("testsuite", {"name": suite_name})
    files_with_findings: set[str] = set()
    for finding in findings:
        path = str(finding["file"])
        files_with_findings.add(path)
        code = f"SC{finding['code']}"
        case = ET.SubElement(
            suite,
            "testcase",
            {
                "classname": suite_name,
                "name": (f"{path}:{finding['line']}:{finding['column']}:{code}"),
            },
        )
        failure = ET.SubElement(
            case,
            "failure",
            {
                "message": f"{code} {finding['level']}: {finding['message']}",
                "type": "shellcheck",
            },
        )
        failure.text = finding["message"]

    for path in checked_files:
        if path not in files_with_findings:
            ET.SubElement(
                suite,
                "testcase",
                {"classname": suite_name, "name": path},
            )

    _set_counts(suite)
    root = ET.Element("testsuites", {"name": suite_name})
    root.append(suite)
    _set_counts(root)
    _write_xml(root, output)
    return 1 if findings else 0


class RecordingResult(unittest.TextTestResult):
    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.started: dict[unittest.case.TestCase, float] = {}
        self.durations: dict[unittest.case.TestCase, float] = {}

    def startTest(self, test: unittest.case.TestCase) -> None:
        self.started[test] = time.monotonic()
        super().startTest(test)

    def stopTest(self, test: unittest.case.TestCase) -> None:
        self.durations[test] = time.monotonic() - self.started.pop(test, time.monotonic())
        super().stopTest(test)


def unittest_report(
    output: Path,
    suite_name: str,
    start_directory: str,
    pattern: str,
) -> int:
    discovered = unittest.defaultTestLoader.discover(
        start_dir=start_directory,
        pattern=pattern,
    )
    runner = unittest.TextTestRunner(
        stream=sys.stderr,
        verbosity=1,
        resultclass=RecordingResult,
    )
    result = runner.run(discovered)
    assert isinstance(result, RecordingResult)

    failures = {test: detail for test, detail in result.failures}
    errors = {test: detail for test, detail in result.errors}
    skipped = {test: reason for test, reason in result.skipped}
    expected_failures = {test: detail for test, detail in result.expectedFailures}
    unexpected_successes = set(result.unexpectedSuccesses)

    suite = ET.Element("testsuite", {"name": suite_name})
    all_tests = (
        set(result.durations)
        | set(failures)
        | set(errors)
        | set(skipped)
        | set(expected_failures)
        | unexpected_successes
    )
    for test in sorted(all_tests, key=lambda item: item.id()):
        case = ET.SubElement(
            suite,
            "testcase",
            {
                "classname": test.__class__.__module__,
                "name": test.id(),
                "time": f"{result.durations.get(test, 0.0):.6f}",
            },
        )
        if test in failures:
            node = ET.SubElement(case, "failure", {"message": "assertion failed"})
            node.text = failures[test]
        elif test in errors:
            node = ET.SubElement(case, "error", {"message": "test harness error"})
            node.text = errors[test]
        elif test in skipped:
            ET.SubElement(case, "skipped", {"message": skipped[test]})
        elif test in expected_failures:
            node = ET.SubElement(case, "skipped", {"message": "expected failure"})
            node.text = expected_failures[test]
        elif test in unexpected_successes:
            ET.SubElement(
                case,
                "failure",
                {"message": "unexpected success"},
            )

    _set_counts(suite)
    root = ET.Element("testsuites", {"name": suite_name})
    root.append(suite)
    _set_counts(root)
    if int(root.get("tests", "0")) == 0:
        raise ValueError("unittest discovery executed zero test cases")
    _write_xml(root, output)
    return 0 if result.wasSuccessful() else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    merge = subparsers.add_parser("merge")
    merge.add_argument("--output", type=Path, required=True)
    merge.add_argument("--suite", required=True)
    merge.add_argument("inputs", nargs="+", type=Path)

    inspect = subparsers.add_parser("inspect")
    inspect.add_argument("--input", type=Path, required=True)

    case = subparsers.add_parser("case")
    case.add_argument("--output", type=Path, required=True)
    case.add_argument("--suite", required=True)
    case.add_argument("--name", required=True)
    case.add_argument(
        "--result",
        choices=("passed", "failed", "broken", "skipped"),
        required=True,
    )
    case.add_argument("--duration", required=True)

    lifecycle = subparsers.add_parser("append-lifecycle")
    lifecycle.add_argument("--input", type=Path, required=True)
    lifecycle.add_argument("--output", type=Path, required=True)
    lifecycle.add_argument("--suite", required=True)
    lifecycle.add_argument("--external-dependency", required=True)
    lifecycle.add_argument("--cleanup", required=True)
    lifecycle.add_argument("--recovery", required=True)
    lifecycle.add_argument("--diagnostics", required=True)
    lifecycle.add_argument(
        "--run-result",
        choices=("passed", "failed", "broken"),
        required=True,
    )

    shellcheck = subparsers.add_parser("shellcheck")
    shellcheck.add_argument("--output", type=Path, required=True)
    shellcheck.add_argument("--suite", required=True)
    shellcheck.add_argument("--findings", type=Path, required=True)
    shellcheck.add_argument("files", nargs="+")

    unit = subparsers.add_parser("unittest")
    unit.add_argument("--output", type=Path, required=True)
    unit.add_argument("--suite", required=True)
    unit.add_argument("--start-directory", required=True)
    unit.add_argument("--pattern", default="test_*.py")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "merge":
            return merge_reports(args.output, args.suite, args.inputs)
        if args.command == "inspect":
            counts = inspect_report(args.input)
            print(
                counts["tests"],
                counts["failures"],
                counts["errors"],
                counts["skipped"],
                counts["passed"],
            )
            return 0
        if args.command == "case":
            return write_case(
                args.output,
                args.suite,
                args.name,
                args.result,
                args.duration,
            )
        if args.command == "append-lifecycle":
            return append_lifecycle(
                args.input,
                args.output,
                args.suite,
                args.external_dependency,
                args.cleanup,
                args.recovery,
                args.diagnostics,
                args.run_result,
            )
        if args.command == "shellcheck":
            return shellcheck_report(
                args.output,
                args.suite,
                args.findings,
                args.files,
            )
        if args.command == "unittest":
            return unittest_report(
                args.output,
                args.suite,
                args.start_directory,
                args.pattern,
            )
    except (ET.ParseError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"JUnit adapter error: {error}", file=sys.stderr)
        return 2
    raise AssertionError(f"unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
