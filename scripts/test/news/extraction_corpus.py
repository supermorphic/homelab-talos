"""Replay protected retained inputs and publish IDs, counts, reasons and hashes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unicodedata
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[3]


def normalize(text):
    text = unicodedata.normalize("NFKC", text).translate(
        str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-", "−": "-"})
    )
    return re.sub(r"\s+", "", text).casefold()


def image_key(url):
    path = urlsplit(url).path
    photo = re.search(r"/photos/([^/]+)", path)
    return "photo:" + photo[1] if photo else re.sub(r"-\d+x\d+(?=\.)", "", path)


class Parsed(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.text = []
        self.images = []
        self.tags = []
        self.feed(html)
        self.close()

    def handle_data(self, data):
        self.text.append(data)

    def handle_starttag(self, tag, attrs):
        self.tags.append(tag)
        if tag == "img":
            self.images.append(image_key(dict(attrs).get("src", "")))


def assess(html: str, reference: dict) -> dict:
    parsed = Parsed(html)
    text = normalize(" ".join(parsed.text))
    blocks = reference.get("blocks", [])
    missing = sum(normalize(block["text"]) not in text for block in blocks)
    captions = sum(normalize(caption) not in text for caption in reference.get("captions", []))
    images = sum(image not in parsed.images for image in reference.get("images", []))
    structures = sum(
        parsed.tags.count(tag) < sum(b["tag"] == tag for b in blocks)
        for tag in ("h2", "h3", "h4", "li", "td", "th")
    )
    ordered_paragraphs = reference.get(
        "paragraph_order", [b["text"] for b in blocks if b.get("tag") == "p"]
    )
    positions = [
        text.find(normalize(paragraph))
        for paragraph in ordered_paragraphs
        if normalize(paragraph) in text
    ]
    image_positions = [
        parsed.images.index(key)
        for key in reference.get("image_order", [])
        if key in parsed.images
    ]
    order = positions == sorted(positions) and image_positions == sorted(image_positions)
    excluded = reference.get("excluded_blocks", [])
    unwanted = sum(normalize(block) in text for block in excluded)
    unwanted += sum(
        parsed.tags.count(tag)
        for tag in ("nav", "header", "footer", "aside", "form", "script", "iframe")
    )
    return {
        "pass": not (missing or captions or images or structures or unwanted) and order,
        "editorial_blocks": len(blocks),
        "editorial_images": len(reference.get("images", [])),
        "editorial_captions": len(reference.get("captions", [])),
        "missing_blocks": missing,
        "unexpected_blocks": unwanted,
        "excluded_blocks_checked": len(excluded),
        "missing_captions": captions,
        "missing_images": images,
        "missing_structures": structures,
        "order_preserved": order,
    }


def validate_corpus(root: Path) -> tuple[dict, str]:
    try:
        root = root.resolve(strict=True)
        path = root / "manifest.json"
        if path.is_symlink():
            raise ValueError("corpus manifest must be a regular file")
        raw = path.read_bytes()
        manifest = json.loads(raw)
        cases = manifest["cases"]
        ids = [case["id"] for case in cases]
        if (
            manifest.get("schema") != 1
            or not ids
            or len(ids) != len(set(ids))
            or not set(manifest["original_ids"]).issubset(ids)
        ):
            raise ValueError("incomplete corpus")
        files = [(c["html"], c["sha256"]) for c in cases] + list(
            manifest.get("reviews", {}).items()
        )
        files += [(c["rss"], c["rss_sha256"]) for c in cases if "rss" in c]
        for name, digest in files:
            if (
                not isinstance(name, str)
                or not re.fullmatch(r"[A-Za-z0-9_./-]+", name)
                or name.startswith("/")
                or ".." in name.split("/")
            ):
                raise ValueError("invalid corpus path")
            file = root / name
            if (
                file.is_symlink()
                or not file.resolve().is_relative_to(root)
                or not file.is_file()
                or hashlib.sha256(file.read_bytes()).hexdigest() != digest
            ):
                raise ValueError("corpus hash mismatch")
        return manifest, hashlib.sha256(raw).hexdigest()
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError("missing or malformed protected corpus") from error


def replay(root: Path, app: Path, *, broken=False) -> dict:
    from scripts.test.news.extraction_local import container

    manifest, fingerprint = validate_corpus(root)
    expected = json.loads(
        (ROOT / "tests/fixtures/news/extraction/corpus-expectations.json").read_text()
    )
    if (
        fingerprint != expected["sha256"]
        or sorted(c["id"] for c in manifest["cases"]) != sorted(expected["cases"])
        or len(manifest["original_ids"]) != 17
    ):
        raise ValueError("protected corpus differs from reviewed contract")
    release = json.loads((app / "release.json").read_text())
    output = container(
        "sh /app/scripts/initialize.sh >&2 && /usr/bin/php8.4 -d extension=tidy /repo/scripts/test/news/extraction-corpus-replay.php"
        + (" broken" if broken else ""),
        app=app,
        network="bridge",
        corpus=root,
    )
    replies = json.loads(output)
    cases = []
    for source, result in zip(manifest["cases"], replies, strict=True):
        if source["id"] != result.get("id"):
            raise ValueError("corpus reply identity mismatch")
        wanted = source["expected"]
        quality = (
            assess(result.get("html", ""), source.get("reference", {}))
            if wanted == "accepted"
            else {}
        )
        passed = result.get("decision") == wanted and (wanted != "accepted" or quality["pass"])
        if source.get("mode") == "rss":
            passed = result.get("html_sha256") == source["rss_sha256"]
        case = {
            "id": source["id"],
            "status": "pass" if passed else "fail",
            "reason": result.get("reason", "reply_invalid"),
            "body_sha256": result.get("html_sha256"),
            **quality,
        }
        cases.append(case)
    return {
        "schema": 1,
        "phase": "corpus",
        "status": "pass" if all(c["status"] == "pass" for c in cases) else "fail",
        "release_id": release["id"],
        "rules_commit": release["rules"]["commit"],
        "corpus_sha256": fingerprint,
        "cases": cases,
    }


def export_archive(root: Path, destination: Path) -> dict:
    manifest, digest = validate_corpus(root)
    names = {"manifest.json", *manifest.get("reviews", {})}
    names.update(c["html"] for c in manifest["cases"])
    names.update(c["rss"] for c in manifest["cases"] if "rss" in c)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with destination.open("xb") as output:
        os.chmod(destination, 0o600)
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            for name in sorted(names):
                archive.add(root / name, arcname=name, recursive=False)
    return {
        "schema": 1,
        "private": True,
        "durable": False,
        "corpus_sha256": digest,
        "archive_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        "cases": len(manifest["cases"]),
    }


def retrieve_archive(archive: Path, destination: Path) -> dict:
    if destination.exists():
        raise ValueError("retrieval target must be absent")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(
        prefix="corpus-retrieval-", dir=destination.parent
    ) as temporary:
        staging = Path(temporary) / "corpus"
        staging.mkdir(mode=0o700)
        with tarfile.open(archive, "r:gz") as source:
            names = set()
            total = 0
            for member in source:
                name = member.name
                total += member.size
                if (
                    not member.isfile()
                    or not re.fullmatch(r"[A-Za-z0-9_./-]+", name)
                    or name.startswith("/")
                    or ".." in name.split("/")
                    or name in names
                    or member.size > 8388608
                    or total > 134217728
                    or len(names) >= 1000
                ):
                    raise ValueError("unsafe corpus archive")
                names.add(name)
                target = staging / name
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                body = source.extractfile(member)
                if body is None:
                    raise ValueError("unreadable corpus member")
                with target.open("xb") as output:
                    os.chmod(target, 0o600)
                    shutil.copyfileobj(body, output)
        manifest, digest = validate_corpus(staging)
        staging.rename(destination)
    return {
        "schema": 1,
        "private": True,
        "durable": False,
        "corpus_sha256": digest,
        "retrieved_sha256": digest,
        "cases": len(manifest["cases"]),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("replay", "self-test", "export", "retrieve"),
        nargs="?",
        default="replay",
    )
    parser.add_argument("destination", type=Path, nargs="?")
    args = parser.parse_args()
    if args.action in ("export", "retrieve"):
        if args.destination is None:
            parser.error("export/retrieve requires a destination")
        if args.action == "export":
            receipt = export_archive(
                Path(os.environ.get("NEWS_EXTRACTION_CORPUS", "")), args.destination
            )
        else:
            receipt = retrieve_archive(
                Path(os.environ.get("NEWS_EXTRACTION_CORPUS_ARCHIVE", "")), args.destination
            )
        print(json.dumps(receipt, sort_keys=True))
        return
    root = Path(os.environ.get("NEWS_EXTRACTION_CORPUS", ""))
    app = Path(
        os.environ.get("NEWS_EXTRACTION_CANDIDATE", str(ROOT / "kubernetes/apps/news/graby/app"))
    )
    report = replay(root, app)
    if args.action == "self-test":
        broken = replay(root, app, broken=True)
        if broken["status"] != "fail" or not any(
            case["id"].startswith("ars-") and case["status"] == "fail" for case in broken["cases"]
        ):
            raise ValueError("missing Ars rule did not fail the immutable corpus gate")
        print("Missing Ars rule negative control failed as required")
    target = os.environ.get("NEWS_EXTRACTION_EVIDENCE")
    if target:
        Path(target).write_text(json.dumps(report, indent=2) + "\n")
    run = os.environ.get("HOMELAB_TEST_RUN_DIR")
    if run:
        path = Path(run) / "diagnostics/news-extraction-corpus.json"
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n")
    for case in report["cases"]:
        print(
            case["id"],
            case["status"],
            case["reason"],
            "missing",
            case.get("missing_blocks", 0),
            case.get("missing_images", 0),
            case.get("missing_captions", 0),
        )
    print("release", report["release_id"], "corpus", report["corpus_sha256"])
    if report["status"] != "pass":
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, AssertionError, tarfile.TarError, subprocess.SubprocessError):
        raise SystemExit(
            "Protected corpus replay failed; check retained input hashes and candidate runtime"
        ) from None
