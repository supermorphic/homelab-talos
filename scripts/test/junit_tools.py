#!/usr/bin/env python3
"""Thin CLI over the importable stdlib-only JUnit report library."""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from junit_report import (
    append_lifecycle,
    inspect_report,
    merge_reports,
    shellcheck_report,
    unittest_report,
    write_case,
)


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
