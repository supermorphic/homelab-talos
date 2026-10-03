"""Attended fixture integrity and ordinary Mylar pod replacement acceptance.

MYLAR_ACCEPTANCE_FIXTURE names a private JSON file containing download_path,
library_path, and issue_id. Acquisition and client recheck remain attended.
The catalog wrapper owns the test Lease and disruption admission.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath

from resilience_support import (
    ScenarioFailure,
    atomic_write_json,
    install_interrupt_handlers,
    write_recovery,
)


def validate_fixture(value: object) -> dict:
    if not isinstance(value, dict) or set(value) != {"download_path", "library_path", "issue_id"}:
        raise ScenarioFailure("fixture must contain exactly the three documented fields")
    for field, root in (
        ("download_path", "/data/downloads/comics"),
        ("library_path", "/data/media/comics"),
    ):
        raw = value[field]
        if not isinstance(raw, str) or any(ord(c) < 32 for c in raw):
            raise ScenarioFailure("invalid fixture path")
        path = PurePosixPath(raw)
        if (
            str(path) != raw
            or ".." in path.parts
            or not path.is_relative_to(root)
            or path.suffix.lower() not in {".cbz", ".cbr"}
        ):
            raise ScenarioFailure("fixture path is outside its comic root or unsupported")
    if (
        not isinstance(value["issue_id"], str)
        or not value["issue_id"].isascii()
        or not value["issue_id"].isdigit()
    ):
        raise ScenarioFailure("fixture issue ID must be an ASCII numeric string")
    return value


# No config files, API keys, comic titles, filenames, or archive contents are
# returned. The content digest is compared in memory and never retained.
PROBE = r"""
import hashlib, json, pathlib, sqlite3, subprocess, sys, zipfile
try:
    f = json.loads(sys.stdin.read())
    paths = [pathlib.Path(f[k]) for k in ('download_path', 'library_path')]
    for p, root in zip(paths, ('/data/downloads/comics', '/data/media/comics')):
        if not p.is_file() or p.resolve(strict=True) != p or not p.is_relative_to(root):
            raise ValueError()
    a, b = [p.stat() for p in paths]
    if a.st_size <= 0 or (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino) or min(a.st_nlink, b.st_nlink) < 2:
        raise ValueError()
    with sqlite3.connect('file:/config/mylar/mylar.db?mode=ro', uri=True) as db:
        row = db.execute('SELECT Status, Location, ComicID FROM issues WHERE IssueID = ?', (f['issue_id'],)).fetchone()
        if not row or row[0] != 'Downloaded' or not row[1]:
            raise ValueError()
        comic = db.execute('SELECT ComicLocation FROM comics WHERE ComicID = ?', (row[2],)).fetchone()
        if not comic or pathlib.Path(comic[0]).resolve() != paths[1].parent or pathlib.Path(row[1]).name != paths[1].name:
            raise ValueError()
    image_extensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'}
    if zipfile.is_zipfile(paths[1]):
        with zipfile.ZipFile(paths[1]) as archive:
            if archive.testzip() is not None:
                raise ValueError()
            pages = sum(pathlib.PurePosixPath(n).suffix.lower() in image_extensions for n in archive.namelist())
    else:
        checked = subprocess.run(['unrar', 't', '-inul', str(paths[1])], capture_output=True, timeout=120)
        names = subprocess.run(['unrar', 'lb', str(paths[1])], capture_output=True, text=True, timeout=120)
        if checked.returncode != 0 or names.returncode != 0:
            raise ValueError()
        pages = sum(pathlib.PurePosixPath(n).suffix.lower() in image_extensions for n in names.stdout.splitlines())
    if pages == 0:
        raise ValueError()
    with paths[1].open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    print(json.dumps({'bytes': b.st_size, 'pages': pages, 'links': min(a.st_nlink, b.st_nlink), 'digest': digest}))
except Exception:
    print('Fixture integrity, archive, or Downloaded-record check failed.', file=sys.stderr)
    sys.exit(1)
"""


class Acceptance:
    def __init__(self, kubeconfig: str, fixture: dict, run_dir: Path):
        self.kubeconfig = kubeconfig
        self.base = ["kubectl", "--kubeconfig", kubeconfig]
        self.fixture = fixture
        self.run_dir = run_dir

    def call(self, *args: str, data: str | None = None, timeout: int = 180) -> str:
        result = subprocess.run(
            self.base + list(args),
            input=data,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        if result.returncode:
            raise ScenarioFailure(
                "scoped Kubernetes operation failed; no raw runtime output retained"
            )
        return result.stdout

    def resource(self, namespace: str, *args: str) -> dict:
        return json.loads(self.call("-n", namespace, *args, "-o", "json"))

    def pod(self) -> dict:
        items = self.resource("media", "get", "pods", "-l", "app.kubernetes.io/name=mylar3")[
            "items"
        ]
        if len(items) != 1 or items[0]["metadata"].get("deletionTimestamp"):
            raise ScenarioFailure("expected exactly one non-terminating Mylar pod")
        pod = items[0]
        if not any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in pod.get("status", {}).get("conditions", [])
        ):
            raise ScenarioFailure("Mylar pod is not Ready")
        return pod

    def probe(self, pod: dict) -> dict:
        return json.loads(
            self.call(
                "-n",
                "media",
                "exec",
                "-i",
                pod["metadata"]["name"],
                "-c",
                "app",
                "--",
                "python3",
                "-c",
                PROBE,
                data=json.dumps(self.fixture),
            )
        )

    def volume(self) -> str:
        pvc = self.resource("media", "get", "pvc", "mylar3")
        if (
            pvc.get("status", {}).get("phase") != "Bound"
            or pvc["spec"].get("storageClassName") != "longhorn"
        ):
            raise ScenarioFailure("Mylar config must be bound to Longhorn")
        return pvc["spec"]["volumeName"]

    def admit_deletion(self) -> None:
        # Reuse the wrapper's live guards after the potentially long archive probe.
        guard = """
set -euo pipefail
source scripts/lib/lease.sh
source scripts/lib/disruption-admission.sh
[[ -n "${HOMELAB_DISRUPTION_LEASE_HOLDER:-}" ]]
[[ ! -e "$2/diagnostics/lease-renewal-failed" ]]
[[ -z "${TEST_CAMPAIGN_LEASE_FAILURE_MARKER:-}" || ! -e "$TEST_CAMPAIGN_LEASE_FAILURE_MARKER" ]]
assert_established_disruption_admissible "$1"
verify_test_lease_holder "$1" "$HOMELAB_DISRUPTION_LEASE_HOLDER"
"""
        result = subprocess.run(
            ["bash", "-c", guard, "mylar3-admission", self.kubeconfig, str(self.run_dir)],
            cwd=Path(__file__).resolve().parents[3],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if result.returncode:
            raise ScenarioFailure(
                "current disruption admission or test Lease does not permit pod replacement"
            )

    def ready_after(self, old_uid: str, timeout: int = 360) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                pod = self.pod()
                if pod["metadata"]["uid"] != old_uid:
                    return pod
            except ScenarioFailure:
                pass
            time.sleep(2)
        raise ScenarioFailure("replacement Mylar pod did not become Ready within six minutes")

    def require_exec(self) -> None:
        if (
            self.call(
                "auth", "can-i", "create", "pods", "--subresource=exec", "-n", "media"
            ).strip()
            != "yes"
        ):
            raise ScenarioFailure(
                "selected identity lacks the required fixture inspection authority"
            )

    def verify_integrity(self) -> None:
        # Record preflight preserves observer as current context. Select the
        # scoped inspection identity explicitly without changing that context.
        self.base.extend(["--context", "homelab-diagnostic"])
        self.require_exec()
        evidence = self.probe(self.pod())
        atomic_write_json(
            self.run_dir / "diagnostics" / "mylar3-integrity.json",
            {
                "hardlinkIdentity": True,
                "archiveValid": True,
                "downloadedRecordValid": True,
                "archiveBytes": evidence["bytes"],
                "archivePages": evidence["pages"],
                "minimumLinkCount": evidence["links"],
            },
        )
        print("Mylar fixture hardlinks, archive integrity and Downloaded record verified.")

    def run(self) -> None:
        self.require_exec()
        if self.call("auth", "can-i", "delete", "pods", "-n", "media").strip() != "yes":
            raise ScenarioFailure(
                "selected identity lacks the explicitly required acceptance authority"
            )
        before_pod = self.pod()
        uid = before_pod["metadata"]["uid"]
        volume = self.volume()
        before = self.probe(before_pod)
        deployment = self.resource("media", "get", "deployment", "mylar3")
        if (
            deployment["spec"].get("replicas") != 1
            or deployment["spec"].get("strategy", {}).get("type") != "Recreate"
        ):
            raise ScenarioFailure("unexpected Mylar deployment configuration")
        owners = [
            o
            for o in before_pod["metadata"].get("ownerReferences", [])
            if o.get("controller") and o.get("kind") == "ReplicaSet"
        ]
        if len(owners) != 1:
            raise ScenarioFailure("Mylar pod does not have one ReplicaSet controller")
        replica_set = self.resource("media", "get", "replicaset", owners[0]["name"])
        if not any(
            o.get("controller")
            and o.get("kind") == "Deployment"
            and o.get("uid") == deployment["metadata"]["uid"]
            for o in replica_set["metadata"].get("ownerReferences", [])
        ):
            raise ScenarioFailure("pod is not owned by the Mylar deployment")
        # Repeat live preconditions immediately before the exact-UID deletion.
        if self.pod()["metadata"]["uid"] != uid or self.volume() != volume:
            raise ScenarioFailure("Mylar target changed before replacement")
        self.admit_deletion()
        options = {"apiVersion": "v1", "kind": "DeleteOptions", "preconditions": {"uid": uid}}
        name = before_pod["metadata"]["name"]
        write_recovery(
            self.run_dir, "not-attempted", "replacement requested; readiness recovery pending"
        )
        deletion_accepted = False
        try:
            self.call(
                "delete",
                "--raw",
                f"/api/v1/namespaces/media/pods/{name}",
                "-f",
                "-",
                data=json.dumps(options),
            )
            deletion_accepted = True
            after_pod = self.ready_after(uid)
            write_recovery(
                self.run_dir, "passed", "replacement Mylar pod is Ready; no test files created"
            )
            if self.volume() != volume:
                raise ScenarioFailure("Mylar config claim changed its bound volume")
            longhorn = self.resource("longhorn-system", "get", "volumes.longhorn.io", volume)[
                "status"
            ]
            if (
                longhorn.get("state") != "attached"
                or longhorn.get("currentNodeID") != after_pod["spec"]["nodeName"]
            ):
                raise ScenarioFailure(
                    "config volume is not attached to the replacement pod's node"
                )
            after = self.probe(after_pod)
            if any(before[k] != after[k] for k in ("digest", "bytes", "pages")):
                raise ScenarioFailure("fixture content changed across pod replacement")
            atomic_write_json(
                self.run_dir / "diagnostics" / "mylar3-acceptance.json",
                {
                    "hardlinkBeforeAndAfter": True,
                    "archiveValidBeforeAndAfter": True,
                    "downloadedRecordPreserved": True,
                    "configVolumePreserved": True,
                    "replacementReady": True,
                    "nodeChanged": before_pod["spec"]["nodeName"] != after_pod["spec"]["nodeName"],
                    "archiveBytes": after["bytes"],
                    "archivePages": after["pages"],
                    "minimumLinkCount": min(before["links"], after["links"]),
                },
            )
            print(
                "Mylar fixture integrity, hardlinks, Downloaded record and retained config survived pod replacement."
            )
        except Exception:
            try:
                if not deletion_accepted:
                    try:
                        current = self.pod()
                    except ScenarioFailure:
                        current = None
                    if current is not None and current["metadata"]["uid"] == uid:
                        write_recovery(
                            self.run_dir,
                            "passed",
                            "deletion failed; original Mylar pod remains Ready",
                        )
                    else:
                        self.ready_after(uid, timeout=60)
                        write_recovery(
                            self.run_dir,
                            "passed",
                            "Mylar pod recovered after an uncertain delete response",
                        )
                else:
                    self.ready_after(uid, timeout=60)
                    write_recovery(
                        self.run_dir,
                        "passed",
                        "replacement Mylar pod recovered; primary assertion failed",
                    )
            except (ScenarioFailure, OSError, ValueError, KeyError, subprocess.TimeoutExpired):
                write_recovery(
                    self.run_dir,
                    "failed",
                    "Mylar readiness recovery needs operator inspection; PVCs were not modified",
                )
            raise


def main() -> int:
    install_interrupt_handlers()
    run_dir = Path(os.environ.get("HOMELAB_TEST_RUN_DIR", ""))
    try:
        if (
            len(sys.argv) not in (2, 3)
            or (len(sys.argv) == 3 and sys.argv[2] != "--integrity-only")
            or not os.environ.get("HOMELAB_TEST_RUN_DIR")
        ):
            raise ScenarioFailure("use the registered integration recipe")
        write_recovery(run_dir, "not-required", "preflight; no mutation attempted")
        fixture = validate_fixture(
            json.loads(Path(os.environ["MYLAR_ACCEPTANCE_FIXTURE"]).read_text())
        )
        acceptance = Acceptance(os.environ.get("TEST_KUBECONFIG", sys.argv[1]), fixture, run_dir)
        if len(sys.argv) == 3:
            acceptance.verify_integrity()
        else:
            acceptance.run()
        return 0
    except (ScenarioFailure, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(
            str(error)
            if isinstance(error, ScenarioFailure)
            else "Acceptance input or runtime operation failed; private values omitted.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
