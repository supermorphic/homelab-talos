"""Operator-only ciphertext writers. Plaintext passes only through process memory/stdin."""

import base64
import os
import secrets as random
import stat
import subprocess
import sys
from pathlib import Path

from .configuration import SafeError, canonical_json

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "openbao-recovery.age"
SEAL = ROOT / "kubernetes/apps/security/openbao/app/openbao-seal.sops.yaml"


def _run(args, payload=None):
    try:
        result = subprocess.run(
            args,
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=True,
        )
        return result.stdout
    except (OSError, subprocess.SubprocessError):
        raise SafeError("invalid-source") from None


def validate_recipient(recipient: str) -> None:
    if not isinstance(recipient, str) or not recipient.startswith("age1") or len(recipient) != 62:
        raise SafeError("invalid-source")
    _run(["age", "--encrypt", "--recipient", recipient], b"public-recipient-preflight")


def directory_fd(directory: Path) -> int:
    """Walk with O_NOFOLLOW, rejecting aliases and repository-contained destinations."""
    if not directory.is_absolute() or ".." in directory.parts or directory.resolve() != directory:
        raise SafeError("invalid-source")
    roots = [ROOT]
    output = _run(["git", "-C", str(ROOT), "worktree", "list", "--porcelain"]).decode()
    roots.extend(
        Path(line[9:]).resolve() for line in output.splitlines() if line.startswith("worktree ")
    )
    if any(directory == root or root in directory.parents for root in roots):
        raise SafeError("invalid-source")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in directory.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise SafeError("invalid-source")
        return fd
    except (OSError, SafeError):
        os.close(fd)
        raise SafeError("invalid-source") from None


def _install(fd: int, name: str, ciphertext: bytes) -> None:
    temporary = ".openbao-" + random.token_hex(16)
    out = None
    try:
        out = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd
        )
        with os.fdopen(out, "wb") as stream:
            out = None
            stream.write(ciphertext)
            stream.flush()
            os.fsync(stream.fileno())
        # link is an atomic exclusive installation: unlike rename it cannot overwrite.
        os.link(temporary, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
        os.fsync(fd)
    except OSError:
        raise SafeError("invalid-response") from None
    finally:
        if out is not None:
            os.close(out)
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass


def preflight_recovery(directory: Path, recipient: str) -> None:
    validate_recipient(recipient)
    fd = directory_fd(directory)
    probe = ".preflight-" + random.token_hex(16)
    try:
        try:
            os.stat(BUNDLE, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise SafeError("invalid-source")
        _install(fd, probe, _run(["age", "--encrypt", "--recipient", recipient], b"preflight"))
        os.unlink(probe, dir_fd=fd)
        os.fsync(fd)
    except OSError:
        raise SafeError("invalid-response") from None
    finally:
        os.close(fd)


def write_recovery(directory: Path, recipient: str, payload: bytes) -> Path:
    validate_recipient(recipient)
    fd = directory_fd(directory)
    try:
        ciphertext = _run(["age", "--encrypt", "--recipient", recipient], payload)
        if not ciphertext.startswith(b"age-encryption.org/v1\n"):
            raise SafeError("invalid-response")
        _install(fd, BUNDLE, ciphertext)
        return directory / BUNDLE
    finally:
        os.close(fd)


def write_seal(directory: Path, recipient: str) -> Path:
    """Called only after the existing operator identity/recipient validation recipe."""
    if SEAL.exists() or SEAL.is_symlink():
        raise SafeError("invalid-source")
    preflight_recovery(directory, recipient)
    key = random.token_bytes(32)
    payload = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": "openbao-seal", "namespace": "openbao"},
        "type": "Opaque",
        "data": {"key": base64.b64encode(key).decode()},
    }
    ciphertext = _run(
        [
            "sops",
            "--encrypt",
            "--input-type",
            "json",
            "--output-type",
            "yaml",
            "--filename-override",
            str(SEAL.relative_to(ROOT)),
            "/dev/stdin",
        ],
        canonical_json(payload),
    )
    import yaml

    document = yaml.safe_load(ciphertext)
    if (
        {entry["recipient"] for entry in document["sops"]["age"]} != {recipient}
        or not document["data"]["key"].startswith("ENC[AES256_GCM,")
        or payload["data"]["key"].encode() in ciphertext
    ):
        raise SafeError("invalid-response")
    retained = write_recovery(
        directory,
        recipient,
        canonical_json(
            {"seal_key_id": "openbao-static-seal-v1", "seal_key_base64": payload["data"]["key"]}
        ),
    )
    fd = os.open(SEAL.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _install(fd, SEAL.name, ciphertext)
    finally:
        os.close(fd)
    return retained


def main():
    try:
        recipient = (
            _run(["yq", "-r", ".creation_rules[1].age", str(ROOT / ".sops.yaml")]).decode().strip()
        )
        if os.environ.get("OPENBAO_SECRETS_CONFIRM") != "write:openbao:openbao-seal:sops":
            raise SafeError("invalid-source")
        directory = Path(os.environ.get("OPENBAO_RECOVERY_DIRECTORY", ""))
        write_seal(directory, recipient)
        print(
            "OpenBao seal ciphertext and encrypted recovery retained. Add the Secret to the app kustomization before publication."
        )
        return 0
    except (SafeError, OSError, KeyError, TypeError, ValueError):
        print(
            "OpenBao secret creation refused or incomplete; preserve retained ciphertext.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
