"""Write the operator-owned Crawl4AI bootstrap Secret as SOPS ciphertext.

Supply both values for every write. Preserve CRAWL4AI_SIGNING_KEY during routine
administrative API-token rotation. Change it intentionally only when all issued JWTs
must be revoked during the coordinated server cutover.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

import yaml

TARGET = Path("kubernetes/apps/web-research/crawl4ai/app/bootstrap.sops.yaml")
KUSTOMIZATION = Path("kubernetes/apps/web-research/crawl4ai/app/kustomization.yaml")
RESOURCE = "./bootstrap.sops.yaml"
CONFIRMATION = "write:web-research:crawl4ai:sops"
SECRET_KEYS = {"api_token", "signing_key"}


class SecretWriteError(RuntimeError):
    """A token-free failure safe to show to the operator."""


def _load_yaml(content: bytes | str, description: str) -> dict[str, Any]:
    try:
        document = yaml.safe_load(content)
    except yaml.YAMLError as error:
        raise SecretWriteError(f"{description} is not valid YAML") from error
    if not isinstance(document, dict):
        raise SecretWriteError(f"{description} must be one YAML mapping")
    return document


def _validate_value(environment: Mapping[str, str], name: str) -> str:
    value = environment.get(name, "")
    if not 32 <= len(value) <= 4096 or any(
        ord(character) < 32 or ord(character) > 126 for character in value
    ):
        raise SecretWriteError(f"{name} must contain 32 to 4096 printable ASCII characters")
    return value


def _sops_policy(root: Path) -> tuple[str, str]:
    policy_path = root / ".sops.yaml"
    try:
        policy = _load_yaml(policy_path.read_bytes(), "the SOPS policy")
    except OSError as error:
        raise SecretWriteError("the SOPS policy is unavailable") from error
    matches: list[tuple[str, str]] = []
    for rule in policy.get("creation_rules", []):
        if not isinstance(rule, dict):
            continue
        path_regex = rule.get("path_regex")
        recipient = rule.get("age")
        encrypted_regex = rule.get("encrypted_regex")
        try:
            selected = isinstance(path_regex, str) and re.search(path_regex, TARGET.as_posix())
        except re.error as error:
            raise SecretWriteError("the SOPS policy contains an invalid path rule") from error
        if selected and isinstance(recipient, str) and isinstance(encrypted_regex, str):
            matches.append((recipient, encrypted_regex))
    if len(matches) != 1 or not all(matches[0]):
        raise SecretWriteError("the target must select exactly one complete SOPS policy")
    return matches[0]


def _validate_ciphertext(
    content: bytes,
    recipient: str,
    encrypted_regex: str,
    supplied_values: tuple[str, str],
    description: str,
) -> None:
    try:
        manifest = _load_yaml(content, description)
        metadata = manifest.get("metadata")
        string_data = manifest.get("stringData")
        sops = manifest.get("sops")
        age = sops.get("age") if isinstance(sops, dict) else None
        recipients = (
            [entry.get("recipient") for entry in age if isinstance(entry, dict)]
            if isinstance(age, list)
            else []
        )
        valid = (
            set(manifest) == {"apiVersion", "kind", "metadata", "type", "stringData", "sops"}
            and manifest.get("apiVersion") == "v1"
            and manifest.get("kind") == "Secret"
            and manifest.get("type") == "Opaque"
            and metadata == {"name": "crawl4ai-bootstrap", "namespace": "web-research"}
            and isinstance(string_data, dict)
            and set(string_data) == SECRET_KEYS
            and all(
                isinstance(value, str) and value.startswith("ENC[AES256_GCM,")
                for value in string_data.values()
            )
            and recipients == [recipient]
            and sops.get("encrypted_regex") == encrypted_regex
        )
    except (AttributeError, TypeError):
        valid = False
    if not valid or any(value.encode() in content for value in supplied_values):
        raise SecretWriteError(f"{description} does not match the required ciphertext contract")


def _repository_state(root: Path, recipient: str, encrypted_regex: str, values: tuple[str, str]):
    target = root / TARGET
    kustomization_path = root / KUSTOMIZATION
    try:
        kustomization_source = kustomization_path.read_bytes()
        kustomization = _load_yaml(kustomization_source, "the Kustomization")
    except OSError as error:
        raise SecretWriteError("the Crawl4AI Kustomization is unavailable") from error
    resources = kustomization.get("resources")
    if not isinstance(resources, list) or not all(isinstance(item, str) for item in resources):
        raise SecretWriteError("the Crawl4AI Kustomization resources are invalid")
    selected = resources.count(RESOURCE)
    conflicting_selection = any(
        item != RESOURCE and Path(os.path.normpath(KUSTOMIZATION.parent / item)) == TARGET
        for item in resources
    )
    target_exists = target.exists()
    if conflicting_selection or selected > 1 or target_exists != (selected == 1):
        raise SecretWriteError("the existing Secret and resource selection are inconsistent")
    if target_exists:
        try:
            target_source = target.read_bytes()
        except OSError as error:
            raise SecretWriteError("the existing ciphertext is unavailable") from error
        _validate_ciphertext(
            target_source, recipient, encrypted_regex, values, "the existing ciphertext"
        )
    else:
        target_source = None
    return kustomization, target_source, kustomization_source


def _run_guard(root: Path, runner: Callable[..., subprocess.CompletedProcess[bytes]]) -> None:
    try:
        result = runner(["just", "repo", "secrets"], cwd=root, capture_output=True, check=False)
    except OSError as error:
        raise SecretWriteError("the repository age-identity check could not run") from error
    if result.returncode != 0:
        raise SecretWriteError("the repository age-identity check failed")


def _encrypt(
    root: Path,
    plaintext: bytes,
    runner: Callable[..., subprocess.CompletedProcess[bytes]],
) -> bytes:
    command = [
        "sops",
        "--encrypt",
        "--input-type",
        "yaml",
        "--output-type",
        "yaml",
        "--filename-override",
        TARGET.as_posix(),
        "/dev/stdin",
    ]
    try:
        result = runner(
            command,
            cwd=root,
            input=plaintext,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise SecretWriteError("SOPS encryption could not run") from error
    if result.returncode != 0 or not result.stdout:
        raise SecretWriteError("SOPS encryption failed")
    return result.stdout


def _install(
    root: Path,
    ciphertext: bytes,
    kustomization: dict[str, Any],
    original_target: bytes | None,
    original_kustomization: bytes,
    replace: Callable[[str | Path, str | Path], None],
) -> None:
    target = root / TARGET
    kustomization_path = root / KUSTOMIZATION
    target_exists = original_target is not None
    with tempfile.TemporaryDirectory(prefix=".crawl4ai-secrets.", dir=target.parent) as temp:
        stage_directory = Path(temp)
        candidate = stage_directory / "bootstrap.sops.yaml"
        candidate.write_bytes(ciphertext)
        candidate.chmod(0o600)
        replacement_started = False
        try:
            if not target_exists:
                updated = dict(kustomization)
                updated["resources"] = [*kustomization["resources"], RESOURCE]
                kustomization_candidate = stage_directory / "kustomization.yaml"
                kustomization_candidate.write_text(
                    yaml.safe_dump(updated, sort_keys=False), encoding="utf-8"
                )
            try:
                current_target = target.read_bytes() if target.exists() else None
                current_kustomization = kustomization_path.read_bytes()
            except OSError as error:
                raise SecretWriteError("repository state changed before installation") from error
            if (
                current_target != original_target
                or current_kustomization != original_kustomization
            ):
                raise SecretWriteError("repository state changed before installation")
            replace(candidate, target)
            replacement_started = True
            if not target_exists:
                replace(kustomization_candidate, kustomization_path)
        except SecretWriteError:
            raise
        except OSError as error:
            if replacement_started:
                if original_target is None:
                    target.unlink(missing_ok=True)
                else:
                    rollback = stage_directory / "previous.sops.yaml"
                    rollback.write_bytes(original_target)
                    os.replace(rollback, target)
            raise SecretWriteError(
                "ciphertext installation failed; existing files were preserved"
            ) from error


def write_bootstrap_secret(
    root: Path,
    environment: Mapping[str, str],
    *,
    runner: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run,
    replace: Callable[[str | Path, str | Path], None] = os.replace,
) -> None:
    """Validate, encrypt, and atomically select the Crawl4AI bootstrap Secret."""
    api_token = _validate_value(environment, "CRAWL4AI_API_TOKEN")
    signing_key = _validate_value(environment, "CRAWL4AI_SIGNING_KEY")
    if environment.get("CRAWL4AI_SECRETS_CONFIRM") != CONFIRMATION:
        raise SecretWriteError("the exact Crawl4AI write confirmation is required")
    recipient, encrypted_regex = _sops_policy(root)
    values = (api_token, signing_key)
    kustomization, original_target, original_kustomization = _repository_state(
        root, recipient, encrypted_regex, values
    )
    _run_guard(root, runner)
    plaintext = yaml.safe_dump(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "crawl4ai-bootstrap", "namespace": "web-research"},
            "type": "Opaque",
            "stringData": {"api_token": api_token, "signing_key": signing_key},
        },
        sort_keys=False,
    ).encode()
    ciphertext = _encrypt(root, plaintext, runner)
    _validate_ciphertext(ciphertext, recipient, encrypted_regex, values, "the SOPS ciphertext")
    _install(
        root,
        ciphertext,
        kustomization,
        original_target,
        original_kustomization,
        replace,
    )


def main() -> int:
    try:
        write_bootstrap_secret(Path(__file__).resolve().parents[2], os.environ)
    except SecretWriteError as error:
        print(f"Crawl4AI bootstrap Secret was not written: {error}.", file=sys.stderr)
        return 1
    print(f"Wrote SOPS-encrypted {TARGET} (crawl4ai-bootstrap in web-research).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
