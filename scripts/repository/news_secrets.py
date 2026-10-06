"""Encrypt operator-supplied news bootstrap values using public age recipients only."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from contextlib import ExitStack
from pathlib import Path

import yaml

DB = Path("kubernetes/apps/news/postgresql/app/postgresql-credentials.sops.yaml")
APP = Path("kubernetes/apps/news/freshrss/app/freshrss-runtime.sops.yaml")
KUSTOMIZATION = DB.parent / "kustomization.yaml"
RESOURCE = "./postgresql-credentials.sops.yaml"
CONFIRMATION = "write:news:bootstrap:sops"
PASSWORDS = (
    "NEWS_POSTGRES_PASSWORD",
    "NEWS_DB_PASSWORD",
    "NEWS_BACKUP_PASSWORD",
    "NEWS_MONITORING_PASSWORD",
    "NEWS_OPERATOR_PASSWORD",
    "NEWS_API_PASSWORD",
)
CONTRACTS = {
    DB: (
        "news-postgresql-credentials",
        {
            "postgres-superuser-password": "NEWS_POSTGRES_PASSWORD",
            "freshrss-password": "NEWS_DB_PASSWORD",
            "backup-password": "NEWS_BACKUP_PASSWORD",
            "monitoring-password": "NEWS_MONITORING_PASSWORD",
        },
    ),
    APP: (
        "freshrss-runtime",
        {
            "db-password": "NEWS_DB_PASSWORD",
            "operator-name": "NEWS_OPERATOR_NAME",
            "operator-password": "NEWS_OPERATOR_PASSWORD",
            "api-password": "NEWS_API_PASSWORD",
        },
    ),
}


class SecretWriteError(RuntimeError):
    """A failure whose message contains no credential values or raw tool output."""


def load(content):
    try:
        value = yaml.safe_load(content)
    except yaml.YAMLError:
        raise SecretWriteError("invalid Secret or SOPS policy structure") from None
    if not isinstance(value, dict):
        raise SecretWriteError("Secret and SOPS policy must be mappings")
    return value


def policy(root, target):
    matches = []
    try:
        for rule in load((root / ".sops.yaml").read_bytes()).get("creation_rules", []):
            if re.search(rule["path_regex"], target.as_posix()):
                matches.append(rule)
    except (OSError, TypeError, KeyError, re.error):
        raise SecretWriteError("SOPS recipient policy is unavailable or invalid") from None
    if len(matches) != 1:
        raise SecretWriteError("each target must select exactly one SOPS recipient policy")
    rule = matches[0]
    recipient = rule.get("age", "")
    if (
        not isinstance(recipient, str)
        or not re.fullmatch(r"age1[0-9a-z]{58}", recipient)
        or rule.get("encrypted_regex") != "^(data|stringData)$"
    ):
        raise SecretWriteError(
            "the news policy requires one public age recipient and data encryption"
        )
    return recipient


def validate(content, target, recipient, values):
    document = load(content)
    name, mapping = CONTRACTS[target]
    data, sops = document.get("stringData"), document.get("sops")
    valid = (
        set(document) == {"apiVersion", "kind", "metadata", "type", "stringData", "sops"}
        and document.get("apiVersion") == "v1"
        and document.get("kind") == "Secret"
        and document.get("type") == "Opaque"
        and document.get("metadata") == {"name": name, "namespace": "news"}
        and isinstance(data, dict)
        and set(data) == set(mapping)
        and all(isinstance(v, str) and v.startswith("ENC[AES256_GCM,") for v in data.values())
        and isinstance(sops, dict)
        and sops.get("encrypted_regex") == "^(data|stringData)$"
        and isinstance(sops.get("mac"), str)
        and sops["mac"].startswith("ENC[AES256_GCM,")
        and isinstance(sops.get("age"), list)
        and len(sops["age"]) == 1
        and isinstance(sops["age"][0], dict)
        and sops["age"][0].get("recipient") == recipient
    )
    if not valid or any(value.encode() in content for value in values):
        raise SecretWriteError("ciphertext does not match the news Secret contract")


def write_secrets(root, environment, *, runner=subprocess.run, replace=os.replace):
    """Stage both encrypted artifacts, then replace each atomically with rollback."""
    root = root.resolve()
    if environment.get("NEWS_SECRETS_CONFIRM") != CONFIRMATION:
        raise SecretWriteError("NEWS_SECRETS_CONFIRM must contain the exact write confirmation")
    values = [environment.get(key, "") for key in PASSWORDS]
    if any(
        not 32 <= len(value) <= 4096 or any(ord(c) < 33 or ord(c) > 126 for c in value)
        for value in values
    ):
        raise SecretWriteError(
            "supply each NEWS password as 32 to 4096 printable non-space characters"
        )
    if len(set(values)) != len(values):
        raise SecretWriteError("each role, login and API password must be distinct")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,31}", environment.get("NEWS_OPERATOR_NAME", "")):
        raise SecretWriteError("NEWS_OPERATOR_NAME must be a simple FreshRSS username")
    originals, recipients = {}, {}
    for target in CONTRACTS:
        path = root / target
        if not path.parent.is_dir() or path.is_symlink() or path.resolve() != root / target:
            raise SecretWriteError(
                "news target directories must exist and must not contain symlinks"
            )
        recipients[target] = policy(root, target)
        originals[target] = path.read_bytes() if path.exists() else None
        if originals[target] is not None:
            validate(originals[target], target, recipients[target], values)
    if len({value is None for value in originals.values()}) != 1:
        raise SecretWriteError("existing news bootstrap artifacts must be a complete pair")
    selection_path = root / KUSTOMIZATION
    if selection_path.is_symlink():
        raise SecretWriteError("the database Kustomization must not be a symlink")
    original_selection = selection_path.read_bytes()
    selection = load(original_selection)
    resources = selection.get("resources")
    if not isinstance(resources, list) or not all(isinstance(r, str) for r in resources):
        raise SecretWriteError("database resource selection is invalid")
    equivalent = [r for r in resources if Path(os.path.normpath(DB.parent / r)) == DB]
    if equivalent != ([RESOURCE] if originals[DB] is not None else []):
        raise SecretWriteError("existing database Secret and resource selection are inconsistent")
    originals[KUSTOMIZATION] = original_selection

    with ExitStack() as stack:
        staged, ciphertexts = {}, {}
        for target, (name, mapping) in CONTRACTS.items():
            directory = Path(
                stack.enter_context(
                    tempfile.TemporaryDirectory(
                        prefix=".news-secrets.", dir=(root / target).parent
                    )
                )
            )
            plaintext = yaml.safe_dump(
                {
                    "apiVersion": "v1",
                    "kind": "Secret",
                    "type": "Opaque",
                    "metadata": {"name": name, "namespace": "news"},
                    "stringData": {
                        key: environment[variable] for key, variable in mapping.items()
                    },
                },
                sort_keys=False,
            ).encode()
            # Encryption needs no private identity. Do not pass one to the child.
            child_environment = {
                k: v for k, v in os.environ.items() if not k.startswith("SOPS_AGE_")
            }
            try:
                result = runner(
                    [
                        "sops",
                        "--encrypt",
                        "--input-type",
                        "yaml",
                        "--output-type",
                        "yaml",
                        "--config",
                        str(root / ".sops.yaml"),
                        "--filename-override",
                        target.as_posix(),
                        "/dev/stdin",
                    ],
                    cwd=root,
                    input=plaintext,
                    capture_output=True,
                    env=child_environment,
                    check=False,
                )
            except OSError:
                raise SecretWriteError("SOPS encryption could not run") from None
            if result.returncode or not result.stdout:
                raise SecretWriteError("SOPS encryption failed; tool output withheld")
            validate(result.stdout, target, recipients[target], values)
            candidate = directory / target.name
            candidate.touch(mode=0o600)
            candidate.write_bytes(result.stdout)
            ciphertexts[target], staged[target] = result.stdout, candidate
        if originals[DB] is None:
            selection["resources"].append(RESOURCE)
            candidate = staged[DB].parent / "kustomization.yaml"
            candidate.write_text(yaml.safe_dump(selection, sort_keys=False))
            staged[KUSTOMIZATION] = candidate
            ciphertexts[KUSTOMIZATION] = candidate.read_bytes()
        for target, original in originals.items():
            path = root / target
            current = path.read_bytes() if path.exists() else None
            if path.is_symlink() or current != original:
                raise SecretWriteError(
                    "news files changed during encryption; no replacement performed"
                )
        installed = []
        try:
            for target, candidate in staged.items():
                replace(candidate, root / target)
                installed.append(target)
        except OSError:
            for target in reversed(installed):
                path = root / target
                if path.is_symlink() or path.read_bytes() != ciphertexts[target]:
                    raise SecretWriteError(
                        "news files changed during rollback; operator review required"
                    ) from None
                if originals[target] is None:
                    path.unlink()
                else:
                    rollback = staged[target].parent / "rollback"
                    rollback.touch(mode=0o600)
                    rollback.write_bytes(originals[target])
                    replace(rollback, path)
            raise SecretWriteError("ciphertext replacement failed; prior files restored") from None


def main():
    try:
        write_secrets(Path(__file__).resolve().parents[2], os.environ)
    except (SecretWriteError, OSError):
        print(
            "News Secrets were not installed. Check intent, inputs and existing pair; values withheld.",
            file=sys.stderr,
        )
        return 1
    print("Wrote encrypted news database and FreshRSS bootstrap Secrets. Flux remains suspended.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
