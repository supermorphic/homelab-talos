#!/usr/bin/env python3
"""Independent assertions over metadata from the run-owned disposable application stack."""

import json
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
from automation_data_inventory import (
    DiscoveryRequest,
    build_inventory,
    lifecycle_evidence,
    resolve,
    timestamp,
    validate_observation,
)

DOMAIN = "automation_data_acceptance"
DIAGNOSTICS = {}


def load(path):
    selected = Path(path)
    if selected.stat().st_size > 4194304:
        raise ValueError("bounded_fixture_required")
    return json.loads(selected.read_text())


def main(arguments):
    mode, path, *extra = arguments
    raw = load(path)
    inventory = build_inventory([validate_observation(s, s["source"]) for s in raw["sources"]])
    # Podman's VM can run a few milliseconds ahead of the workstation. Keep the
    # production future-timestamp rejection intact and prove it before waiting
    # at most one second for this retained test observation to become current.
    future = [
        s
        for s in raw["sources"]
        if s.get("complete") and timestamp(s["observedAt"]) > datetime.now(UTC)
    ]
    if future:
        assert all(
            not s["complete"]
            for s in inventory.sources
            if s["source"] in {f["source"] for f in future}
        )
        latest = max(timestamp(s["observedAt"]) for s in future)
        deadline = time.monotonic() + 1
        while datetime.now(UTC) < latest and time.monotonic() < deadline:
            time.sleep(0.01)
        assert datetime.now(UTC) >= latest, "Fixture clock mismatch exceeds the bounded wait"
        inventory = build_inventory([validate_observation(s, s["source"]) for s in raw["sources"]])
    DIAGNOSTICS["sources"] = [
        {
            **{k: s.get(k) for k in ["source", "complete", "errorCode"]},
            "ageSeconds": None
            if not s.get("observedAt")
            else (datetime.now(UTC) - timestamp(s["observedAt"])).total_seconds(),
        }
        for s in inventory.sources
    ]
    DIAGNOSTICS["mode"] = mode
    DIAGNOSTICS["tasks"] = []
    for purpose, pair, kind in [
        ("workflow", None, None),
        ("migration", None, None),
        ("application", None, None),
        *[("source", p, k) for p in ["default", "extra"] for k in ["reader", "operator"]],
    ]:
        r = resolve(
            DiscoveryRequest(
                "resolve",
                DOMAIN,
                purpose,
                application="interview" if purpose == "application" else None,
                pair=pair,
                access_kind=kind,
            ),
            inventory,
        )
        DIAGNOSTICS["tasks"].append(
            {
                "purpose": purpose,
                "pair": pair,
                "kind": kind,
                "decision": r.decision,
                "prerequisites": r.prerequisites,
                "discrepancyCodes": []
                if r.identity is None
                else [d["code"] for d in r.identity["discrepancies"]],
            }
        )
    if mode == "incomplete":
        assert any(not s["complete"] for s in inventory.sources)
        assert (
            resolve(DiscoveryRequest("resolve", DOMAIN, "workflow"), inventory).decision
            == "unavailable"
        )
        return
    assert all(s["complete"] for s in inventory.sources), (
        "Independent enumerations must all complete"
    )
    if mode == "complete":
        assert (
            resolve(DiscoveryRequest("resolve", DOMAIN, "workflow"), inventory).decision == "ready"
        )
        for pair in ["default", "extra"]:
            for kind in ["reader", "operator"]:
                resolution = resolve(
                    DiscoveryRequest("resolve", DOMAIN, "source", pair=pair, access_kind=kind),
                    inventory,
                )
                assert resolution.decision == "ready", (
                    "Existing pair metadata must resolve consistently"
                )
        application = resolve(
            DiscoveryRequest("resolve", DOMAIN, "application", application="interview"), inventory
        )
        assert application.decision == "setup_required", (
            "No protected workstation profile is installed by this fixture"
        )
        assert application.identity["credentialGeneration"] == int(extra[0])
        assert not application.identity["discrepancies"]
        assert (
            resolve(DiscoveryRequest("resolve", DOMAIN, "migration"), inventory).decision
            == "setup_required"
        )
    elif mode == "lifecycle":
        mutation = load(extra[0])
        evidence = lifecycle_evidence(mutation, inventory)
        assert evidence["status"] == "observed", "Mutation metadata must independently match"
        assert mutation["inventoryReadback"]["status"] == "observed", (
            "Direct workflow readback must independently complete"
        )
    elif mode == "absent":
        receipt = load(extra[0])
        assert receipt["steps"] == ["enumerated", "removed", "enumerated"]
        identities = {
            (s["source"], o["kind"], o["id"]) for s in raw["sources"] for o in s["objects"]
        }
        assert all(tuple(target) not in identities for target in receipt["removed"])
    elif mode == "registry-only":
        resolution = resolve(
            DiscoveryRequest("resolve", "issue506_inventory_removal", "workflow"), inventory
        )
        assert resolution.decision == "inconsistent"
        assert any(d["code"] == "missing_credential" for d in resolution.identity["discrepancies"])
    elif mode == "observed-only":
        resolution = resolve(
            DiscoveryRequest("resolve", "issue506_inventory_removal", "workflow"), inventory
        )
        assert resolution.decision == "setup_required"
        assert any(
            i.get("role") == "issue506_inventory_removal_runtime"
            and i["classification"] == "unclassified"
            for i in inventory.items
        )
    else:
        raise ValueError("unknown_fixture_assertion")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception:  # noqa: BLE001 - fixture input may contain encrypted application fields
        print(json.dumps(DIAGNOSTICS, sort_keys=True), file=sys.stderr)
        print("Disposable credential-discovery assertion failed.", file=sys.stderr)
        raise SystemExit(1) from None
