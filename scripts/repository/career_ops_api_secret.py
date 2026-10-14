"""Stage the qualification API principal without activating a caller or coordinator.

The bearer stays in an owner-only local file. Only its SHA-256 enters the
public-age SOPS encryption input. This bootstrap never replaces a Secret,
changes Flux selection, rotates credentials, or enables production admission.
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
PRINCIPAL = "career-ops-qualification"


class EnrollmentError(RuntimeError):
    """Credential-free failure safe to display."""


def preflight(root):
    target, policy = root / TARGET, root / ".sops.yaml"
    if target.resolve() != target or policy.resolve() != policy or target.exists():
        raise EnrollmentError("Bootstrap cannot replace ciphertext or follow symlinks")
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


def read_token(path):
    if not path.is_absolute() or path.resolve() != path:
        raise EnrollmentError("Token path must be absolute and contain no symlinks")
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700:
        raise EnrollmentError("Token directory must be owned by the current user with mode 0700")
    try:
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
            raise EnrollmentError("Invalid qualification token format")
    return content.strip().decode()


def stage(root, token_file, confirmation, *, runner=subprocess.run):
    if confirmation != CONFIRMATION:
        raise EnrollmentError("Exact qualification enrollment confirmation required")
    policy, recipient = preflight(root)
    token = read_token(token_file)
    principals = {
        "schemaVersion": 1,
        "principals": [
            {"principalId": PRINCIPAL, "tokenSha256": [hashlib.sha256(token.encode()).hexdigest()]}
        ],
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
            or token.encode() in result.stdout
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
        fresh_policy, _ = preflight(root)
        if fresh_policy != policy or read_token(token_file) != token:
            raise EnrollmentError("Enrollment inputs changed; ciphertext was not installed")
        try:
            os.link(candidate, root / TARGET)
        except FileExistsError:
            raise EnrollmentError(
                "Another writer installed ciphertext; nothing replaced"
            ) from None
    return {
        "principal": PRINCIPAL,
        "target": str(TARGET),
        "token_file": str(token_file),
        "ciphertext_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "activation": "unchanged",
        "selected": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--token-file",
        required=True,
        type=Path,
        help="owner-only file in an existing 0700 directory; generated once, retained for delivery retries",
    )
    parser.add_argument("--confirm", required=True)
    args = parser.parse_args()
    try:
        print(
            json.dumps(stage(Path(__file__).resolve().parents[2], args.token_file, args.confirm))
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
