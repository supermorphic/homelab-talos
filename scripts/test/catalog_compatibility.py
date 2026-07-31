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

import yaml

REPO_ROOT = Path(__file__).parents[2]
VALIDATOR = REPO_ROOT / "scripts/test/validate-catalog.sh"
CATALOG = REPO_ROOT / "tests/catalog.yaml"


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
    assert completed.stdout == "Test catalog passed validation: suites=95.\n"
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
        "-verification.alertmanager-ntfy\n"
        " verification.cilium\n"
        " verification.csi-driver-smb\n"
        " verification.flaresolverr\n",
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
        "@@ -9,4 +9,3 @@\n"
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
        "resilience-ordering",
        lambda data: data["campaigns"]["resilience"]["members"].reverse(),
        "Campaign resilience ordering differs from the explicit catalog contract.\n"
        "--- /dev/fd/<fd>\t<timestamp>\n"
        "+++ /dev/fd/<fd>\t<timestamp>\n"
        "@@ -1,8 +1,8 @@\n"
        "-test.flux-restart\n"
        "-test.portainer-persistence\n"
        "-chainsaw.resilience.qbittorrent-vpn-disconnect\n"
        "-chainsaw.resilience.qbittorrent-pod-recreation\n"
        "-chainsaw.resilience.plex-cross-node-reschedule\n"
        "-chainsaw.resilience.test-reports-persistence\n"
        "-chainsaw.resilience.tailscale-subnet-router-replica-recovery\n"
        " test.resilience.plex-node-reboot\n"
        "+chainsaw.resilience.tailscale-subnet-router-replica-recovery\n"
        "+chainsaw.resilience.test-reports-persistence\n"
        "+chainsaw.resilience.plex-cross-node-reschedule\n"
        "+chainsaw.resilience.qbittorrent-pod-recreation\n"
        "+chainsaw.resilience.qbittorrent-vpn-disconnect\n"
        "+test.portainer-persistence\n"
        "+test.flux-restart\n",
        normalize_diff=True,
    )


def execution_contract(root: Path, canonical: dict[str, Any]) -> None:
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
        "Validation catalog/executions.ci count differs: catalog=33 ci=32.\n",
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
    assert completed.stdout == "Test catalog passed validation: suites=95.\n"
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
