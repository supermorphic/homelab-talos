"""Bounded issuer acceptance; full application workflows retain their own evidence."""

import json
import sys
import time
from collections import Counter
from pathlib import Path
from xml.etree import ElementTree as ET

from scripts.openbao import guards
from scripts.openbao.configuration import SafeError
from scripts.test import access, junit_report
from scripts.test import scoped_access_acceptance as acceptance
from scripts.test.scenarios import openbao_issuance, openbao_restore
from scripts.test.scenarios.resilience_support import atomic_write_json

ROOT = Path(__file__).resolve().parents[3]
PROFILES = {
    "cilium": "test-cilium-connectivity",
    "openbao-ha": "test-openbao-ha",
    "openbao-restore": "test-openbao-restore",
}
CILIUM_CASES = {
    "no-policies",
    "client-ingress",
    "client-ingress-knp",
    "pod-to-pod-encryption-v2",
    "ingress-from-specific-namespace-ccnp",
}
CILIUM_INTERVAL = 6


def allowed_request(target, run_id):
    if target == "openbao-ha":
        return (
            "/api/v1/namespaces/openbao-acceptance/pods?dryRun=All",
            openbao_issuance.pod_document(run_id, False),
        )
    if target == "openbao-restore":
        return "/api/v1/namespaces/openbao-restore-test/configmaps?dryRun=All", {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "immutable": True,
            "metadata": {
                "name": "scratch-config",
                "namespace": "openbao-restore-test",
                "annotations": {"homelab.supermorphic.com/test-run": run_id},
            },
            "data": {
                "server.hcl": openbao_restore.scratch_configuration("credential-issuer-acceptance")
            },
        }
    raise SafeError("invalid-source")


def prove_allowed(client, target, run_id):
    path, document = allowed_request(target, run_id)
    status, body = client.request(client.proxy_url, path, payload=document)
    if (
        status != 201
        or body.get("kind") != document["kind"]
        or body.get("metadata", {}).get("name") != document["metadata"]["name"]
        or body.get("metadata", {}).get("namespace") != document["metadata"]["namespace"]
    ):
        raise SafeError("invalid-response")


def cilium_arguments(run_dir):
    return [
        "--test",
        "^(" + "|".join(sorted(CILIUM_CASES)) + ")/",
        "--post-test-sleep",
        str(CILIUM_INTERVAL) + "s",
        "--verbose",
        "--junit-file",
        str(run_dir / "diagnostics/fragments/cilium-credential-issuer.xml"),
    ]


def cilium_window(root, elapsed, console):
    cases = list(root.iter("testcase"))
    executed = [c for c in cases if c.find("skipped") is None]
    if Counter(c.get("name") for c in executed) != Counter(CILIUM_CASES) or any(
        c.find("failure") is not None or c.find("error") is not None for c in executed
    ):
        raise SafeError("invalid-response")
    late_index = next(
        i for i, c in enumerate(cases) if c.get("name") == "ingress-from-specific-namespace-ccnp"
    )
    minimum = late_index * CILIUM_INTERVAL
    args = next(
        (p.get("value", "").split("|") for p in root.iter("property") if p.get("name") == "Args"),
        [],
    )
    interval_proven = any(args[i : i + 2] == ["--post-test-sleep", "6s"] for i in range(len(args)))
    late_actions = console.count(
        "[.] Action [ingress-from-specific-namespace-ccnp/ccnp-client-to-client:ping-"
    )
    # The pinned client pauses after every registered case, including skipped
    # cases. Its late selected scenario executes in an authenticated fixture Pod.
    # Require an actual action, rather than accepting an empty scenario as proof.
    if (
        not interval_proven
        or not late_actions
        or minimum < acceptance.NATIVE_SONOBUOY_SECONDS
        or elapsed < minimum
    ):
        raise SafeError("invalid-response")
    return {
        "status": "pass",
        "elapsed_seconds": elapsed,
        "minimum_late_case_seconds": minimum,
        "late_native_exec_actions": late_actions,
        "selected_cases": sorted(CILIUM_CASES),
    }


def inputs(target):
    if target not in PROFILES:
        raise SafeError("invalid-source")
    config, run_dir = access.suite_inputs(ROOT, "test.credential-issuer." + target)
    binding = access.validate_invocation(ROOT, config)
    if binding["profile"] != PROFILES[target]:
        raise SafeError("invalid-source")
    revision = guards.source_revision()

    def checkpoint():
        if (
            access.validate_invocation(ROOT, config) != binding
            or guards.source_revision() != revision
        ):
            raise SafeError("source-mismatch")

    return config, run_dir, checkpoint


def main(argv):
    result = {"status": "fail"}
    run_dir = None
    started = time.monotonic()
    try:
        if len(argv) < 2:
            raise SafeError("invalid-source")
        phase = argv[1]
        target = "cilium" if phase in {"cilium-arguments", "cilium-result"} else phase
        config, run_dir, checkpoint = inputs(target)
        if phase == "cilium-arguments" and len(argv) == 2:
            checkpoint()
            print(json.dumps(cilium_arguments(run_dir)))
            return 0
        if phase == "cilium-result" and len(argv) == 3:
            checkpoint()
            root = ET.parse(
                run_dir / "diagnostics/fragments/cilium-credential-issuer.xml"
            ).getroot()
            console = (run_dir / "diagnostics/cilium-credential-issuer.log").read_text()
            result = cilium_window(root, int(argv[2]), console)
        elif target in {"openbao-ha", "openbao-restore"} and len(argv) == 2:
            client = acceptance.LiveClient(config, checkpoint)
            with client.proxy():
                if (
                    client.identity()
                    != "system:serviceaccount:kube-system:homelab-" + PROFILES[target]
                ):
                    raise SafeError("authentication-failed")
                prove_allowed(client, target, run_dir.name)
            result = {
                "status": "pass",
                "profile": PROFILES[target],
                "phases": ["authenticated-identity", "allowed-server-dry-run"],
            }
        else:
            raise SafeError("invalid-source")
    except BaseException as error:  # noqa: BLE001 -- Response bodies and credentials stay private.
        result["classification"] = (
            str(error) if isinstance(error, SafeError) else "invalid-response"
        )
    if run_dir is not None:
        atomic_write_json(run_dir / "diagnostics/credential-issuer.json", result)
        junit_report.write_case(
            run_dir / "diagnostics/fragments/credential-issuer.xml",
            "test.credential-issuer." + target,
            "credential-issuer-boundary",
            "passed" if result["status"] == "pass" else "failed",
            str(round(time.monotonic() - started, 3)),
        )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
