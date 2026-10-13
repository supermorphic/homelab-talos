"""Fixed synthetic data only; shared by the native fixture program.

The runner must mount a separately enrolled synthetic claim, run publication on
one node and a fresh reader on another, then perform the read-only check through
an actually read-only mount. Local execution cannot establish those conditions.
No network, token, Secret, application data, or cleanup authority is needed here.
"""

import errno
import hashlib
import json
import os
import sys
from pathlib import Path

BUNDLE = "boundary-synthetic-bundle"
PAYLOAD = b"homelab-application-boundary/synthetic/v1\n"


def publish(root):
    descriptor = os.open(
        root / BUNDLE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        remaining = memoryview(PAYLOAD)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError(errno.EIO, "synthetic write did not progress")
            remaining = remaining[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def verify_bundle(root):
    descriptor = os.open(root / BUNDLE, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        with os.fdopen(descriptor, "rb", closefd=False) as bundle:
            actual = bundle.read(len(PAYLOAD) + 1)
    finally:
        os.close(descriptor)
    if actual != PAYLOAD:
        raise ValueError("synthetic checksum mismatch")


def assert_read_only(root):
    probe = root / "boundary-synthetic-read-only-probe"
    try:
        descriptor = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as error:
        if error.errno == errno.EROFS:
            return
        # A permission error or an existing file is not a read-only mount.
        raise
    try:
        identity = os.fstat(descriptor)
        current = probe.stat(follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino):
            raise ValueError("synthetic probe ownership changed")
        probe.unlink()
    finally:
        os.close(descriptor)
    raise ValueError("synthetic mount permits writes")


def main(argv):
    if len(argv) != 2 or argv[0] not in {"publish", "read", "read-only"}:
        print("Usage: mount-probe.py <publish|read|read-only> <synthetic-mount>", file=sys.stderr)
        return 2
    mode, mount = argv
    try:
        root = Path(mount)
        if mode == "publish":
            publish(root)
        elif mode == "read":
            verify_bundle(root)
        else:
            assert_read_only(root)
    except (OSError, ValueError) as error:
        print(
            json.dumps({"result": "failed", "errno": getattr(error, "errno", None)}),
            file=sys.stderr,
        )
        return 1
    result = {
        "publish": "published-synthetic-bundle",
        "read": "verified-synthetic-bundle",
        "read-only": "verified-read-only-mount",
    }[mode]
    print(json.dumps({"result": result, "sha256": hashlib.sha256(PAYLOAD).hexdigest()}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
