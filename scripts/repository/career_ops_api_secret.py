"""Stage Career Ops API principals without activating a caller or coordinator.

Each bearer stays in an owner-only local file. Only its SHA-256 enters the
public-age SOPS encryption input. Bootstrap stages the qualification principal
and never replaces a Secret. Package enrollment replaces only reviewed
ciphertext: it keeps the existing qualification bearer and stages the package
operator and the composer, which may only render and register its own packages.
Neither changes Flux selection or enables admission.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

TARGET = Path("kubernetes/apps/applications/career-ops/connection/cv-api-auth.sops.yaml")
CONFIRMATION = "stage:career-ops:cv-api-auth"
REPLACE_CONFIRMATION = "replace:career-ops:cv-api-auth"
PRINCIPAL = "career-ops-qualification"
OPERATOR = "career-ops-operator"
OPERATOR_CAPABILITIES = ["packages:read", "packages:write", "render"]
COMPOSER = "career-ops-composer"
COMPOSER_CAPABILITIES = ["render", "packages:register"]


class EnrollmentError(RuntimeError):
    """Credential-free failure safe to display."""


def preflight(root, replace_sha256=None):
    target, policy = root / TARGET, root / ".sops.yaml"
    if target.resolve() != target or policy.resolve() != policy:
        raise EnrollmentError("API enrollment cannot follow symlinks")
    if replace_sha256 is None:
        if target.exists():
            raise EnrollmentError("Bootstrap cannot replace ciphertext")
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
    try:
        rules = yaml.safe_load(content)["creation_rules"]
        matches = [r for r in rules if re.search(r.get("path_regex", "(?!)"), TARGET.as_posix())]
        if (
            len(matches) != 1
            or not re.fullmatch(r"age1[a-z0-9]+", matches[0]["age"])
            or matches[0]["encrypted_regex"] != "^(data|stringData)$"
        ):
            raise ValueError()
    except (KeyError, TypeError, ValueError, yaml.YAMLError, re.error):
        raise EnrollmentError("API Secret requires one public-age SOPS rule") from None
    return content, matches[0]["age"]


def read_token(path, create=True):
    if not path.is_absolute() or path.resolve() != path:
        raise EnrollmentError("Token path must be absolute and contain no symlinks")
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700:
        raise EnrollmentError("Token directory must be owned by the current user with mode 0700")
    try:
        if not create:
            raise FileExistsError()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_urlsafe(32) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            raise EnrollmentError("Token must be an owner-only regular file")
        content = stream.read(128)
        if not re.fullmatch(rb"[A-Za-z0-9_-]{43}\n?", content):
            raise EnrollmentError("Invalid API token format")
    return content.strip().decode()


def stage(
    root, token_file, confirmation, *, operator_token_file=None, composer_token_file=None,
    replace_sha256=None, runner=subprocess.run,
):
    replacing = (
        operator_token_file is not None
        or composer_token_file is not None
        or replace_sha256 is not None
    )
    if replacing and (
        not isinstance(replace_sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", replace_sha256) is None
        or not isinstance(operator_token_file, Path)
        or not isinstance(composer_token_file, Path)
        or len({token_file, operator_token_file, composer_token_file}) != 3
    ):
        raise EnrollmentError(
            "Package enrollment requires a reviewed checksum, operator token and composer token"
        )
    if confirmation != (REPLACE_CONFIRMATION if replacing else CONFIRMATION):
        raise EnrollmentError("Exact API enrollment confirmation required")
    policy, recipient = preflight(root, replace_sha256)

    def inputs():
        # Replacement keeps the deployed qualification bearer; it never mints a new one.
        tokens = [read_token(token_file, create=not replacing)]
        if replacing:
            tokens.append(read_token(operator_token_file))
            tokens.append(read_token(composer_token_file))
            if len(set(tokens)) != len(tokens):
                raise EnrollmentError("API principals require distinct tokens")
        return tokens

    tokens = inputs()
    digests = [hashlib.sha256(token.encode()).hexdigest() for token in tokens]
    if replacing:
        principals = {
            "schemaVersion": 2,
            "principals": [
                {"principalId": PRINCIPAL, "tokenSha256": [digests[0]], "capabilities": ["render"]},
                {
                    "principalId": OPERATOR,
                    "tokenSha256": [digests[1]],
                    "capabilities": OPERATOR_CAPABILITIES,
                },
                {
                    "principalId": COMPOSER,
                    "tokenSha256": [digests[2]],
                    "capabilities": COMPOSER_CAPABILITIES,
                },
            ],
        }
    else:
        principals = {
            "schemaVersion": 1,
            "principals": [{"principalId": PRINCIPAL, "tokenSha256": [digests[0]]}],
        }
    document = {
        "apiVersion": "v1",
        "kind": "Secret",
        "type": "Opaque",
        "metadata": {"name": "cv-api-auth", "namespace": "career-ops"},
        "stringData": {"principals.json": json.dumps(principals, separators=(",", ":"))},
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
                TARGET.as_posix(),
                "/dev/stdin",
            ],
            cwd=root,
            input=yaml.safe_dump(document).encode(),
            capture_output=True,
            check=False,
            timeout=60,
            env={k: v for k, v in os.environ.items() if not k.startswith("SOPS_AGE_")},
        )
        encrypted = yaml.safe_load(result.stdout) if result.returncode == 0 else None
        if (
            not isinstance(encrypted, dict)
            or set(encrypted) != set(document) | {"sops"}
            or any(
                encrypted.get(k) != document[k] for k in ("apiVersion", "kind", "type", "metadata")
            )
            or set(encrypted.get("stringData", {})) != {"principals.json"}
            or not encrypted["stringData"]["principals.json"].startswith("ENC[AES256_GCM,")
            or [a["recipient"] for a in encrypted["sops"]["age"]] != [recipient]
            or encrypted["sops"]["encrypted_regex"] != "^(data|stringData)$"
            or not encrypted["sops"]["mac"].startswith("ENC[AES256_GCM,")
            or any(token.encode() in result.stdout for token in tokens)
        ):
            raise EnrollmentError("API Secret encryption did not satisfy the ciphertext contract")
    except (
        OSError,
        subprocess.SubprocessError,
        KeyError,
        TypeError,
        AttributeError,
        yaml.YAMLError,
    ):
        raise EnrollmentError("API Secret encryption failed; details withheld") from None
    with tempfile.TemporaryDirectory(
        prefix=".api-enrollment-", dir=root / TARGET.parent
    ) as directory:
        candidate = Path(directory) / TARGET.name
        candidate.write_bytes(result.stdout)
        candidate.chmod(0o600)
        fresh_policy, _ = preflight(root, replace_sha256)
        if fresh_policy != policy or inputs() != tokens:
            raise EnrollmentError("Enrollment inputs changed; ciphertext was not installed")
        try:
            if replacing:
                os.replace(candidate, root / TARGET)
            else:
                os.link(candidate, root / TARGET)
        except FileExistsError:
            raise EnrollmentError(
                "Another writer installed ciphertext; nothing replaced"
            ) from None
    receipt = {
        "principal": PRINCIPAL,
        "target": str(TARGET),
        "token_file": str(token_file),
        "ciphertext_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "activation": "unchanged",
        "selected": False,
    }
    if replacing:
        receipt |= {
            "operator_principal": OPERATOR,
            "operator_capabilities": OPERATOR_CAPABILITIES,
            "operator_token_file": str(operator_token_file),
            "composer_principal": COMPOSER,
            "composer_capabilities": COMPOSER_CAPABILITIES,
            "composer_token_file": str(composer_token_file),
            "replaced_ciphertext_sha256": replace_sha256,
        }
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--token-file",
        required=True,
        type=Path,
        help="owner-only file in an existing 0700 directory; generated once, retained for delivery retries",
    )
    parser.add_argument(
        "--operator-token-file",
        type=Path,
        help="package enrollment: owner-only operator token, generated once and retained",
    )
    parser.add_argument(
        "--composer-token-file",
        type=Path,
        help=(
            "package enrollment, required with --operator-token-file: owner-only composer token,"
            " generated once and retained"
        ),
    )
    parser.add_argument(
        "--replace-sha256", help="package enrollment: SHA-256 of the reviewed existing ciphertext"
    )
    parser.add_argument("--confirm", required=True)
    args = parser.parse_args()
    try:
        print(
            json.dumps(stage(
                Path(__file__).resolve().parents[2], args.token_file, args.confirm,
                operator_token_file=args.operator_token_file,
                composer_token_file=args.composer_token_file, replace_sha256=args.replace_sha256,
            ))
        )
        return 0
    except (EnrollmentError, OSError) as error:
        print(
            str(error)
            if isinstance(error, EnrollmentError)
            else "API enrollment filesystem error; details withheld",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
