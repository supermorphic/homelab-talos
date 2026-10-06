#!/usr/bin/env python3
"""Discover task access through bounded metadata; never retrieve a consumer password."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from automation_data_access import fetch_observations, inspect_profile, load_access_config
from automation_data_client import PrivateFileError
from automation_data_inventory import (
    DiscoveryRequest,
    InventoryError,
    Resolution,
    build_inventory,
    render_result,
    resolve,
    validate_request,
)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise InventoryError("invalid_arguments")


def parse_request(argv: list[str]) -> DiscoveryRequest:
    parser = Parser(
        description=__doc__,
        epilog=(
            "For approved task access, first run 'mise exec -- just kube kubeconfig' "
            "from the assigned worktree. Use 'list' to discover identities, then "
            "'resolve --help' to select the intended purpose. Discovery reads private "
            "metadata, not passwords; keep its output private."
        ),
    )
    actions = parser.add_subparsers(dest="action", required=True, parser_class=Parser)
    listing = actions.add_parser("list", help="List registered identities and access metadata.")
    listing.add_argument("--domain")
    resolution = actions.add_parser(
        "resolve",
        help="Resolve prerequisites and the supported next action for one identity.",
        epilog=(
            "For routine application access, select 'application --application NAME'. "
            "A ready application or migration result supplies localProfile.serviceFile "
            "and localProfile.service on the identity, plus nextAction with the connection "
            "recipe and arguments. Keep that connection running while using the selected "
            "profile in the consumer. Readiness does not authorize the consumer operation. "
            "For a blocked result, report its prerequisite and nextAction; do not switch "
            "to broader credentials or provision a replacement. "
            "Migration results also include executionContexts.local and executionContexts.n8n. "
            "The top-level decision, nextAction, and exit code retain local connection semantics: "
            "local access requires a protected current profile. The n8n context can independently "
            "report a retained credential ready for workflow binding without a local profile. "
            "Its nextAction identifies the PostgreSQL credential and observed published workflow "
            "IDs; these do not establish installation or suitability of a consumer migration "
            "workflow. Binding and execution need separate task authorization and authentication. "
            "Discovery never exports credentials or installs a workflow."
        ),
    )
    resolution.add_argument("domain", help="Registered domain to inspect.")
    resolution.add_argument(
        "purpose",
        choices=["application", "migration", "workflow", "source"],
        help="Access purpose authorized for this task.",
    )
    resolution.add_argument(
        "--application", help="Registered application name for application access."
    )
    resolution.add_argument("--pair", help="Registered NocoDB source pair for source access.")
    resolution.add_argument(
        "--access-kind", dest="access_kind", help="Source access kind: reader or operator."
    )
    for child in [listing, resolution]:
        child.add_argument("--format", choices=["text", "json"], default="text")
    request = DiscoveryRequest(**vars(parser.parse_args(argv)))
    validate_request(request)
    return request


def profile_summary(profile):
    return {
        "status": profile.status,
        "serviceFile": None if profile.service_file is None else str(profile.service_file),
        "service": profile.service,
        "localPort": profile.local_port,
    }


def main(argv: list[str]) -> int:
    format = (
        "json"
        if "--format=json" in argv
        or any(argv[i : i + 2] == ["--format", "json"] for i in range(len(argv)))
        else "text"
    )
    try:
        request = parse_request(argv)
        format = request.format
        config = load_access_config()
        inventory = build_inventory(fetch_observations(config, request))
        if request.action == "list":
            if request.domain is not None:
                inventory.items = [
                    item
                    for item in inventory.items
                    if item.get("domain") in {None, request.domain}
                ]
                identities = {item["id"] for item in inventory.items}
                inventory.discrepancies = [
                    d
                    for d in inventory.discrepancies
                    if d["identity"] in identities or d["identity"].startswith("binding:")
                ]
            for item in inventory.items:
                if item["family"] in {"application", "migration"} and item["complete"]:
                    item["localProfile"] = profile_summary(inspect_profile(config, item))
            print(render_result(inventory, format))
            return (
                0
                if all(source["complete"] for source in inventory.sources)
                and not inventory.discrepancies
                else 1
            )
        preliminary = resolve(request, inventory, None)
        profile = None
        if request.purpose in {"application", "migration"} and preliminary.identity is not None:
            profile = inspect_profile(config, preliminary.identity)
        result = resolve(request, inventory, profile)
        if profile is not None and result.identity is not None:
            result.identity["localProfile"] = profile_summary(profile)
        print(render_result(result, format))
        return 0 if result.decision == "ready" else 1
    except InventoryError as error:
        code = str(error)
        if code == "invalid_arguments":
            print(
                json.dumps({"schemaVersion": 1, "errorCode": "invalid_arguments"})
                if format == "json"
                else "invalid_arguments"
            )
            return 2
        decision = (
            "setup_required"
            if code == "authentication_required"
            else "recovery_required"
            if code == "authentication_failed"
            else "unavailable"
        )
        result = Resolution(
            decision,
            [{"name": "inventory_access", "status": code}],
            next_action={
                "kind": "procedure",
                "reference": "docs/specs/026-automation-data-postgresql-platform.md#private-credential-discovery-installation",
                "owner": "Platform operator",
            },
        )
        print(render_result(result, format))
        return 1
    except PrivateFileError as error:
        if str(error) == "access_setup_required":
            result = Resolution(
                "setup_required",
                [{"name": "private_access_enrollment", "status": "missing"}],
                next_action={
                    "kind": "procedure",
                    "reference": "docs/specs/026-automation-data-postgresql-platform.md#private-credential-discovery-installation",
                    "owner": "Platform operator",
                },
            )
            print(render_result(result, format))
            return 1
        print(
            json.dumps({"schemaVersion": 1, "errorCode": "invalid_configuration"})
            if format == "json"
            else "invalid_configuration"
        )
        return 2
    except Exception:  # noqa: BLE001 - never print protected contents or remote exception bodies
        print(
            json.dumps({"schemaVersion": 1, "errorCode": "source_unavailable"})
            if format == "json"
            else "source_unavailable"
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
