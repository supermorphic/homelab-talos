"""Stage a CV database Secret from its ready protected application profile.

Uses public-age SOPS encryption only. Does not activate or rotate a login,
select the ciphertext in Flux, or change admission and recovery state.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

import psycopg
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from automation_data_access import (
    assert_profile_unchanged,
    revalidate_connection_profile,
    select_connection_profile,
)
from automation_data_client import (
    PrivateFileError,
    PrivateTunnelUnavailable,
    authenticate_candidate,
    private_database_tunnel,
    validate_service_profile,
)

TARGET = Path("kubernetes/apps/applications/career-ops/connection/cv-render-database.sops.yaml")
CONFIRMATION = "stage:career-ops:cv-render-database"
REPLACE_CONFIRMATION = "replace:career-ops:cv-render-database"
ROLE = (
    "app_"
    + hashlib.md5(b"career_ops:cv_render", usedforsecurity=False).hexdigest()
    + "_integration"
)
EXPECTED = {
    "domain": "career_ops",
    "application": "cv_render",
    "database": "career_ops",
    "schema": "cv_render",
    "role": ROLE,
}


class EnrollmentError(RuntimeError):
    """A credential-free error safe to display."""


def binding_contract(binding):
    if (
        not isinstance(binding, dict)
        or set(binding) != set(EXPECTED) | {"credentialGeneration"}
        or any(binding.get(key) != value for key, value in EXPECTED.items())
        or type(binding.get("credentialGeneration")) is not int
        or binding["credentialGeneration"] < 1
    ):
        raise EnrollmentError("The CV runtime binding is not valid")


@contextmanager
def runtime_credential():
    """Keep the existing scoped tunnel and fresh profile checks around Secret staging."""
    if any(
        key in os.environ for key in ("AUTOMATION_DATA_SERVICE_FILE", "AUTOMATION_DATA_SERVICE")
    ):
        raise EnrollmentError(
            "Runtime enrollment requires the automatically discovered CV profile"
        )
    selected = select_connection_profile("career_ops", "application/cv_render")
    if not selected.automatic or selected.status != "ready" or not selected.binding:
        raise EnrollmentError("The CV application profile is not ready")
    binding = {key: selected.binding.get(key) for key in (*EXPECTED, "credentialGeneration")}
    binding_contract(binding)
    revalidate_connection_profile("career_ops", "application/cv_render", selected)
    if selected.service != f"automation_data_career_ops_{ROLE}" or selected.local_port is None:
        raise EnrollmentError("The CV application service is not valid")
    profile = validate_service_profile(
        selected.service_file, selected.service, "career_ops", ROLE, selected.local_port
    )
    expected_passfile = selected.service_file.parent / (
        f"generation-{binding['credentialGeneration']}/credential.pgpass"
    )
    if profile["passfile"] != str(expected_passfile):
        raise EnrollmentError("The CV application password generation is not valid")
    assert_profile_unchanged(selected)
    configured = os.environ.get("AUTOMATION_DATA_KUBECONFIG")
    kubeconfig = Path(configured) if configured else None
    with private_database_tunnel(kubeconfig, selected.local_port) as port:
        authenticate_candidate(port, "career_ops", ROLE, profile["password"])
        yield binding, profile["password"]
        revalidate_connection_profile("career_ops", "application/cv_render", selected)
        assert_profile_unchanged(selected)


def preflight(root, replace_sha256=None):
    target = root / TARGET
    policy = root / ".sops.yaml"
    if target.resolve() != target or policy.resolve() != policy:
        raise EnrollmentError("Ciphertext staging cannot use symlinks")
    if replace_sha256 is None:
        if target.exists():
            raise EnrollmentError("Initial ciphertext staging cannot replace existing files")
    else:
        try:
            info = target.lstat()
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid()
                or info.st_nlink != 1
                or info.st_size > 1048576
                or hashlib.sha256(target.read_bytes()).hexdigest() != replace_sha256
            ):
                raise EnrollmentError("Existing ciphertext does not match the reviewed replacement")
        except OSError:
            raise EnrollmentError("Reviewed ciphertext replacement target is unavailable") from None
    content = policy.read_bytes()
    rules = yaml.safe_load(content).get("creation_rules", [])
    matching = [
        rule for rule in rules if re.search(rule.get("path_regex", "(?!)"), TARGET.as_posix())
    ]
    if (
        len(matching) != 1
        or not isinstance(matching[0].get("age"), str)
        or not re.fullmatch(r"age1[a-z0-9]+", matching[0]["age"])
        or matching[0].get("encrypted_regex") != "^(data|stringData)$"
    ):
        raise EnrollmentError("Runtime ciphertext requires one public-age SOPS rule")
    return content, matching[0]["age"]


def validate_ciphertext(content, recipient, password):
    document = yaml.safe_load(content)
    if not isinstance(document, dict):
        raise EnrollmentError("SOPS did not return the expected encrypted Secret")
    data, sops = document.get("stringData"), document.get("sops")
    if (
        set(document) != {"apiVersion", "kind", "type", "metadata", "stringData", "sops"}
        or document.get("apiVersion") != "v1"
        or document.get("kind") != "Secret"
        or document.get("type") != "Opaque"
        or document.get("metadata") != {"name": "cv-render-database", "namespace": "career-ops"}
        or not isinstance(data, dict)
        or set(data) != {"username", "password", "binding.json"}
        or not all(
            isinstance(value, str) and value.startswith("ENC[AES256_GCM,")
            for value in data.values()
        )
        or not isinstance(sops, dict)
        or not isinstance(sops.get("age"), list)
        or [item.get("recipient") for item in sops["age"] if isinstance(item, dict)] != [recipient]
        or sops.get("encrypted_regex") != "^(data|stringData)$"
        or not isinstance(sops.get("mac"), str)
        or not sops["mac"].startswith("ENC[AES256_GCM,")
        or password.encode() in content
        or ROLE.encode() in content
    ):
        raise EnrollmentError("SOPS did not return the expected encrypted Secret")


def install(
    root, confirmation, *, replace_sha256=None, expected_generation=None,
    credential=runtime_credential, runner=subprocess.run,
):
    replacing = replace_sha256 is not None or expected_generation is not None
    if replacing and (
        not isinstance(replace_sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", replace_sha256) is None
        or type(expected_generation) is not int
        or expected_generation < 2
    ):
        raise EnrollmentError("Replacement requires a reviewed checksum and new generation")
    if confirmation != (REPLACE_CONFIRMATION if replacing else CONFIRMATION):
        raise EnrollmentError("The exact ciphertext staging confirmation is required")
    policy, recipient = preflight(root, replace_sha256)
    with credential() as (binding, password):
        binding_contract(binding)
        if replacing and binding["credentialGeneration"] != expected_generation:
            raise EnrollmentError("The ready credential does not match the replacement generation")
        if not isinstance(password, str) or not password or any(c.isspace() for c in password):
            raise EnrollmentError("The CV application password is not valid")
        plaintext = yaml.safe_dump(
            {
                "apiVersion": "v1",
                "kind": "Secret",
                "type": "Opaque",
                "metadata": {"name": "cv-render-database", "namespace": "career-ops"},
                "stringData": {
                    "username": ROLE,
                    "password": password,
                    "binding.json": json.dumps(binding, sort_keys=True),
                },
            }
        ).encode()
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
                    TARGET.as_posix(),
                    "/dev/stdin",
                ],
                cwd=root,
                input=plaintext,
                capture_output=True,
                check=False,
                timeout=60,
                env={k: v for k, v in os.environ.items() if not k.startswith("SOPS_AGE_")},
            )
        except (OSError, subprocess.SubprocessError):
            raise EnrollmentError("SOPS encryption could not complete; details withheld") from None
        if result.returncode or not result.stdout:
            raise EnrollmentError("SOPS encryption failed; tool output withheld")
        validate_ciphertext(result.stdout, recipient, password)
        generation = binding["credentialGeneration"]
    # The credential context repeats remote readiness and local generation checks
    # before this exclusive installation; only ciphertext leaves that context.
    if preflight(root, replace_sha256) != (policy, recipient):
        raise EnrollmentError("SOPS policy changed during staging")
    with tempfile.TemporaryDirectory(prefix=".cv-runtime-", dir=root / TARGET.parent) as temporary:
        candidate = Path(temporary) / TARGET.name
        candidate.write_bytes(result.stdout)
        candidate.chmod(0o600)
        try:
            if replacing:
                # Repeat guards immediately before replacing only the reviewed ciphertext.
                if preflight(root, replace_sha256) != (policy, recipient):
                    raise EnrollmentError("SOPS policy changed during staging")
                os.replace(candidate, root / TARGET)
            else:
                os.link(candidate, root / TARGET)
        except OSError:
            raise EnrollmentError(
                "Ciphertext was not installed; existing files were preserved"
            ) from None
    receipt = {
        "status": "ciphertext-staged",
        "credentialGeneration": generation,
        "ciphertext_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "path": TARGET.as_posix(),
    }
    if replacing:
        receipt["replaced_ciphertext_sha256"] = replace_sha256
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--confirm", required=True, choices=[CONFIRMATION, REPLACE_CONFIRMATION])
    parser.add_argument("--replace-sha256", help="Replace only existing ciphertext with this reviewed SHA256")
    parser.add_argument("--expected-generation", type=int, help="Require this ready new credential generation (at least 2)")
    args = parser.parse_args()
    try:
        print(
            json.dumps(install(
                Path(__file__).resolve().parents[2], args.confirm,
                replace_sha256=args.replace_sha256, expected_generation=args.expected_generation,
            ), sort_keys=True)
        )
        return 0
    except (
        EnrollmentError,
        PrivateFileError,
        OSError,
        ValueError,
        TypeError,
        AttributeError,
        KeyError,
        yaml.YAMLError,
        re.error,
        PrivateTunnelUnavailable,
        psycopg.Error,
    ):
        print(
            "CV runtime ciphertext staging failed; credential and tool details withheld",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
