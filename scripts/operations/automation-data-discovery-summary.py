#!/usr/bin/env python3
"""Observe discovery completeness separately from existing service-health checks."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from automation_data_access import fetch_observations, load_access_config
from automation_data_inventory import (
    SCHEMA_REVISIONS,
    DiscoveryRequest,
    InventoryEnvelope,
    build_inventory,
)


def summarize(inventory: InventoryEnvelope) -> dict:
    sources = [
        {
            key: source.get(key)
            for key in ["source", "complete", "objectCount", "observedAt", "errorCode"]
        }
        for source in inventory.sources
    ]
    complete = sum(source["complete"] is True for source in sources)
    return {
        "schemaVersion": 1,
        "status": "complete"
        if complete == len(SCHEMA_REVISIONS)
        else "partial"
        if complete
        else "unavailable",
        "sources": sources,
        "discrepancyCount": len(inventory.discrepancies),
    }


def main() -> int:
    try:
        inventory = build_inventory(
            fetch_observations(load_access_config(), DiscoveryRequest("list"))
        )
        result = summarize(inventory)
    except Exception:  # noqa: BLE001 - never print protected content or remote errors
        result = summarize(
            InventoryEnvelope(
                sources=[
                    {
                        "source": source,
                        "complete": False,
                        "objectCount": 0,
                        "observedAt": None,
                        "errorCode": "source_unavailable",
                    }
                    for source in SCHEMA_REVISIONS
                ]
            )
        )
    print(json.dumps(result, separators=(",", ":")))
    # Discovery evidence is reported independently. Existing service health owns
    # the verifier's exit status; enrollment cannot turn healthy services into failures.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
