"""Prepare immutable candidate inputs; select nothing until matching gates pass."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "kubernetes/apps/news/graby/app"
EXTENSION = ROOT / "kubernetes/apps/news/freshrss/app/extensions/xExtension-CommunityExtraction"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def fingerprint(root):
    metadata = json.loads((root / "release.json").read_text())
    metadata.pop("id", None)
    metadata["files"] = {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(root.rglob("*"))
        if p.is_file() and p.name != "release.json"
    }
    metadata["extension_files"] = {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(EXTENSION.iterdir())
        if p.is_file()
    }
    metadata["id"] = hashlib.sha256(canonical(metadata)).hexdigest()
    return metadata


def verify_candidate(candidate: dict, evidence: dict) -> bool:
    try:
        release = candidate["id"]
        unsigned = {key: value for key, value in candidate.items() if key != "id"}
        if hashlib.sha256(canonical(unsigned)).hexdigest() != release:
            return False
        contract = candidate["corpus"]
        expected = contract["cases"]
        if (
            not re.fullmatch(r"[a-f0-9]{64}", release)
            or not expected
            or len(expected) != len(set(expected))
        ):
            return False
        for phase in ("initialization", "runtime", "corpus", "ingestion"):
            report = evidence[phase]
            if (
                report.get("schema") != 1
                or report.get("phase") != phase
                or report.get("status") != "pass"
                or report.get("release_id") != release
                or report.get("rules_commit") != candidate["rules"]["commit"]
            ):
                return False
        if set(evidence["runtime"].get("checks", [])) != {"fetch", "extraction", "service"}:
            return False
        corpus = evidence["corpus"]
        cases = corpus["cases"]
        if (
            corpus.get("corpus_sha256") != contract["sha256"]
            or len(cases) != len(expected)
            or {r["id"] for r in cases} != set(expected)
            or any(r.get("status") != "pass" for r in cases)
        ):
            return False
        indexed = {case["id"]: case for case in cases}
        for identifier, requirements in contract["quality"].items():
            case = indexed[identifier]
            if case.get("pass") is not True or case.get("order_preserved") is not True:
                return False
            for kind in ("blocks", "images", "captions"):
                if (
                    case.get("editorial_" + kind) != requirements[kind]
                    or case.get("missing_" + kind) != 0
                ):
                    return False
            if (
                case.get("unexpected_blocks") != 0
                or case.get("excluded_blocks_checked") != requirements["excluded"]
            ):
                return False
            if case.get("missing_structures") != 0:
                return False
        retained = evidence["retention"]
        return (
            retained.get("status") == "pass"
            and retained.get("private") is True
            and retained.get("durable") is True
            and retained.get("corpus_sha256") == contract["sha256"]
            and retained.get("retrieved_sha256") == contract["sha256"]
        )
    except (KeyError, TypeError, ValueError):
        return False


def prepare(request: dict) -> Path:
    commit, checksum = request.get("commit", ""), request.get("sha256", "")
    if not re.fullmatch(r"[a-f0-9]{40}", commit) or not re.fullmatch(r"[a-f0-9]{64}", checksum):
        raise ValueError("immutable rule pin required")
    from scripts.test.news.extraction_corpus import validate_corpus

    corpus = Path(os.environ.get("NEWS_EXTRACTION_CORPUS", ""))
    manifest, digest = validate_corpus(corpus)
    target = ROOT / ".tmp/572/releases" / ("candidate-" + os.urandom(8).hex())
    target.mkdir(parents=True, mode=0o700)
    shutil.copytree(APP, target / "app")
    shutil.copytree(EXTENSION, target / "extension")
    metadata = fingerprint(target / "app")
    metadata.pop("id")
    metadata["rules"] = {"commit": commit, "sha256": checksum}
    metadata["corpus"] = {
        "sha256": digest,
        "cases": sorted(c["id"] for c in manifest["cases"]),
        "quality": {
            c["id"]: {
                "blocks": len(c["reference"]["blocks"]),
                "images": len(c["reference"]["images"]),
                "captions": len(c["reference"]["captions"]),
                "excluded": len(c["reference"].get("excluded_blocks", [])),
            }
            for c in manifest["cases"]
            if c["expected"] == "accepted"
        },
    }
    metadata["id"] = hashlib.sha256(canonical(metadata)).hexdigest()
    (target / "app/release.json").write_bytes(json.dumps(metadata, indent=2).encode() + b"\n")
    # Download only an immutable upstream archive. Initializer independently
    # checks the same bytes again inside the published runtime.
    url = "https://codeload.github.com/fivefilters/ftr-site-config/tar.gz/" + commit
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read(8388609)
    if len(archive) > 8388608 or hashlib.sha256(archive).hexdigest() != checksum:
        raise ValueError("upstream archive mismatch")
    (target / "rules.tar.gz").write_bytes(archive)
    environment = {
        **os.environ,
        "NEWS_EXTRACTION_CANDIDATE": str(target / "app"),
        "NEWS_EXTRACTION_EVIDENCE": str(target / "corpus.json"),
    }
    subprocess.run(
        ["mise", "exec", "--", "just", "kube", "news-extraction-corpus-test"],
        cwd=ROOT,
        env=environment,
        check=True,
    )
    return target


def verify_files(metadata: dict, root: Path, extension: Path) -> bool:
    for base, declared in (
        (root, metadata.get("files", {})),
        (extension, metadata.get("extension_files", {})),
    ):
        base = base.resolve()
        actual = {
            str(file.relative_to(base)): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in base.rglob("*")
            if file.is_file() and file.name != "release.json" and not file.is_symlink()
        }
        if not declared or declared != actual:
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "verify"))
    parser.add_argument("input", type=Path)
    args = parser.parse_args()
    request = json.loads(args.input.read_text())
    if args.action == "prepare":
        print(prepare(request).relative_to(ROOT))
    else:
        candidate = json.loads(Path(request["candidate"]).read_text())
        evidence = {
            key: json.loads(Path(path).read_text()) for key, path in request["evidence"].items()
        }
        root = Path(request["candidate"]).parent
        extension = root.parent / "extension"
        if not extension.is_dir():
            extension = EXTENSION
        if not verify_files(candidate, root, extension) or not verify_candidate(
            candidate, evidence
        ):
            raise SystemExit(
                "Candidate refused: missing, failed, mismatched, or unretained evidence"
            )
        print("Candidate evidence accepted; reviewed Git promotion remains separate")


if __name__ == "__main__":
    main()
