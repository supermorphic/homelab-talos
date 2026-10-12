#!/usr/bin/env python3
"""Synthetic API seam for command safety tests; never models policy decisions."""

import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
if args[:1] == ["--kubeconfig"]:
    args = args[2:]
root = Path(os.environ["APPLICATION_BOUNDARY_FIXTURE_DATA"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["auth", "whoami"]:
    print(
        json.dumps(
            {
                "status": {
                    "userInfo": {"username": os.environ["APPLICATION_BOUNDARY_FIXTURE_IDENTITY"]}
                }
            }
        )
    )
elif args[:1] == ["get"]:
    documents = json.loads((root / "objects.json").read_text())
    key = args[1].lower() + "/" + args[2]
    item = documents.get(key)
    if item is None and "--ignore-not-found" in args:
        sys.exit(0)
    if item is None:
        sys.exit("Synthetic API resource is unavailable.")
    print(json.dumps(item))
elif args[:1] == ["create"] and "--dry-run=server" in args:
    counter = root / "requests"
    number = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(number + 1))
    if number == 0:
        print("job.batch/career-ops-boundary-admission")
    else:
        sys.exit(
            os.environ.get(
                "APPLICATION_BOUNDARY_FIXTURE_DENIAL",
                "Error from server (Forbidden): ValidatingAdmissionPolicy 'career-ops-workloads' denied request",
            )
        )
else:
    sys.exit("Unexpected or persistent API action is forbidden by this fixture.")
