"""Canonical test authority; fixture catalogs never select production credentials."""

import hashlib
import os
import re
import sys
from pathlib import Path

import yaml

from scripts.openbao.configuration import SafeError
from scripts.openbao.credentials import SUITE_PROFILE_BINDINGS

BASE_PROFILES = {"observer", "debugger", "test-runner", "report-publisher", "campaign-coordinator"}
PREREQUISITES = {
    "talos-reader",
    "talos-operator",
    "physical-power",
    "application-credential",
    "openbao-operator",
    "openbao-recovery",
}
AUDIT_SUITES = {"verification.agent-access", "test.agent-credentials"}
HOST_LOCAL_SUITES = {"test.nocodb-local-integration", "test.web-research-local-integration"}
PHYSICAL_SUITE = "test.resilience.node-abrupt-loss"


def validate_access(entry: dict) -> None:
    metadata = entry.get("metadata", {})
    suite_id = metadata.get("id")
    declaration = entry.get("access")
    if (
        not isinstance(declaration, dict)
        or not {"profile", "prerequisites"} <= declaration.keys()
        or declaration.keys() - {"profile", "prerequisites", "profile_checks", "operator_boundary"}
    ):
        raise SafeError("invalid-source")
    profile = declaration["profile"]
    prerequisites = declaration["prerequisites"]
    if (
        not isinstance(prerequisites, list)
        or any(not isinstance(value, str) or value not in PREREQUISITES for value in prerequisites)
        or len(set(prerequisites)) != len(prerequisites)
        or (profile is not None and not isinstance(profile, str))
    ):
        raise SafeError("invalid-source")
    if profile is None:
        if metadata.get("tier") != "offline" and suite_id not in HOST_LOCAL_SUITES | {
            PHYSICAL_SUITE
        }:
            raise SafeError("invalid-source")
    elif (
        profile not in BASE_PROFILES | SUITE_PROFILE_BINDINGS.keys()
        or profile in {"report-publisher", "campaign-coordinator"}
        or metadata.get("tier") == "offline"
        or suite_id in HOST_LOCAL_SUITES | {PHYSICAL_SUITE}
    ):
        raise SafeError("invalid-source")
    for dedicated, suites in SUITE_PROFILE_BINDINGS.items():
        if (suite_id in suites) != (profile == dedicated):
            raise SafeError("invalid-source")
    attended = set(prerequisites) & {
        "talos-operator",
        "physical-power",
        "application-credential",
        "openbao-operator",
        "openbao-recovery",
    }
    if attended and metadata.get("execution_owner") != "human":
        raise SafeError("invalid-source")
    if suite_id == PHYSICAL_SUITE:
        if declaration.get("operator_boundary") != "physical-power-and-talos" or not {
            "talos-operator",
            "physical-power",
        } <= set(prerequisites):
            raise SafeError("invalid-source")
    elif "operator_boundary" in declaration:
        raise SafeError("invalid-source")
    checks = declaration.get("profile_checks")
    if suite_id in AUDIT_SUITES:
        if (
            not isinstance(checks, list)
            or not checks
            or any(not isinstance(value, str) or value not in BASE_PROFILES for value in checks)
            or len(set(checks)) != len(checks)
        ):
            raise SafeError("invalid-source")
    elif checks is not None:
        raise SafeError("invalid-source")
    required = {
        "test.openbao-ha": {"openbao-operator"},
        "test.openbao-restore-drill": {"openbao-operator", "openbao-recovery"},
        "test.agent-credentials": {"openbao-operator"},
    }.get(suite_id, set())
    if not required <= set(prerequisites):
        raise SafeError("invalid-source")


def resolve_suite_access(repo_root: Path, suite_id: str) -> dict:
    catalog_path = repo_root / "tests/catalog.yaml"
    override = os.environ.get("TEST_CATALOG_PATH")
    if override and Path(override).absolute() != catalog_path.absolute():
        raise SafeError("invalid-source")
    for variable, default in (
        ("NOCODB_ACCESS_EXTENSION_CONFIRM", "test.nocodb-access"),
        ("NOCODB_RESTORE_EXTENSION_CONFIRM", "test.nocodb-restore-drill"),
    ):
        if suite_id == default and os.environ.get(variable):
            raise SafeError("invalid-source")
    try:
        raw = catalog_path.read_bytes()
        catalog = yaml.safe_load(raw)
        if catalog.get("schema_version") != 3:
            raise SafeError("invalid-source")
        entries = [entry for entry in catalog["suites"] if entry["metadata"]["id"] == suite_id]
        if len(entries) != 1:
            raise SafeError("invalid-source")
        entry = entries[0]
        validate_access(entry)
    except (OSError, KeyError, TypeError, AttributeError, yaml.YAMLError):
        raise SafeError("invalid-source") from None
    return {
        "suite_id": suite_id,
        "catalog_digest": hashlib.sha256(raw).hexdigest(),
        **entry["access"],
    }


def prepare_invocation(repo_root: Path, suite_id: str, run_id: str) -> Path | None:
    from scripts.openbao import credentials, workstation

    declaration = resolve_suite_access(repo_root, suite_id)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", run_id):
        raise SafeError("invalid-source")
    if declaration["profile"] is None:
        return None
    binding = {"schema_version": 1, "run_id": run_id, **declaration}
    return credentials.install_invocation_kubeconfig(repo_root, workstation.DIRECTORY, binding)


def validate_invocation(repo_root: Path, config_path: Path) -> dict:
    from scripts.openbao import credentials, workstation

    binding, config = credentials.read_invocation(repo_root, config_path)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", str(binding.get("run_id", ""))):
        raise SafeError("invalid-source")
    expected = {
        "schema_version": 1,
        "run_id": binding["run_id"],
        **resolve_suite_access(repo_root, binding.get("suite_id")),
    }
    if binding != expected or binding["profile"] is None:
        raise SafeError("invalid-source")
    local = credentials.load_workstation(workstation.DIRECTORY)
    if local["cluster"]["schema_version"] != 2 or config != credentials._invocation_config(
        repo_root, local["cluster"], binding, config_path
    ):
        raise SafeError("invalid-source")
    return binding


def remove_invocation(repo_root: Path, config_path: Path) -> None:
    from scripts.openbao import credentials

    # Source drift can invalidate refresh, but must not prevent removal of owned config files.
    credentials.remove_invocation_files(repo_root, config_path)


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parents[2]
    try:
        if len(argv) == 4 and argv[1] == "prepare":
            path = prepare_invocation(root, argv[2], argv[3])
            if path is not None:
                print(path)
        elif len(argv) == 3 and argv[1] == "validate":
            import json

            print(json.dumps(validate_invocation(root, Path(argv[2]))))
        elif len(argv) == 3 and argv[1] == "remove":
            remove_invocation(root, Path(argv[2]))
        else:
            raise SafeError("invalid-source")
        return 0
    except Exception:  # noqa: BLE001 -- Credential-bearing exceptions must never be rendered.
        print("Test credential unavailable: invalid-source", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
