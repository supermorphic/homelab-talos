#!/usr/bin/env python3
"""Prepare or verify one expiring n8n enrollment transport; never publish it."""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from automation_data_login_transport import prepare, verify


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    create = actions.add_parser(
        "prepare", help="Create private session files and an inactive relay"
    )
    create.add_argument(
        "--directory",
        type=Path,
        required=True,
        help="New absolute private directory outside any Git checkout",
    )
    create.add_argument("--domain", required=True)
    create.add_argument("--application", required=True)
    create.add_argument("--schema", required=True)
    create.add_argument(
        "--credential-id",
        required=True,
        help="Accessible existing n8n provisioning Header Auth ID (not its secret)",
    )
    check = actions.add_parser("verify", help="Check fresh full n8n published workflow readback")
    check.add_argument("--directory", type=Path, required=True)
    check.add_argument(
        "--observation",
        type=Path,
        required=True,
        help="Full workflow JSON from configured n8n connection, including activeVersion",
    )
    args = parser.parse_args(argv)
    try:
        if args.action == "prepare":
            result = prepare(
                args.directory, args.domain, args.application, args.schema, args.credential_id
            )
        else:
            result = verify(args.directory, args.observation)
        print(json.dumps(result))
        return 0
    except Exception:  # noqa: BLE001 - never print bearer, candidate, or provider response
        print(
            "Application login transport failed; private session files preserved.", file=sys.stderr
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
