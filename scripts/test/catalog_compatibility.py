"""Black-box compatibility contract for the catalog validator shell command."""

from __future__ import annotations

import copy
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

import catalog_validator
import yaml

REPO_ROOT = Path(__file__).parents[2]
VALIDATOR = REPO_ROOT / "scripts/test/validate-catalog.sh"
CATALOG = REPO_ROOT / "tests/catalog.yaml"
CI_GROUP_EXECUTIONS = ("ci-core", "ci-observability", "ci-automation", "ci-framework")


def ci_group_members(catalog: dict[str, Any]) -> list[str]:
    executions = catalog["executions"]
    return [suite_id for group in CI_GROUP_EXECUTIONS for suite_id in executions[group]]


def run_validator(catalog: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(VALIDATOR), str(catalog)],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
        text=True,
    )


def suite(catalog: dict[str, Any], suite_id: str) -> dict[str, Any]:
    return next(item for item in catalog["suites"] if item["metadata"]["id"] == suite_id)


def expect_rejection(
    root: Path,
    canonical: dict[str, Any],
    name: str,
    mutate: Callable[[dict[str, Any]], None],
    expected_stderr: str,
    expected_status: int = 1,
    normalize_diff: bool = False,
) -> None:
    candidate = copy.deepcopy(canonical)
    mutate(candidate)
    fixture = root / f"{name}.yaml"
    fixture.write_text(yaml.safe_dump(candidate, sort_keys=False), encoding="utf-8")
    completed = run_validator(fixture)
    assert completed.returncode == expected_status, (
        f"{name}: expected exit {expected_status}, got {completed.returncode}\n"
        f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
    )
    assert completed.stdout == "", f"{name}: rejection wrote stdout: {completed.stdout!r}"
    actual_stderr = completed.stderr
    if normalize_diff:
        actual_stderr = re.sub(
            r"^(---|\+\+\+) /dev/fd/\d+\t.*$",
            r"\1 /dev/fd/<fd>\t<timestamp>",
            actual_stderr,
            flags=re.MULTILINE,
        )
    assert actual_stderr == expected_stderr, (
        f"{name}: stderr changed\nexpected: {expected_stderr!r}\nactual:   {actual_stderr!r}"
    )


def expect_acceptance(
    root: Path,
    canonical: dict[str, Any],
    name: str,
    mutate: Callable[[dict[str, Any]], None],
) -> None:
    candidate = copy.deepcopy(canonical)
    mutate(candidate)
    fixture = root / f"{name}.yaml"
    fixture.write_text(yaml.safe_dump(candidate, sort_keys=False), encoding="utf-8")
    completed = run_validator(fixture)
    assert completed.returncode == 0, (
        f"{name}: expected acceptance, got exit {completed.returncode}\n"
        f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
    )
    assert completed.stdout == "Test catalog passed validation: suites=120.\n"
    assert completed.stderr == ""


def existing_negative_contract(root: Path, canonical: dict[str, Any]) -> None:
    expect_rejection(
        root,
        canonical,
        "duplicate-suite",
        lambda data: data["suites"].append(copy.deepcopy(data["suites"][0])),
        "Duplicate test catalog IDs: validation.ci\n",
    )
    expect_rejection(
        root,
        canonical,
        "unsafe-dispatch-path",
        lambda data: suite(data, "chainsaw.smoke.cluster.default")["dispatch"].__setitem__(
            "path", "../outside"
        ),
        "Catalog entry chainsaw.smoke.cluster.default has unsafe or missing dispatch path "
        "'../outside'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "direct-runtime",
        lambda data: suite(data, "test.integration.media-hardlink")["dispatch"].__setitem__(
            "runtime", "shell-string"
        ),
        "Direct entry test.integration.media-hardlink has unsupported runtime 'shell-string'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "direct-args",
        lambda data: suite(data, "test.integration.media-hardlink")["dispatch"].__setitem__(
            "args", ".kube/config --unsafe"
        ),
        "Error: no matches found\n"
        "Direct entry test.integration.media-hardlink must use a string argument vector "
        "and no selector.\n",
    )
    expect_rejection(
        root,
        canonical,
        "unguarded-mutation",
        lambda data: suite(data, "test.cilium-connectivity").__setitem__(
            "confirmation", {"type": "none", "variable": None, "expected": None}
        ),
        "Mutating catalog entry test.cilium-connectivity must declare command or exact "
        "confirmation.\n",
    )
    expect_rejection(
        root,
        canonical,
        "unsafe-runner-command",
        lambda data: suite(data, "verification.metrics-server")["runner"].__setitem__(
            "command", "mise exec -- just kube metrics-server-verify; touch /tmp/unsafe"
        ),
        "Catalog entry verification.metrics-server runner command is not a safe literal "
        "mise + just invocation.\n",
    )
    expect_rejection(
        root,
        canonical,
        "unsupported-runner-placeholder",
        lambda data: suite(data, "chainsaw.resilience.test-reports-persistence")[
            "runner"
        ].__setitem__(
            "command",
            "TEST_REPORT_RUN_ID=<token> "
            "CLUSTER_CHAOS_CONFIRM=chaos:test-reports-persistence "
            "mise exec -- just test resilience test-reports-persistence",
        ),
        "Catalog entry chainsaw.resilience.test-reports-persistence contains "
        "unsupported runner placeholder: <token>.\n",
    )
    expect_rejection(
        root,
        canonical,
        "empty-runner-placeholder",
        lambda data: suite(data, "chainsaw.resilience.test-reports-persistence")[
            "runner"
        ].__setitem__(
            "command",
            "TEST_REPORT_RUN_ID=<> "
            "CLUSTER_CHAOS_CONFIRM=chaos:test-reports-persistence "
            "mise exec -- just test resilience test-reports-persistence",
        ),
        "Catalog entry chainsaw.resilience.test-reports-persistence contains "
        "unsupported runner placeholder: <>.\n",
    )
    expect_rejection(
        root,
        canonical,
        "missing-ci-suite",
        lambda data: data["suites"].remove(suite(data, "validation.trivy")),
        "CI execution ID must resolve to one child validation suite: validation.trivy\n",
    )
    expect_rejection(
        root,
        canonical,
        "unknown-campaign-member",
        lambda data: data["campaigns"]["e2e"]["members"].append("test.e2e.not-registered"),
        "Unknown or ambiguous catalog suite ID: test.e2e.not-registered.\n"
        "Campaign e2e references an unknown suite: test.e2e.not-registered\n",
    )
    expect_rejection(
        root,
        canonical,
        "campaign-cycle",
        lambda data: data["campaigns"]["standard"]["includes"].append("full"),
        "Test campaign include cycle: standard -> full -> weekly -> standard.\n",
        expected_status=2,
    )

    def remove_verification_member(data: dict[str, Any]) -> None:
        data["campaigns"]["verification"]["members"].pop()

    expect_rejection(
        root,
        canonical,
        "missing-tier-member",
        remove_verification_member,
        "Campaign verification members differs from the explicit catalog contract.\n"
        "--- /dev/fd/<fd>\t<timestamp>\n"
        "+++ /dev/fd/<fd>\t<timestamp>\n"
        "@@ -1,4 +1,3 @@\n"
        "-verification.agent-access\n"
        " verification.alertmanager-ntfy\n"
        " verification.automation-data\n"
        " verification.cilium\n",
        normalize_diff=True,
    )
    expect_rejection(
        root,
        canonical,
        "duplicate-campaign-member",
        lambda data: data["campaigns"]["e2e"]["members"].append(
            data["campaigns"]["e2e"]["members"][0]
        ),
        "Campaign e2e resolves duplicate suite IDs: test.e2e.flux-alert-delivery\n",
    )


def top_level_contract(root: Path, canonical: dict[str, Any]) -> None:
    missing = root / "missing.yaml"
    completed = run_validator(missing)
    assert completed.returncode == 1
    assert completed.stdout == ""
    assert completed.stderr == f"Missing test catalog: {missing}\n"

    expect_rejection(
        root,
        canonical,
        "invalid-schema",
        lambda data: data.__setitem__("schema_version", 1),
        "Error: no matches found\n"
        "Test catalog must have schema_version=2 plus suites, executions.ci, and campaigns.\n",
    )

    def duplicate_dispatch(data: dict[str, Any]) -> None:
        duplicate = copy.deepcopy(suite(data, "chainsaw.smoke.cluster.default"))
        duplicate["metadata"]["id"] = "chainsaw.smoke.cluster.duplicate"
        data["suites"].append(duplicate)

    expect_rejection(
        root,
        canonical,
        "duplicate-dispatch",
        duplicate_dispatch,
        "Duplicate test dispatch tuples: smoke|cluster|<none>\n",
    )


def entry_contract(root: Path, canonical: dict[str, Any]) -> None:
    entry_id = "validation.ci"
    expect_rejection(
        root,
        canonical,
        "invalid-id",
        lambda data: suite(data, entry_id)["metadata"].__setitem__("id", "Bad ID"),
        "Catalog entry 0 has invalid id 'Bad ID'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "missing-metadata",
        lambda data: suite(data, entry_id)["metadata"].__setitem__("source", ""),
        f"Catalog entry {entry_id} is missing non-empty source.\n",
    )

    invalid_metadata = {
        "source": ("other", "source"),
        "framework": ("other", "framework"),
        "tier": ("other", "tier"),
        "scope": ("other", "scope"),
        "intent": ("other", "intent"),
        "target": ("Bad Target", "target"),
        "execution_owner": ("robot", "execution_owner"),
    }
    for field, (value, diagnostic_name) in invalid_metadata.items():
        expect_rejection(
            root,
            canonical,
            f"invalid-{field}",
            lambda data, field=field, value=value: suite(data, entry_id)["metadata"].__setitem__(
                field, value
            ),
            f"Catalog entry {entry_id} has invalid {diagnostic_name} '{value}'.\n",
        )

    expect_rejection(
        root,
        canonical,
        "invalid-results-strategy",
        lambda data: suite(data, entry_id)["native_results"].__setitem__("strategy", "other"),
        f"Catalog entry {entry_id} has invalid native result strategy 'other'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "invalid-mutates-cluster",
        lambda data: suite(data, entry_id)["metadata"].__setitem__("mutates_cluster", "maybe"),
        f"Catalog entry {entry_id} must set mutates_cluster to a boolean.\n",
    )
    expect_rejection(
        root,
        canonical,
        "invalid-confirmation-type",
        lambda data: suite(data, entry_id)["confirmation"].__setitem__("type", "other"),
        f"Catalog entry {entry_id} has invalid confirmation type 'other'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "mutating-verification",
        lambda data: suite(data, "verification.metrics-server")["metadata"].__setitem__(
            "mutates_cluster", True
        ),
        "Verification entry verification.metrics-server must be observational.\n",
    )
    expect_rejection(
        root,
        canonical,
        "confirmed-verification",
        lambda data: suite(data, "verification.metrics-server")["confirmation"].update(
            {"type": "exact", "variable": "VERIFY_CONFIRM", "expected": "verify:metrics"}
        ),
        "Verification entry verification.metrics-server must not require confirmation.\n",
    )

    exact_id = "test.cilium-connectivity"
    expect_rejection(
        root,
        canonical,
        "invalid-exact-confirmation",
        lambda data: suite(data, exact_id)["confirmation"].__setitem__("variable", "bad"),
        f"Exact-confirmation entry {exact_id} needs a variable name and expected shape.\n",
    )
    expect_rejection(
        root,
        canonical,
        "hidden-exact-guard",
        lambda data: suite(data, exact_id)["runner"].__setitem__(
            "command", "mise exec -- just kube cilium-connectivity-test"
        ),
        f"Exact-confirmation entry {exact_id} command does not expose its declared guard.\n",
    )
    n8n_guard_cases = {
        "test.n8n-persistence": "mise exec -- just test resilience n8n-persistence",
        "test.n8n-restore-drill": "mise exec -- just kube n8n-restore-drill",
    }
    for n8n_id, unguarded_command in n8n_guard_cases.items():
        expect_rejection(
            root,
            canonical,
            f"hidden-guard-{n8n_id}",
            lambda data, n8n_id=n8n_id, unguarded_command=unguarded_command: suite(data, n8n_id)[
                "runner"
            ].__setitem__("command", unguarded_command),
            f"Exact-confirmation entry {n8n_id} command does not expose its declared guard.\n",
        )
    expect_rejection(
        root,
        canonical,
        "metadata-on-non-exact-confirmation",
        lambda data: suite(data, entry_id)["confirmation"].__setitem__("variable", "UNEXPECTED"),
        "Error: no matches found\n"
        f"Non-exact entry {entry_id} must not declare confirmation variable/value metadata.\n",
    )
    expect_rejection(
        root,
        canonical,
        "unpinned-runner",
        lambda data: suite(data, entry_id)["runner"].__setitem__("command", "just ci"),
        f"Catalog entry {entry_id} must expose a pinned mise + just command.\n",
    )
    expect_rejection(
        root,
        canonical,
        "missing-implementation",
        lambda data: suite(data, entry_id)["runner"].__setitem__(
            "implementation", "scripts/test/does-not-exist.sh"
        ),
        f"Catalog entry {entry_id} points to missing implementation "
        "'scripts/test/does-not-exist.sh'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "invalid-scenario-type",
        lambda data: suite(data, entry_id)["metadata"].__setitem__("scenario", 7),
        f"Catalog entry {entry_id} scenario must be a string or null.\n",
    )
    expect_rejection(
        root,
        canonical,
        "invalid-scenario-value",
        lambda data: suite(data, entry_id)["metadata"].__setitem__("scenario", "Bad Scenario"),
        f"Catalog entry {entry_id} has invalid scenario 'Bad Scenario'.\n",
    )


def dispatch_contract(root: Path, canonical: dict[str, Any]) -> None:
    chainsaw_id = "chainsaw.smoke.cluster.default"
    expect_rejection(
        root,
        canonical,
        "invalid-dispatch-mode",
        lambda data: suite(data, chainsaw_id)["dispatch"].__setitem__("mode", "other"),
        f"Catalog entry {chainsaw_id} has invalid dispatch mode 'other'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "invalid-chainsaw-selector",
        lambda data: suite(data, chainsaw_id)["dispatch"].__setitem__("selector", "bad"),
        f"Chainsaw entry {chainsaw_id} has an invalid path or selector.\n",
    )
    expect_rejection(
        root,
        canonical,
        "empty-chainsaw-selection",
        lambda data: suite(data, chainsaw_id)["dispatch"].__setitem__(
            "selector", "homelab-talos/suite=not-present"
        ),
        f"Chainsaw entry {chainsaw_id} selects no test documents.\n",
    )

    bash_id = "test.integration.media-hardlink"
    expect_rejection(
        root,
        canonical,
        "invalid-direct-bash",
        lambda data: suite(data, bash_id)["metadata"].__setitem__("framework", "just"),
        f"Direct Bash entry {bash_id} must name an executable Bash implementation.\n",
    )
    python_id = "test.e2e.qbit-manage-policy"
    expect_rejection(
        root,
        canonical,
        "invalid-direct-python",
        lambda data: suite(data, python_id)["dispatch"].__setitem__(
            "path", "scripts/test/scenarios/media-hardlink.sh"
        ),
        f"Direct Python entry {python_id} must name a Python implementation.\n",
    )
    expect_rejection(
        root,
        canonical,
        "direct-path-not-allowlisted",
        lambda data: suite(data, bash_id)["dispatch"].__setitem__(
            "path", "scripts/validate/cilium.sh"
        ),
        f"Direct entry {bash_id} must use an allowlisted scenario/probe path.\n",
    )


def campaign_contract(root: Path, canonical: dict[str, Any]) -> None:
    def remove_campaign(data: dict[str, Any]) -> None:
        del data["campaigns"]["weekly"]

    expect_rejection(
        root,
        canonical,
        "campaign-names",
        remove_campaign,
        "Test catalog campaign names differ from the supported public interface.\n"
        "--- /dev/fd/<fd>\t<timestamp>\n"
        "+++ /dev/fd/<fd>\t<timestamp>\n"
        "@@ -10,4 +10,3 @@\n"
        " standard\n"
        " validation\n"
        " verification\n"
        "-weekly\n",
        normalize_diff=True,
    )
    expect_acceptance(
        root,
        canonical,
        "empty-campaign-description",
        lambda data: data["campaigns"]["conformance-certified"].__setitem__("description", ""),
    )
    expect_rejection(
        root,
        canonical,
        "invalid-campaign-metadata",
        lambda data: data["campaigns"]["conformance-certified"].__setitem__(
            "members", "conformance.certified"
        ),
        "Error: no matches found\n"
        "Campaign conformance-certified has invalid metadata or member/include arrays.\n",
    )
    expect_rejection(
        root,
        canonical,
        "unknown-campaign-include",
        lambda data: data["campaigns"]["conformance-certified"].__setitem__(
            "includes", ["not-present"]
        ),
        "Unknown test campaign: not-present.\n"
        "Campaign conformance-certified includes an unknown campaign: not-present\n",
    )
    expect_rejection(
        root,
        canonical,
        "incorrect-derived-mutation",
        lambda data: data["campaigns"]["conformance-certified"].__setitem__(
            "mutates_cluster", False
        ),
        "Campaign conformance-certified mutates_cluster does not match its resolved members.\n",
    )
    expect_rejection(
        root,
        canonical,
        "incorrect-derived-disruption",
        lambda data: data["campaigns"]["resilience"].__setitem__("disruptive", False),
        "Campaign resilience disruptive does not match its resolved members.\n",
    )


def conformance_contract(root: Path, canonical: dict[str, Any]) -> None:
    def replace_certified_conformance(data: dict[str, Any]) -> None:
        campaign = data["campaigns"]["conformance-certified"]
        campaign["members"] = ["chainsaw.smoke.cluster.diagnostics-self-test"]
        campaign["mutates_cluster"] = False

    expect_rejection(
        root,
        canonical,
        "conformance-coverage",
        replace_certified_conformance,
        "Conformance campaigns differs from the explicit catalog contract.\n"
        "--- /dev/fd/<fd>\t<timestamp>\n"
        "+++ /dev/fd/<fd>\t<timestamp>\n"
        "@@ -1,2 +1,2 @@\n"
        "-conformance.certified\n"
        "+chainsaw.smoke.cluster.diagnostics-self-test\n"
        " conformance.quick\n",
        normalize_diff=True,
    )


def campaign_composition_contract(root: Path, canonical: dict[str, Any]) -> None:
    expect_rejection(
        root,
        canonical,
        "validation-composition",
        lambda data: data["campaigns"]["validation"].__setitem__(
            "members", ["validation.repo-lint"]
        ),
        "Campaign validation must execute only the aggregate validation.ci suite.\n",
    )
    composition_cases = {
        "standard": (
            "Campaign standard must be validation, smoke, e2e, then conformance-quick.\n"
        ),
        "weekly": "Campaign weekly has an unexpected composition.\n",
        "full": "Campaign full must extend weekly with certified conformance.\n",
    }
    for campaign, message in composition_cases.items():
        expect_rejection(
            root,
            canonical,
            f"{campaign}-composition",
            lambda data, campaign=campaign: data["campaigns"][campaign]["includes"].reverse(),
            message,
        )

    expect_rejection(
        root,
        canonical,
        "smoke-ordering",
        lambda data: data["campaigns"]["smoke"]["members"].reverse(),
        "Campaign smoke aggregate ordering differs from the explicit catalog contract.\n"
        "--- /dev/fd/<fd>\t<timestamp>\n"
        "+++ /dev/fd/<fd>\t<timestamp>\n"
        "@@ -1,4 +1,4 @@\n"
        "-chainsaw.smoke.cluster.default\n"
        "-chainsaw.smoke.media.qbittorrent\n"
        "-chainsaw.smoke.media.qbit-manage\n"
        " chainsaw.smoke.platform.all\n"
        "+chainsaw.smoke.media.qbit-manage\n"
        "+chainsaw.smoke.media.qbittorrent\n"
        "+chainsaw.smoke.cluster.default\n",
        normalize_diff=True,
    )
    expect_rejection(
        root,
        canonical,
        "integration-ordering",
        lambda data: data["campaigns"]["integration"]["members"].reverse(),
        "Campaign integration ordering differs from the explicit catalog contract.\n"
        "--- /dev/fd/<fd>\t<timestamp>\n"
        "+++ /dev/fd/<fd>\t<timestamp>\n"
        "@@ -1,8 +1,8 @@\n"
        "-test.cilium-connectivity\n"
        "-test.storage-provisioning\n"
        "-test.flux-canary\n"
        "-test.n8n-restore-drill\n"
        "-test.automation-data-restore-drill\n"
        "-test.integration.media-hardlink\n"
        "-test.plex-network-policy\n"
        " test.ntfy-publish\n"
        "+test.plex-network-policy\n"
        "+test.integration.media-hardlink\n"
        "+test.automation-data-restore-drill\n"
        "+test.n8n-restore-drill\n"
        "+test.flux-canary\n"
        "+test.storage-provisioning\n"
        "+test.cilium-connectivity\n",
        normalize_diff=True,
    )
    expect_rejection(
        root,
        canonical,
        "resilience-ordering",
        lambda data: data["campaigns"]["resilience"]["members"].reverse(),
        "Campaign resilience ordering differs from the explicit catalog contract.\n"
        "--- /dev/fd/<fd>\t<timestamp>\n"
        "+++ /dev/fd/<fd>\t<timestamp>\n"
        "@@ -1,8 +1,8 @@\n"
        "-test.flux-restart\n"
        "-test.portainer-persistence\n"
        "-test.n8n-persistence\n"
        "-chainsaw.resilience.qbittorrent-vpn-disconnect\n"
        "-chainsaw.resilience.qbittorrent-pod-recreation\n"
        "-chainsaw.resilience.plex-cross-node-reschedule\n"
        "-chainsaw.resilience.test-reports-persistence\n"
        " chainsaw.resilience.tailscale-subnet-router-replica-recovery\n"
        "+chainsaw.resilience.test-reports-persistence\n"
        "+chainsaw.resilience.plex-cross-node-reschedule\n"
        "+chainsaw.resilience.qbittorrent-pod-recreation\n"
        "+chainsaw.resilience.qbittorrent-vpn-disconnect\n"
        "+test.n8n-persistence\n"
        "+test.portainer-persistence\n"
        "+test.flux-restart\n",
        normalize_diff=True,
    )


def execution_contract(root: Path, canonical: dict[str, Any]) -> None:
    assert set(CI_GROUP_EXECUTIONS) <= set(canonical["executions"]), (
        "Catalog is missing one or more CI group executions."
    )
    assert set(canonical["executions"]) == {"ci", *CI_GROUP_EXECUTIONS}
    assert len(ci_group_members(canonical)) == len(set(ci_group_members(canonical)))
    assert ci_group_members(canonical) == canonical["executions"]["ci"]

    harness_groups = {
        "core": "ci-core",
        "observability": "ci-observability",
        "automation": "ci-automation",
        "ci-framework": "ci-framework",
    }
    for group, execution in harness_groups.items():
        suite_id = f"validation.test-harness-{group}"
        assert canonical["executions"][execution].count(suite_id) == 1
        assert (
            sum(
                suite_id in canonical["executions"][candidate] for candidate in CI_GROUP_EXECUTIONS
            )
            == 1
        )
        record = suite(canonical, suite_id)
        assert record["runner"]["command"] == f"mise exec -- just test validate {group}"
        assert record["runner"]["implementation"] == "scripts/test/validate-chainsaw.sh"
        assert record["native_results"] == {"strategy": "native-junit"}

    expect_rejection(
        root,
        canonical,
        "missing-ci-group",
        lambda data: data["executions"].pop("ci-observability"),
        "Missing CI group execution: ci-observability.\n",
    )
    expect_rejection(
        root,
        canonical,
        "duplicate-ci-group-member",
        lambda data: data["executions"]["ci-core"].append(
            data["executions"]["ci-observability"][0]
        ),
        "CI group executions contain duplicate suite IDs.\n",
    )
    expect_rejection(
        root,
        canonical,
        "unknown-ci-group-member",
        lambda data: data["executions"]["ci-core"].__setitem__(0, "validation.unknown"),
        "CI group executions are not the exact full CI partition.\n",
    )
    expect_rejection(
        root,
        canonical,
        "wrong-ci-harness-command",
        lambda data: suite(data, "validation.test-harness-core")["runner"].__setitem__(
            "command", "mise exec -- just test validate automation"
        ),
        "CI harness suite validation.test-harness-core must use command "
        "'mise exec -- just test validate core'.\n",
    )
    expect_rejection(
        root,
        canonical,
        "ci-target-absent-from-groups",
        lambda data: data["executions"]["ci-core"].pop(),
        "CI group executions are not the exact full CI partition.\n",
    )
    expect_rejection(
        root,
        canonical,
        "reordered-full-ci-execution",
        lambda data: data["executions"]["ci"].reverse(),
        "CI group executions are not in canonical full-CI order.\n",
    )
    expect_rejection(
        root,
        canonical,
        "extra-ci-execution",
        lambda data: data["executions"].__setitem__("ci-security", []),
        "Test catalog execution names must be ci plus the four CI group executions.\n",
    )

    expect_rejection(
        root,
        canonical,
        "duplicate-ci-id",
        lambda data: data["executions"]["ci"].append(data["executions"]["ci"][0]),
        "Duplicate executions.ci suite IDs: validation.repo-lint\n",
    )

    def add_unregistered_validation(data: dict[str, Any]) -> None:
        entry = copy.deepcopy(suite(data, "validation.repo-lint"))
        entry["metadata"]["id"] = "validation.extra"
        data["suites"].append(entry)

    expect_rejection(
        root,
        canonical,
        "validation-count",
        add_unregistered_validation,
        "Validation catalog/executions.ci count differs: catalog=44 ci=43.\n",
    )
    expect_rejection(
        root,
        canonical,
        "missing-chainsaw-dispatch",
        lambda data: data["suites"].remove(
            suite(data, "chainsaw.smoke.cluster.diagnostics-self-test")
        ),
        "Error: no matches found\n"
        "Chainsaw document "
        "tests/chainsaw/smoke/cluster/diagnostics-self-test/chainsaw-test.yaml has no "
        "exact catalog dispatch entry.\n",
    )


def fail_fast_contract(root: Path, canonical: dict[str, Any]) -> None:
    def duplicate_and_unsafe(data: dict[str, Any]) -> None:
        data["suites"].append(copy.deepcopy(data["suites"][0]))
        suite(data, "chainsaw.smoke.cluster.default")["dispatch"]["path"] = "../outside"

    expect_rejection(
        root,
        canonical,
        "fail-fast-top-level-before-entry",
        duplicate_and_unsafe,
        "Duplicate test catalog IDs: validation.ci\n",
    )


def access_boundary_contract(root: Path, canonical: dict[str, Any]) -> None:
    assert canonical["campaigns"]["scoped-verification"].get("execution_mode") == (
        "scoped-local"
    ), "scoped-verification does not declare scoped-local execution"
    assert canonical["campaigns"]["verification"].get("execution_mode") == (
        "operator-published"
    ), "verification does not declare operator-published execution"
    logging = suite(canonical, "verification.logging")
    assert logging.get("access", {}).get("tier") == "diagnostic", (
        "verification.logging is not diagnostic-tier"
    )
    for campaign_name in ("verification", "scoped-verification"):
        assert "verification.logging" in canonical["campaigns"][campaign_name]["members"], (
            f"verification.logging is absent from {campaign_name}"
        )
    analyze = catalog_validator.forbidden_kubernetes_operations
    forbidden_cases = {
        "array-secret": 'kc=(kubectl --kubeconfig x)\n"${kc[@]}" get secrets',
        "renamed-secret": 'k=kubectl\n"$k" get --namespace monitoring secret foo',
        "readonly-renamed-delete": 'readonly cmd=kubectl\n"$cmd" delete pod app',
        "path-delete": "/usr/local/bin/kubectl delete pod app",
        "raw-equals": "kubectl get --raw=/api/v1/secrets",
        "raw-value": "kubectl get --raw /api/v1/pods",
        "dynamic-command": 'cmd=$(printf kubectl)\n"$cmd" get pods',
        "unresolved-command": '"$cmd" get pods',
        "shell-alias": "alias k='kubectl get pods'\nk",
        "substitution-in-argument": 'echo "$(kubectl get secrets)"',
        "nested-substitution-in-argument": ('echo "$(printf \'%s\' "$(kubectl get secrets)")"'),
        "dynamic-command-substitution": "$(printf kubectl) delete pod app",
        "dynamic-assignment-command": 'tool=$(printf kubectl); "$tool" delete pod app',
        "env-launcher": "env -i KUBECONFIG=x kubectl delete pod app",
        "command-launcher": "command -- kubectl delete pod app",
        "comma-separated-secret": "kubectl get pods,secrets",
        "builtin-launcher": "builtin -- kubectl delete pod app",
        "positional-one-command": '"$1" delete pod app',
        "braced-positional-command": '"${1}" delete pod app',
        "positional-argv-command": '"$@" delete pod app',
        "braced-positional-argv-command": '"${@}" delete pod app',
        "positional-all-command": '"$*" delete pod app',
        "braced-positional-all-command": '"${*}" delete pod app',
        "adjacent-positional-command": 'kubectl"$1" delete pod app',
        "resolved-positional-wrapper-mutation": ('run() { "$@"; }\nrun kubectl delete pod app'),
        "env-short-split-string": 'env -S "kubectl delete pod app"',
        "env-attached-split-string": 'env -S"kubectl delete pod app"',
        "env-long-split-string": 'env --split-string "kubectl delete pod app"',
        "env-equals-split-string": 'env --split-string="kubectl delete pod app"',
        "option-between": "kubectl --namespace monitoring get --output name secrets",
        "namespace-before-secret": "kubectl get -n monitoring secrets",
        "helper-secret": 'kg() { kubectl get "$@"; }\nkg --output name secrets',
        "helm-storage": "helm get values cilium --namespace kube-system",
        "unknown": "kubectl frobnicate pods",
        "rollout-restart": "kubectl rollout restart deployment/app",
        "rollout-undo": "kubectl rollout undo deployment/app",
        "run": "kubectl run shell --image=busybox",
        "cordon": "kubectl cordon node-a",
        "uncordon": "kubectl uncordon node-a",
        "drain": "kubectl drain node-a",
        "taint": "kubectl taint nodes node-a dedicated=test:NoSchedule",
        "cp": "kubectl cp pod:/tmp/a ./a",
        "attach": "kubectl attach pod/app",
        "debug": "kubectl debug pod/app --image=busybox",
        "create": "kubectl create configmap sample",
        "replace": "kubectl replace --filename object.yaml",
        "apply": "kubectl apply --filename object.yaml",
        "delete": "kubectl delete pod app",
        "edit": "kubectl edit deployment app",
        "patch": "kubectl --namespace default patch deployment app -p {}",
        "scale": "kubectl scale deployment app --replicas=2",
        "set": "kubectl set image deployment/app app=image",
        "label": "kubectl label pod app changed=true",
        "annotate": "kubectl annotate pod app changed=true",
        "expose": "kubectl expose deployment app",
        "autoscale": "kubectl autoscale deployment app --min=1 --max=2",
    }
    for name, source in forbidden_cases.items():
        assert analyze(source), f"{name}: forbidden operation was not detected"
    safe_cases = {
        "get": "kubectl --namespace default get pods",
        "secret-as-name": "kubectl get pod secret",
        "echo-command-text": "echo kubectl delete pods",
        "printf-command-text": "printf '%s\\n' 'kubectl get secrets'",
        "assignment-only": "note=kubectl",
        "safe-substitution": 'echo "$(kubectl get pods)"',
        "single-quoted-substitution-text": "echo '$(kubectl get secrets)'",
        "safe-env-launcher": "env -i LANG=C kubectl get pods",
        "safe-command-launcher": "command -- kubectl get pod secret",
        "safe-command-lookup": "command -v kubectl",
        "safe-builtin-launcher": "builtin -- kubectl get pods",
        "positional-ordinary-argument": 'kubectl get pod "$1"',
        "positional-argv-ordinary-argument": 'echo "$@"',
        "resolved-positional-wrapper-read": 'run() { "$@"; }\nrun kubectl get pods',
        "describe": "kubectl describe pod app",
        "logs": "kubectl logs deployment/app --tail=10",
        "wait": "kubectl wait --for=condition=Ready pod/app",
        "rollout-status": "kubectl rollout status deployment/app",
        "auth-can-i": "kubectl auth can-i get secrets",
        "config-contexts": "kubectl config get-contexts homelab-observer",
        "config-current": "kubectl config current-context",
        "config-view": "kubectl config view --minify",
        "api-resources": "kubectl api-resources",
        "api-versions": "kubectl api-versions",
        "version": "kubectl version --client",
        "top": "kubectl top nodes",
    }
    for name, source in safe_cases.items():
        assert analyze(source) == [], f"{name}: safe operation was rejected: {analyze(source)}"
    assert analyze("kubectl exec deployment/app -- true", allow_interactive=True) == []
    assert analyze("kubectl port-forward service/app 8080:80", allow_interactive=True) == []
    assert analyze("kubectl exec deployment/app -- true"), "observer exec was accepted"
    assert analyze("kubectl port-forward service/app 8080:80"), (
        "observer port-forward was accepted"
    )
    assert analyze("assert_can_i observer no create pods/exec") == []

    fixture = root / "access-reachability"
    (fixture / "scripts/verify").mkdir(parents=True)
    (fixture / "kubernetes").mkdir()
    (fixture / "scripts/verify/root.sh").write_text(
        "#!/usr/bin/env bash\njust kube root-check\n", encoding="utf-8"
    )
    (fixture / "kubernetes/mod.just").write_text(
        "root-check: nested-check\n    true\n"
        "nested-check:\n    kubectl get --output name secrets\n",
        encoding="utf-8",
    )
    reachable = catalog_validator.reachable_verifier_source(fixture, "scripts/verify/root.sh")
    assert analyze(reachable), "nested Just recipe bypass was not detected"

    lease_fixture = root / "lease-reachability"
    (lease_fixture / "scripts/verify").mkdir(parents=True)
    (lease_fixture / "scripts/lib").mkdir(parents=True)
    (lease_fixture / "kubernetes").mkdir()
    (lease_fixture / "scripts/verify/root.sh").write_text(
        "#!/usr/bin/env bash\nsource scripts/lib/lease.sh\nlease_kubectl cfg delete lease lock\n",
        encoding="utf-8",
    )
    (lease_fixture / "scripts/lib/lease.sh").write_text(
        "lease_kubectl() {\n"
        '  local kubeconfig="$1"\n'
        "  shift\n"
        '  "${TEST_LEASE_KUBECTL:-kubectl}" --kubeconfig "$kubeconfig" "$@"\n'
        "}\n",
        encoding="utf-8",
    )
    (lease_fixture / "kubernetes/mod.just").write_text("", encoding="utf-8")
    lease_source = catalog_validator.reachable_verifier_source(
        lease_fixture, "scripts/verify/root.sh"
    )
    assert analyze(lease_source) == ["kubectl subcommand (delete)"], (
        f"indirect lease_kubectl mutation was not resolved: {analyze(lease_source)}"
    )

    escape = root / "escape.sh"
    escape.write_text("kubectl delete pods --all\n", encoding="utf-8")
    traversal_root = root / "traversal"
    traversal_root.mkdir()
    try:
        catalog_validator.reachable_verifier_source(traversal_root, "../escape.sh")
    except catalog_validator.ValidationFailure as failure:
        assert "outside repository root" in failure.message
    else:
        raise AssertionError("implementation path traversal was accepted")

    dynamic_fixture = root / "dynamic-reachability"
    (dynamic_fixture / "scripts/verify").mkdir(parents=True)
    (dynamic_fixture / "kubernetes").mkdir()
    (dynamic_fixture / "scripts/verify/root.sh").write_text(
        '#!/usr/bin/env bash\nhelper="scripts/verify/helper.sh"\nsource "$helper"\n',
        encoding="utf-8",
    )
    (dynamic_fixture / "scripts/verify/helper.sh").write_text("true\n", encoding="utf-8")
    (dynamic_fixture / "kubernetes/mod.just").write_text("", encoding="utf-8")
    try:
        catalog_validator.reachable_verifier_source(dynamic_fixture, "scripts/verify/root.sh")
    except catalog_validator.ValidationFailure as failure:
        assert "dynamic source target" in failure.message
    else:
        raise AssertionError("dynamic source target was accepted")

    (dynamic_fixture / "scripts/verify/root.sh").write_text(
        '#!/usr/bin/env bash\nrecipe="nested"\njust kube "$recipe"\n',
        encoding="utf-8",
    )
    try:
        catalog_validator.reachable_verifier_source(dynamic_fixture, "scripts/verify/root.sh")
    except catalog_validator.ValidationFailure as failure:
        assert "dynamic Just recipe target" in failure.message
    else:
        raise AssertionError("dynamic Just recipe target was accepted")

    assert analyze('runner() { "$command" "$@"; }\nrunner get pods'), (
        "unresolved dynamic wrapper was accepted"
    )

    helper_fixture = root / "executable-helper-reachability"
    (helper_fixture / "scripts/verify").mkdir(parents=True)
    (helper_fixture / "kubernetes").mkdir()
    (helper_fixture / "scripts/verify/root.sh").write_text(
        '#!/usr/bin/env bash\nreadonly verifier=scripts/verify/helper.sh\n"$verifier"\n',
        encoding="utf-8",
    )
    (helper_fixture / "scripts/verify/helper.sh").write_text(
        "kubectl delete pod app\n", encoding="utf-8"
    )
    (helper_fixture / "kubernetes/mod.just").write_text("", encoding="utf-8")
    helper_source = catalog_validator.reachable_verifier_source(
        helper_fixture, "scripts/verify/root.sh"
    )
    assert analyze(helper_source) == ["kubectl subcommand (delete)"], (
        "literal executable helper variable was not traversed"
    )

    (helper_fixture / "scripts/verify/root.sh").write_text(
        '#!/usr/bin/env bash\nhelper="${HELPER_PATH}"\n"$helper"\n',
        encoding="utf-8",
    )
    try:
        catalog_validator.reachable_verifier_source(helper_fixture, "scripts/verify/root.sh")
    except catalog_validator.ValidationFailure as failure:
        assert "dynamic executable helper" in failure.message
    else:
        raise AssertionError("dynamic executable helper variable was accepted")

    def diagnostic_without_context(data: dict[str, Any]) -> None:
        suite(data, "verification.homepage")["runner"]["implementation"] = (
            "scripts/verify/metrics-server.sh"
        )

    expect_rejection(
        root,
        canonical,
        "diagnostic-context-contract",
        diagnostic_without_context,
        "Diagnostic verifier verification.homepage must select homelab-diagnostic "
        "conditionally.\n",
    )

    def agent_access_without_matrix(data: dict[str, Any]) -> None:
        suite(data, "verification.agent-access")["runner"]["implementation"] = (
            "scripts/verify/metrics-server.sh"
        )

    expect_rejection(
        root,
        canonical,
        "agent-access-matrix-contract",
        agent_access_without_matrix,
        "verification.agent-access does not cover the required authorization matrix.\n",
    )

    def portainer_without_rbac_oracle(data: dict[str, Any]) -> None:
        suite(data, "verification.portainer")["runner"]["implementation"] = (
            "scripts/verify/metrics-server.sh"
        )

    expect_rejection(
        root,
        canonical,
        "portainer-rbac-oracle",
        portainer_without_rbac_oracle,
        "verification.portainer must prove exact live RBAC without impersonation.\n",
    )

    def campaign_rbac_drift(data: dict[str, Any]) -> None:
        data["campaigns"]["scoped-verification"]["access"]["required_read_rules"][
            "cilium.io"
        ].remove("ciliumnodes")

    expect_rejection(
        root,
        canonical,
        "scoped-campaign-rbac-drift",
        campaign_rbac_drift,
        "Scoped verifier campaign requirements and observer RBAC grants differ.\n",
    )

    def operator_only_full_campaign(data: dict[str, Any]) -> None:
        suite(data, "verification.monitoring")["access"]["tier"] = "operator"
        data["campaigns"]["scoped-verification"]["members"].remove("verification.monitoring")

    expect_acceptance(
        root,
        canonical,
        "operator-only-full-campaign",
        operator_only_full_campaign,
    )

    expect_rejection(
        root,
        canonical,
        "wrong-scoped-execution-mode",
        lambda data: data["campaigns"]["scoped-verification"].__setitem__(
            "execution_mode", "operator-published"
        ),
        "Campaign scoped-verification must use scoped-local execution.\n",
    )
    expect_rejection(
        root,
        canonical,
        "wrong-operator-execution-mode",
        lambda data: data["campaigns"]["verification"].__setitem__(
            "execution_mode", "scoped-local"
        ),
        "Campaign verification must use operator-published execution.\n",
    )

    def entry_before_campaign(data: dict[str, Any]) -> None:
        suite(data, "validation.ci")["metadata"]["source"] = "other"
        data["campaigns"]["standard"]["includes"].append("full")

    expect_rejection(
        root,
        canonical,
        "fail-fast-entry-before-campaign",
        entry_before_campaign,
        "Catalog entry validation.ci has invalid source 'other'.\n",
    )

    def campaign_before_execution(data: dict[str, Any]) -> None:
        data["campaigns"]["standard"]["includes"].append("full")
        data["executions"]["ci"].append(data["executions"]["ci"][0])

    expect_rejection(
        root,
        canonical,
        "fail-fast-campaign-before-execution",
        campaign_before_execution,
        "Test campaign include cycle: standard -> full -> weekly -> standard.\n",
        expected_status=2,
    )


def main() -> int:
    completed = run_validator(CATALOG)
    assert completed.returncode == 0, completed.stderr
    assert completed.stdout == "Test catalog passed validation: suites=120.\n"
    assert completed.stderr == ""
    canonical = yaml.safe_load(CATALOG.read_text(encoding="utf-8"))
    groups = {
        "existing": existing_negative_contract,
        "top-level": top_level_contract,
        "entry": entry_contract,
        "dispatch": dispatch_contract,
        "campaign": campaign_contract,
        "conformance": conformance_contract,
        "campaign-composition": campaign_composition_contract,
        "execution": execution_contract,
        "fail-fast": fail_fast_contract,
        "access-boundary": access_boundary_contract,
    }
    selected = sys.argv[1:] or list(groups)
    unknown = set(selected) - groups.keys()
    assert not unknown, f"unknown compatibility groups: {sorted(unknown)}"
    with tempfile.TemporaryDirectory(prefix="homelab-catalog-contract-") as temporary:
        for group in selected:
            groups[group](Path(temporary), canonical)
    print("Test catalog compatibility contract passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
