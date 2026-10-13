"""One-shot enrollment of the suspended Career Ops HTTPS Flux source.

The authenticated browser producer streams its one-time creation receipt into
an owner-only FIFO. Only SOPS ciphertext is installed. This is not a credential
store, and never retrieves existing tokens, revokes tokens, or activates Flux.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import select
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

import yaml

ORIGIN = "https://forgejo.infra.supermorphic.com"
REPOSITORY = "supermorphic/career-ops"
TARGET = Path("kubernetes/apps/applications/career-ops/connection/career-ops-source.sops.yaml")
SELECTION = TARGET.parent / "kustomization.yaml"
RESOURCE = "./" + TARGET.name
CONFIRMATION = "enroll:career-ops:flux-source"


class EnrollmentError(RuntimeError):
    """A credential-free message safe to display."""


def load_yaml(content):
    try:
        document = yaml.safe_load(content)
    except yaml.YAMLError:
        raise EnrollmentError("Invalid enrollment YAML; details withheld") from None
    if not isinstance(document, dict):
        raise EnrollmentError("Enrollment YAML must be a mapping")
    return document


def safe_path(root, relative):
    path = root / relative
    if path.is_symlink() or path.resolve() != path:
        raise EnrollmentError("Enrollment paths must not contain symlinks")
    return path


def preflight(root):
    target, selection = safe_path(root, TARGET), safe_path(root, SELECTION)
    if target.exists():
        raise EnrollmentError("Source ciphertext already exists; bootstrap cannot replace it")
    original = selection.read_bytes()
    document = load_yaml(original)
    resources = document.get("resources")
    if not isinstance(resources, list) or not all(isinstance(item, str) for item in resources):
        raise EnrollmentError("Invalid connection resource selection")
    if any(Path(os.path.normpath(TARGET.parent / item)) == TARGET for item in resources):
        raise EnrollmentError("Source Secret is already selected")
    for name in ("gitrepository.yaml", "application-kustomization.yaml"):
        manifest = load_yaml(safe_path(root, TARGET.parent / name).read_bytes())
        if manifest.get("spec", {}).get("suspend") is not True:
            raise EnrollmentError("Both the Git source and application must remain suspended")
        spec = manifest["spec"]
        if name == "gitrepository.yaml":
            valid = (
                manifest.get("metadata") == {"name": "career-ops", "namespace": "career-ops"}
                and spec.get("url") == ORIGIN + "/" + REPOSITORY + ".git"
                and spec.get("ref") == {"branch": "main"}
                and spec.get("secretRef") == {"name": "career-ops-source"}
            )
        else:
            valid = (
                manifest.get("metadata") == {"name": "career-ops-apps", "namespace": "career-ops"}
                and spec.get("path") == "./deploy/"
                and spec.get("targetNamespace") == "career-ops"
                and spec.get("sourceRef") == {"kind": "GitRepository", "name": "career-ops"}
                and spec.get("serviceAccountName") == "career-ops-reconciler"
                and not any(key in spec for key in ("decryption", "postBuild"))
            )
        if not valid:
            raise EnrollmentError(
                "Source and application bindings differ from the enrollment contract"
            )
    policy_bytes = safe_path(root, Path(".sops.yaml")).read_bytes()
    rules = load_yaml(policy_bytes).get("creation_rules", [])
    matches = []
    for rule in rules:
        try:
            if re.search(rule.get("path_regex", "(?!)"), TARGET.as_posix()):
                matches.append(rule)
        except (AttributeError, TypeError, re.error):
            raise EnrollmentError("Invalid SOPS creation rule") from None
    if (
        len(matches) != 1
        or not isinstance(matches[0].get("age"), str)
        or not matches[0]["age"].startswith("age1")
        or matches[0].get("encrypted_regex") != "^(data|stringData)$"
    ):
        raise EnrollmentError("Source must select one public-age SOPS rule for Secret data")
    return original, document, policy_bytes, matches[0]["age"]


def validate_receipt(receipt, expected_name):
    if not isinstance(receipt, dict) or set(receipt) != {
        "origin",
        "username",
        "password",
        "token",
    }:
        raise EnrollmentError("Missing or invalid browser creation receipt")
    token = receipt["token"]
    if (
        receipt["origin"] != ORIGIN
        or not isinstance(receipt["username"], str)
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,39}", receipt["username"])
        or not isinstance(receipt["password"], str)
        or not re.fullmatch(r"[a-f0-9]{40}", receipt["password"])
        or not isinstance(token, dict)
        or set(token) != {"id", "name", "scopes", "repositories"}
        or type(token["id"]) is not int
        or token["id"] <= 0
        or token["name"] != expected_name
        or not re.fullmatch(r"career-ops-flux-[a-z0-9-]{1,64}", expected_name)
        or token["scopes"] != ["read:repository"]
        or token["repositories"] != [REPOSITORY]
    ):
        raise EnrollmentError("Creation receipt does not match the read-only source contract")


def validate_ciphertext(content, recipient, receipt):
    document = load_yaml(content)
    data, sops = document.get("stringData"), document.get("sops")
    if (
        set(document) != {"apiVersion", "kind", "metadata", "type", "stringData", "sops"}
        or document["apiVersion"] != "v1"
        or document["kind"] != "Secret"
        or document["type"] != "Opaque"
        or document["metadata"] != {"name": "career-ops-source", "namespace": "career-ops"}
        or not isinstance(data, dict)
        or set(data) != {"username", "password"}
        or not all(isinstance(v, str) and v.startswith("ENC[AES256_GCM,") for v in data.values())
        or not isinstance(sops, dict)
        or sops.get("age") is None
        or not isinstance(sops["age"], list)
        or [a.get("recipient") for a in sops["age"] if isinstance(a, dict)] != [recipient]
        or sops.get("encrypted_regex") != "^(data|stringData)$"
        or not isinstance(sops.get("mac"), str)
        or not sops["mac"].startswith("ENC[AES256_GCM,")
        or any(receipt[key].encode() in content for key in ("username", "password"))
    ):
        raise EnrollmentError("Encrypted source does not match the ciphertext contract")


def install(root, receipt, expected_name, confirmation, *, runner=subprocess.run):
    if confirmation != CONFIRMATION:
        raise EnrollmentError("The exact enrollment confirmation is required")
    original, document, policy_bytes, recipient = preflight(root)
    validate_receipt(receipt, expected_name)
    plaintext = yaml.safe_dump(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "type": "Opaque",
            "metadata": {"name": "career-ops-source", "namespace": "career-ops"},
            "stringData": {key: receipt[key] for key in ("username", "password")},
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
    validate_ciphertext(result.stdout, recipient, receipt)
    document["resources"].append(RESOURCE)
    selection_bytes = yaml.safe_dump(document, sort_keys=False).encode()
    with tempfile.TemporaryDirectory(
        prefix=".source-enrollment-", dir=root / TARGET.parent
    ) as staging:
        candidate = Path(staging) / TARGET.name
        candidate.write_bytes(result.stdout)
        candidate.chmod(0o600)
        selected = Path(staging) / SELECTION.name
        selected.write_bytes(selection_bytes)
        selected.chmod(0o600)
        # Repeat all live filesystem preconditions immediately before installation.
        fresh, _, policy, _ = preflight(root)
        if fresh != original or policy != policy_bytes:
            raise EnrollmentError("Enrollment inputs changed; ciphertext was not selected")
        target = root / TARGET
        # link is exclusive: never overwrite a concurrently created credential.
        os.link(candidate, target)
        try:
            os.replace(selected, root / SELECTION)
        except OSError:
            target.unlink()
            raise EnrollmentError("Selection failed; source ciphertext was rolled back") from None
    return {
        "origin": ORIGIN,
        "username": receipt["username"],
        "token": receipt["token"],
        "ciphertext_sha256": hashlib.sha256(result.stdout).hexdigest(),
        "source_suspended": True,
        "application_suspended": True,
    }


def read_fifo(path, *, timeout):
    info = path.lstat()
    if (
        not stat.S_ISFIFO(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise EnrollmentError("Receipt input must be an owner-only FIFO")
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise EnrollmentError("Receipt FIFO changed")
        deadline, chunks, received = time.monotonic() + timeout, [], 0
        while time.monotonic() < deadline:
            if not select.select([descriptor], [], [], min(0.1, timeout))[0]:
                continue
            chunk = os.read(descriptor, 16385)
            if chunk:
                chunks.append(chunk)
                received += len(chunk)
                if received > 16384:
                    raise EnrollmentError("Receipt exceeds the size limit")
            elif received:
                try:
                    return json.loads(b"".join(chunks))
                except (ValueError, UnicodeError):
                    raise EnrollmentError("Invalid receipt JSON; details withheld") from None
            else:
                time.sleep(min(0.01, timeout))
        raise EnrollmentError("Receipt delivery timed out; no credential was installed")
    finally:
        os.close(descriptor)
        current = path.lstat() if path.exists() else None
        if current and (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino):
            path.unlink()


@contextmanager
def enrollment_lock(private):
    descriptor = os.open(
        private / "enrollment.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600
    )
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            raise EnrollmentError("Enrollment lock must be an owner-only regular file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise EnrollmentError("Another source enrollment receiver is already active") from None
        yield
    finally:
        os.close(descriptor)


def enrollment_name(private, generated, resume):
    name = resume or generated
    if not re.fullmatch(r"career-ops-flux-[a-z0-9-]{1,64}", name):
        raise EnrollmentError("Invalid enrollment name")
    intent = private / (name + ".pending.json")
    expected = {"token_name": name, "origin": ORIGIN, "repository": REPOSITORY}
    if resume:
        if intent.is_symlink() or not intent.is_file():
            raise EnrollmentError("Resume requires the original private creation intent")
        try:
            actual = json.loads(intent.read_bytes())
        except (ValueError, UnicodeError):
            raise EnrollmentError("Invalid creation intent; details withheld") from None
        if actual != expected:
            raise EnrollmentError("Resume creation intent differs from the source contract")
    else:
        with intent.open("x") as stream:
            json.dump(expected, stream)
        intent.chmod(0o600)
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("discover", "receive"))
    parser.add_argument("--confirm", default="")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument(
        "--resume", default="", help="redeliver the original named browser receipt; never mint"
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    try:
        if args.action == "discover":
            target = safe_path(root, TARGET)
            print(
                json.dumps(
                    {
                        "origin": ORIGIN,
                        "repository": REPOSITORY,
                        "ciphertext_present": target.exists(),
                        "next_action": "review rotation" if target.exists() else "receive",
                        "confirmation": CONFIRMATION,
                    }
                )
            )
            return 0
        if args.confirm != CONFIRMATION or not 1 <= args.timeout <= 1800:
            raise EnrollmentError(
                "Use the exact confirmation and a timeout from 1 to 1800 seconds"
            )
        preflight(root)
        private = safe_path(root, Path(".tmp/issue-593/source-enrollment"))
        private.mkdir(parents=True, exist_ok=True, mode=0o700)
        if private.stat().st_uid != os.getuid() or stat.S_IMODE(private.stat().st_mode) != 0o700:
            raise EnrollmentError("Source enrollment directory must be owner-only")
        with (
            enrollment_lock(private),
            tempfile.TemporaryDirectory(prefix="receive-", dir=private) as session,
        ):
            preflight(root)
            directory = Path(session)
            token_name = "career-ops-flux-" + directory.name.removeprefix("receive-").replace(
                "_", "-"
            )
            token_name = enrollment_name(private, token_name, args.resume)
            fifo = directory / "receipt.fifo"
            os.mkfifo(fifo, 0o600)
            expression = directory / "browser-expression.js"
            producer = (root / "scripts/repository/career_ops_source_browser.js").read_text()
            expression.write_text(
                "() => ("
                + producer
                + ")("
                + json.dumps(
                    {
                        "origin": ORIGIN,
                        "repository": REPOSITORY,
                        "tokenName": token_name,
                        "confirmation": CONFIRMATION,
                        "resumeOnly": bool(args.resume),
                    }
                )
                + ")"
            )
            expression.chmod(0o600)
            print(
                json.dumps(
                    {
                        "status": "waiting-for-authenticated-browser",
                        "fifo": str(fifo),
                        "browser_expression": str(expression),
                        "token_name": token_name,
                    }
                ),
                flush=True,
            )
            receipt = read_fifo(fifo, timeout=args.timeout)
            result = install(root, receipt, token_name, args.confirm)
            receipt_path = private / (token_name + ".json")
            with receipt_path.open("x") as stream:
                json.dump(result, stream, indent=2)
            receipt_path.chmod(0o600)
            (private / (token_name + ".pending.json")).unlink()
            print(
                json.dumps(
                    {
                        "status": "ciphertext-installed",
                        "receipt": str(receipt_path),
                        "target": TARGET.as_posix(),
                        "activation": "suspended",
                    }
                )
            )
        return 0
    except EnrollmentError as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        print(
            "Source enrollment filesystem operation failed; details withheld. "
            "Review ciphertext state before retrying.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
