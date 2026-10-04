"""Operator-run Komga acceptance; application and cluster requests are read-only.

Private inputs and the pre-rollout baseline stay under .tmp. Only constant check
labels and the attended Panels version enter canonical stdout/report evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASE_URL = "https://komga.lab.supermorphic.com"
FORGEJO_URL = "https://forgejo.infra.supermorphic.com/supermorphic/homelab-talos.git"
LIMIT = 32 * 1024 * 1024
ID_PATTERN = re.compile(r"[A-Za-z0-9]{1,80}\Z")
CBZ_TITLE = "Acceptance CBZ title"
CBZ_SUMMARY = "Synthetic ComicInfo metadata"
WRITER = "Acceptance writer"
PUBLISHER = "Acceptance publisher"


class Failure(Exception):
    """A fixed, safe diagnostic; never include response data or private inputs."""


def require(condition, message):
    if not condition:
        raise Failure(message)


def fixture_page(index):
    """Two deterministic, self-created PNG pages; no copyrighted content."""
    colors = [(220, 40, 40), (40, 80, 220)]
    require(index in (0, 1), "Invalid synthetic page index.")

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        )

    rows = (b"\0" + bytes(colors[index]) * 32) * 48
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 48, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def write_private(path, data):
    # Preserve any existing operator file, including an earlier baseline.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as output:
            json.dump(data, output, indent=2)
            output.write("\n")
    except OSError:
        raise Failure("Private output already exists or cannot be created.") from None


def read_private(path):
    require(not path.is_symlink(), "Private input must not be a symlink.")
    try:
        info = path.stat()
        require(info.st_mode & 0o777 == 0o600, "Private input must have mode 0600.")
        require(info.st_uid == os.getuid(), "Private input must belong to the caller.")
        require(info.st_size <= 64 * 1024, "Private input is too large.")
        return json.loads(path.read_text())
    except (OSError, ValueError):
        raise Failure("Cannot read private JSON input.") from None


def generate(directory):
    require(not directory.exists(), "Fixture directory already exists; preserve its contents.")
    directory.mkdir(parents=True, mode=0o700)
    content = directory / "content"
    content.mkdir(mode=0o700)
    with zipfile.ZipFile(content / "acceptance.cbz", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("001.png", fixture_page(0))
        archive.writestr("002.png", fixture_page(1))
        archive.writestr(
            "ComicInfo.xml",
            f"<ComicInfo><Title>{CBZ_TITLE}</Title><Series>Acceptance series</Series>"
            f"<Number>1</Number><Summary>{CBZ_SUMMARY}</Summary>"
            f"<Writer>{WRITER}</Writer></ComicInfo>",
        )
    (content / "series.json").write_text(
        json.dumps(
            {
                "version": "1.0.1",
                "metadata": {
                    "type": "comicSeries",
                    "name": "Acceptance series",
                    "volume": 1,
                    "year": 2026,
                    "publisher": PUBLISHER,
                    "status": "Ended",
                    "total_issues": 1,
                },
            }
        )
        + "\n"
    )
    write_private(
        directory / "fixture.json",
        {
            "schema_version": 1,
            "books": {"cbz": "", "cbr": ""},
            "expected_cbr_pages": 0,
            "collection_id": "",
            "repeat_scan": False,
            "panels": {
                "version": "",
                "integration": "opds_v1",
                "trusted_https": False,
                "browsing": False,
                "reading": False,
                "streaming": False,
                "offline_download": False,
                "resume": False,
                "server_progress": "not_tested",
            },
            "mylar_to_library": False,
        },
    )


def validate_fixture(data):
    require(isinstance(data, dict) and data.get("schema_version") == 1, "Invalid fixture schema.")
    require(
        set(data)
        == {
            "schema_version",
            "books",
            "expected_cbr_pages",
            "collection_id",
            "repeat_scan",
            "panels",
            "mylar_to_library",
        },
        "Fixture fields do not match the generated template.",
    )
    books = data.get("books")
    require(
        isinstance(books, dict) and set(books) == {"cbz", "cbr"}, "Select both CBZ and CBR books."
    )
    ids = [books.get("cbz"), books.get("cbr"), data.get("collection_id")]
    require(
        all(isinstance(value, str) and ID_PATTERN.fullmatch(value) for value in ids),
        "Fill in the private book and collection IDs from Komga URLs.",
    )
    require(books["cbz"] != books["cbr"], "CBZ and CBR selections must be distinct.")
    require(
        type(data.get("expected_cbr_pages")) is int and data["expected_cbr_pages"] >= 2,
        "Record the independently inspected CBR page count.",
    )
    require(type(data.get("repeat_scan")) is bool, "Repeat scan outcome must be a boolean.")
    require(type(data.get("mylar_to_library")) is bool, "Mylar outcome must be a boolean.")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Api:
    def __init__(self, key):
        require(bool(key), "Privately export KOMGA_API_KEY for the reading account.")
        self.key = key
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, path, accept):
        require(path.startswith("/api/") and ".." not in path, "Invalid application request path.")
        request = urllib.request.Request(
            BASE_URL + path, headers={"X-API-Key": self.key, "Accept": accept}
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                body = response.read(LIMIT + 1)
                require(len(body) <= LIMIT, "Application response exceeded the size bound.")
                return body, response.headers.get_content_type()
        except urllib.error.HTTPError as error:
            raise Failure(f"Application request failed with HTTP {error.code}.") from None
        except (OSError, urllib.error.URLError):
            raise Failure("Application request failed; check private HTTPS access.") from None

    def json(self, path):
        body, _ = self.request(path, "application/json")
        try:
            value = json.loads(body)
        except ValueError:
            raise Failure("Application returned invalid JSON.") from None
        require(isinstance(value, dict), "Application returned an unexpected response shape.")
        return value

    def page(self, book_id, page):
        return self.request(
            f"/api/v1/books/{book_id}/pages/{page}?zero_based=false&contentNegotiation=false",
            "image/*",
        )


def image_payload(data, media_type):
    return media_type.startswith("image/") and (
        data.startswith((b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a"))
        or (data.startswith(b"RIFF") and data[8:12] == b"WEBP")
        or (data[4:8] == b"ftyp" and data[8:12] in (b"avif", b"avis"))
    )


def application_state(api, data):
    validate_fixture(data)
    account = api.json("/api/v2/users/me")
    require(bool(account.get("id")), "Reading-account authentication failed.")
    books = []
    marker_found = False
    for kind, book_id in data["books"].items():
        book = api.json(f"/api/v1/books/{book_id}")
        media = book.get("media", {})
        count = media.get("pagesCount")
        expected_types = (
            {"application/zip"}
            if kind == "cbz"
            else {"application/x-rar-compressed", "application/vnd.rar", "application/x-rar"}
        )
        require(
            book.get("id") == book_id and book.get("deleted") is False,
            "Selected book is missing or deleted.",
        )
        require(
            media.get("status") == "READY" and media.get("mediaType") in expected_types,
            "Selected archive has not completed supported-format analysis.",
        )
        require(type(count) is int and count >= 2, "Selected archive needs at least two pages.")
        if kind == "cbr":
            require(
                count == data["expected_cbr_pages"],
                "CBR page count differs from the attended sample.",
            )
        metadata = book.get("metadata", {})
        if kind == "cbz":
            require(count == 2, "Synthetic CBZ page count differs from its fixture.")
            require(
                metadata.get("title") == CBZ_TITLE
                and metadata.get("summary") == CBZ_SUMMARY
                and metadata.get("number") == "1"
                and WRITER in [author.get("name") for author in metadata.get("authors", [])],
                "Synthetic ComicInfo metadata was not imported.",
            )
            series = api.json(f"/api/v1/series/{book['seriesId']}")
            require(
                series.get("metadata", {}).get("publisher") == PUBLISHER,
                "Synthetic Mylar series metadata was not imported.",
            )
        for page in (1, count):
            body, content_type = api.page(book_id, page)
            require(image_payload(body, content_type), "Selected page did not return an image.")
            if kind == "cbz":
                require(
                    hashlib.sha256(body).digest()
                    == hashlib.sha256(fixture_page(page - 1)).digest(),
                    "Synthetic page bytes differ from the independent fixture.",
                )
        progress = book.get("readProgress") or {}
        position = progress.get("page")
        marker_found |= (
            type(position) is int and 0 < position < count and progress.get("completed") is False
        )
        books.append(
            {
                "id": book_id,
                "series_id": book.get("seriesId"),
                "file_hash": book.get("fileHash"),
                "size_bytes": book.get("sizeBytes"),
                "pages": count,
                "metadata": {
                    key: metadata.get(key) for key in ("title", "summary", "number", "authors")
                },
                "progress": {"page": position, "completed": progress.get("completed")},
            }
        )
    require(marker_found, "Seed an unfinished reading-progress marker in Komga before capture.")
    collection = api.json(f"/api/v1/collections/{data['collection_id']}")
    require(
        collection.get("id") == data["collection_id"]
        and bool(set(collection.get("seriesIds", [])) & {book["series_id"] for book in books}),
        "Seeded collection must contain a selected series.",
    )
    stable = {
        "account_id": account["id"],
        "books": sorted(books, key=lambda book: book["id"]),
        "collection": {key: collection.get(key) for key in ("id", "name", "ordered", "seriesIds")},
    }
    return {
        "account_id": account["id"],
        "digest": hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest(),
    }


def attendance(data):
    require(data.get("repeat_scan") is True, "Repeat-scan acceptance remains pending.")
    panels = data.get("panels")
    require(isinstance(panels, dict), "Fill in the attended Panels outcomes.")
    require(
        isinstance(panels.get("version"), str)
        and re.fullmatch(r"\d+(?:\.\d+){1,3}", panels["version"]),
        "Record the installed Panels version.",
    )
    require(panels.get("integration") == "opds_v1", "This fixture covers Panels using OPDS v1.")
    for key in ("trusted_https", "browsing", "reading", "resume"):
        require(panels.get(key) is True, "Required attended Panels outcome remains pending.")
    require(
        panels.get("streaming") is True or panels.get("offline_download") is True,
        "Verify streaming or offline download on the iPad.",
    )
    require(
        panels.get("server_progress") in ("passed", "unsupported"),
        "Record server progress separately from local resume.",
    )
    require(
        data.get("mylar_to_library") is True,
        "Attended Mylar post-processing to Komga-to-Panels flow remains pending.",
    )


def kube_json(kubeconfig, namespace, *args):
    command = [
        "kubectl",
        "--kubeconfig",
        str(kubeconfig),
        "-n",
        namespace,
        "get",
        *args,
        "-o",
        "json",
    ]
    try:
        value = subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
        return json.loads(value.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        raise Failure(
            "Scoped cluster observation failed; do not retry with broader credentials."
        ) from None


def observe(kubeconfig, *, need_backup):
    pods = kube_json(kubeconfig, "media", "pods", "-l", "app.kubernetes.io/name=komga")["items"]
    require(len(pods) == 1, "Wait for the single Komga pod to finish rolling out.")
    pod = pods[0]
    require(
        not pod["metadata"].get("deletionTimestamp")
        and pod["status"].get("phase") == "Running"
        and any(
            item.get("name") == "app" and item.get("ready") is True
            for item in pod["status"].get("containerStatuses", [])
        ),
        "Komga pod is not ready.",
    )
    pvc = kube_json(kubeconfig, "media", "pvc", "komga")
    require(pvc["status"].get("phase") == "Bound", "Komga config claim is not Bound.")
    config_volumes = {
        item["name"]
        for item in pod["spec"].get("volumes", [])
        if item.get("persistentVolumeClaim", {}).get("claimName") == "komga"
    }
    require(
        any(
            mount.get("mountPath") == "/config" and mount.get("name") in config_volumes
            for container in pod["spec"].get("containers", [])
            if container.get("name") == "app"
            for mount in container.get("volumeMounts", [])
        ),
        "Ready Komga container does not mount the retained config claim.",
    )
    volume_name = pvc["spec"]["volumeName"]
    volume = kube_json(kubeconfig, "longhorn-system", "volumes.longhorn.io", volume_name)
    require(volume["status"].get("robustness") == "healthy", "Komga config volume is not healthy.")
    require(
        volume["metadata"].get("labels", {}).get("recurring-job-group.longhorn.io/default")
        == "enabled",
        "Komga config volume is not enrolled in the default backup group.",
    )
    if need_backup:
        require(
            bool(volume["status"].get("lastBackupAt"))
            and bool(volume["status"].get("lastBackup")),
            "No completed Komga config backup is recorded yet.",
        )
    source = kube_json(kubeconfig, "flux-system", "gitrepository", "flux-system")
    require(
        source["spec"].get("url") == FORGEJO_URL
        and any(
            item.get("type") == "Ready" and item.get("status") == "True"
            for item in source["status"].get("conditions", [])
        ),
        "Forgejo source is not ready.",
    )
    revision = source["status"]["artifact"]["revision"]
    applied = kube_json(kubeconfig, "flux-system", "kustomization", "komga")
    require(
        applied["status"].get("lastAppliedRevision") == revision
        and any(
            item.get("type") == "Ready" and item.get("status") == "True"
            for item in applied["status"].get("conditions", [])
        ),
        "Komga has not reconciled the ready Forgejo revision.",
    )
    return {
        "pod_uid": pod["metadata"]["uid"],
        "pvc_uid": pvc["metadata"]["uid"],
        "volume": volume_name,
        "revision": revision,
    }


def compare(baseline, current, state):
    require(baseline.get("schema_version") == 1, "Invalid private baseline schema.")
    require(
        current["pod_uid"] != baseline.get("pod_uid"),
        "No pod replacement has occurred since capture.",
    )
    require(
        current["pvc_uid"] == baseline.get("pvc_uid")
        and current["volume"] == baseline.get("volume"),
        "Config claim or backing volume changed during replacement.",
    )
    require(
        state == baseline.get("state"),
        "Reading account, collection, archive identity or progress changed.",
    )


def private_path(value):
    path = Path(value).absolute()
    require(
        path.resolve().is_relative_to((ROOT / ".tmp").resolve()),
        "Keep private inputs under this worktree's .tmp.",
    )
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("generate", "capture", "verify"))
    parser.add_argument(
        "path", help="Ignored fixture directory for generate; worktree kubeconfig otherwise."
    )
    args = parser.parse_args()
    try:
        if args.action == "generate":
            generate(private_path(args.path))
            print("Synthetic CBZ, Mylar metadata and private outcome template created.")
            return 0
        require(
            os.getenv("KOMGA_ACCEPTANCE_CONFIRM")
            == f"{args.action}:media:komga:library-and-state",
            "Set the exact Komga acceptance execution-intent confirmation.",
        )
        kubeconfig = Path(args.path)
        if args.action == "verify":
            from scripts.test import access

            selected, _ = access.suite_inputs(ROOT, "test.komga-acceptance")
            require(kubeconfig == selected, "Use the selected Komga test invocation.")
        else:
            require(
                kubeconfig.resolve() == ROOT / ".kube/config",
                "Use the assigned worktree observer credential.",
            )
        fixture_path = private_path(
            os.getenv("KOMGA_ACCEPTANCE_FIXTURE", ".tmp/komga-acceptance/fixture.json")
        )
        baseline_path = private_path(
            os.getenv("KOMGA_ACCEPTANCE_BASELINE", ".tmp/komga-acceptance/baseline.json")
        )
        data = read_private(fixture_path)
        validate_fixture(data)
        current = observe(kubeconfig, need_backup=args.action == "verify")
        state = application_state(Api(os.getenv("KOMGA_API_KEY")), data)
        require(
            current == observe(kubeconfig, need_backup=args.action == "verify"),
            "Cluster changed during the application checks; retry after it stabilizes.",
        )
        if args.action == "capture":
            write_private(baseline_path, {"schema_version": 1, **current, "state": state})
            print(
                "Private account, collection and progress baseline captured. This is not a passing acceptance run."
            )
            return 0
        compare(read_private(baseline_path), current, state)
        attendance(data)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        require(
            current["revision"] == "main@sha1:" + head,
            "Run final acceptance from the exact deployed main commit.",
        )
        print(
            "CBZ/CBR expected counts, first/last pages and synthetic ComicInfo/Mylar metadata passed."
        )
        print("Operator-attested repeat scan preserved book identity and progress.")
        print(
            "Reading-account identity, collection, book identity and seeded progress survived pod replacement."
        )
        print("Retained config claim, healthy volume and completed default-group backup passed.")
        print(
            f"Operator-attested Panels {data['panels']['version']} OPDS browsing, reading and resume passed."
        )
        print("Panels server progress: " + data["panels"]["server_progress"] + ".")
        if data["panels"]["streaming"] is True:
            print("Operator-attested Panels streaming passed.")
        if data["panels"]["offline_download"] is True:
            print("Operator-attested Panels offline download passed.")
        print("Operator-attested Mylar post-processing to Komga-to-Panels flow passed.")
        return 0
    except Failure as error:
        print("Komga acceptance: " + str(error), file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 -- Retained output must never include private payloads.
        # Never let private app payloads, paths, credentials or identifiers enter
        # a traceback retained by the canonical result coordinator.
        print(
            "Komga acceptance: unexpected response or input shape; inspect privately.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
