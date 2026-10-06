"""Encrypt operator-supplied news bootstrap values using public age recipients only."""

from __future__ import annotations

import fcntl
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
SELECTIONS = {secret.parent / "kustomization.yaml": secret for secret in (DB, APP)}
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
    """Serialize operators before reading, encrypting, and installing the pair."""
    root = root.resolve()
    lock_path = root / ".tmp/news/secrets.lock"
    if lock_path.parent.resolve() != root / ".tmp/news":
        raise SecretWriteError("the news lock directory must remain inside this worktree")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    except OSError:
        raise SecretWriteError("the news Secret writer lock is unavailable") from None
    with os.fdopen(descriptor, "rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _write_secrets_locked(root, environment, runner=runner, replace=replace)


def _write_secrets_locked(root, environment, *, runner, replace):
    """Stage encrypted artifacts, then replace each atomically with rollback."""
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
    original_policy = (root / ".sops.yaml").read_bytes()
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
    selections = {}
    for target, secret in SELECTIONS.items():
        selection_path = root / target
        if selection_path.is_symlink():
            raise SecretWriteError("news Kustomizations must not be symlinks")
        original_selection = selection_path.read_bytes()
        selection = load(original_selection)
        resources = selection.get("resources")
        if not isinstance(resources, list) or not all(isinstance(r, str) for r in resources):
            raise SecretWriteError("news resource selection is invalid")
        resource = "./" + secret.name
        equivalent = [r for r in resources if Path(os.path.normpath(secret.parent / r)) == secret]
        legacy_app_selection = secret == APP and originals[APP] is not None and not equivalent
        if (
            equivalent != ([resource] if originals[secret] is not None else [])
            and not legacy_app_selection
        ):
            raise SecretWriteError("existing news Secret and resource selection are inconsistent")
        originals[target] = original_selection
        selections[target] = selection

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
        for target, secret in SELECTIONS.items():
            if "./" + secret.name not in selections[target]["resources"]:
                selection = selections[target]
                selection["resources"].append("./" + secret.name)
                candidate = staged[secret].parent / "kustomization.yaml"
                candidate.write_text(yaml.safe_dump(selection, sort_keys=False))
                staged[target] = candidate
                ciphertexts[target] = candidate.read_bytes()
        for target, original in originals.items():
            path = root / target
            current = path.read_bytes() if path.exists() else None
            if path.is_symlink() or current != original:
                raise SecretWriteError(
                    "news files changed during encryption; no replacement performed"
                )
        if (root / ".sops.yaml").read_bytes() != original_policy:
            raise SecretWriteError(
                "the SOPS policy changed during encryption; no replacement performed"
            )
        installed = []
        try:
            for target, candidate in staged.items():
                path = root / target
                current = path.read_bytes() if path.exists() else None
                if path.is_symlink() or current != originals[target]:
                    raise SecretWriteError("news files changed during installation")
                replace(candidate, path)
                installed.append(target)
        except (OSError, SecretWriteError) as install_error:
            try:
                for target in reversed(installed):
                    path = root / target
                    if path.is_symlink() or path.read_bytes() != ciphertexts[target]:
                        raise SecretWriteError("news files changed during rollback")
                    if originals[target] is None:
                        path.unlink()
                    else:
                        rollback = staged[target].parent / "rollback"
                        rollback.touch(mode=0o600)
                        rollback.write_bytes(originals[target])
                        replace(rollback, path)
            except (OSError, SecretWriteError):
                raise SecretWriteError(
                    "incomplete ciphertext rollback; operator review required"
                ) from None
            if isinstance(install_error, SecretWriteError):
                raise SecretWriteError(
                    "news files changed during installation; earlier replacements restored"
                ) from None
            raise SecretWriteError("ciphertext replacement failed; prior files restored") from None


def main():
    try:
        write_secrets(Path(__file__).resolve().parents[2], os.environ)
    except SecretWriteError as error:
        print(f"News Secret write stopped: {error}.", file=sys.stderr)
        return 1
    except OSError:
        print(
            "News file operation failed; operator review of the existing pair is required. Values withheld.",
            file=sys.stderr,
        )
        return 1
    print("Wrote encrypted news database and FreshRSS bootstrap Secrets. Flux remains suspended.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
