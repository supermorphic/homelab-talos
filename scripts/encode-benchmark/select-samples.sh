#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
	echo 'usage: select-samples.sh <census.csv> <seed> <local-movie-root>' >&2
	exit 64
fi

exec python3 - "$@" <<'PYTHON'
import csv
import hashlib
import json
import os
import sys
from pathlib import Path, PurePosixPath

census_path, seed_text, local_root_text = sys.argv[1:]
if not seed_text.isdigit() or int(seed_text) < 0:
    print(f"invalid selection seed: {seed_text}", file=sys.stderr)
    raise SystemExit(64)

expected_header = [
    "source_path", "source_size_bytes", "link_count", "lifecycle_state",
    "lifecycle_evidence", "torrent_hash", "torrent_category", "torrent_tags",
    "cohort", "container", "duration_seconds", "video_codec", "width", "height",
    "pixel_format", "bit_depth", "color_primaries", "color_transfer", "color_space",
    "hdr_format", "dolby_vision_profile", "video_bit_rate", "frame_rate",
    "audio_track_count", "subtitle_count", "chapter_count", "audio_bytes_total",
    "audio_bytes_method",
]
major_cohorts = ("avc", "vc1", "hdr10")
root = Path(local_root_text).resolve()
if not root.is_dir():
    print(f"local movie root not found: {local_root_text}", file=sys.stderr)
    raise SystemExit(66)


def fail(message, status=65):
    print(message, file=sys.stderr)
    raise SystemExit(status)


def media_relative(source_path):
    logical = PurePosixPath(source_path)
    if not logical.is_absolute() or logical.parts[:2] != ("/", "media"):
        fail(f"invalid census media path: {source_path}")
    relative_parts = logical.parts[2:]
    if not relative_parts or any(part in {"", ".", ".."} for part in relative_parts):
        fail(f"invalid census media path: {source_path}")
    return relative_parts


rows_by_cohort = {cohort: [] for cohort in major_cohorts}
seen_paths = set()
try:
    with open(census_path, newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, strict=True)
        if reader.fieldnames != expected_header:
            fail("invalid census CSV header")
        for row_number, row in enumerate(reader, 2):
            if None in row or any(value is None for value in row.values()):
                fail(f"invalid census CSV row {row_number}")
            cohort = row["cohort"]
            if cohort not in rows_by_cohort:
                continue
            source_path = row["source_path"]
            media_relative(source_path)
            if source_path in seen_paths:
                fail(f"duplicate census source path: {source_path}")
            seen_paths.add(source_path)
            try:
                source_size = int(row["source_size_bytes"])
                bit_rate = int(row["video_bit_rate"])
                width = int(row["width"])
                height = int(row["height"])
            except ValueError:
                fail(f"invalid numeric census field at row {row_number}")
            if source_size <= 0 or bit_rate <= 0 or width <= 0 or height <= 0:
                continue
            rank = hashlib.sha256(f"{seed_text}|{source_path}".encode()).hexdigest()
            rows_by_cohort[cohort].append(
                {
                    "path": source_path,
                    "size": source_size,
                    "bit_rate": bit_rate,
                    "width": width,
                    "height": height,
                    "rank": rank,
                }
            )
except (OSError, UnicodeError, csv.Error) as error:
    fail(f"unable to read census CSV: {type(error).__name__}", 66)


selected = []
for cohort in major_cohorts:
    population = sorted(rows_by_cohort[cohort], key=lambda row: (row["bit_rate"], row["path"]))
    count = len(population)
    if count == 0:
        continue
    for index, row in enumerate(population):
        row["quartile"] = min(3, index * 4 // count)
    selected_paths = set()
    cohort_selection = []
    for quartile in sorted({row["quartile"] for row in population}):
        candidate = min(
            (row for row in population if row["quartile"] == quartile),
            key=lambda row: (row["rank"], row["path"]),
        )
        cohort_selection.append(candidate)
        selected_paths.add(candidate["path"])
    target = min(8, count)
    for candidate in sorted(population, key=lambda row: (row["rank"], row["path"])):
        if len(cohort_selection) >= target:
            break
        if candidate["path"] in selected_paths:
            continue
        cohort_selection.append(candidate)
        selected_paths.add(candidate["path"])
    for row in sorted(cohort_selection, key=lambda item: item["path"]):
        parts = media_relative(row["path"])
        local_path = root.joinpath(*parts).resolve()
        try:
            local_path.relative_to(root)
        except ValueError:
            fail(f"invalid census media path: {row['path']}")
        if not local_path.is_file():
            fail(f"local sample not found for {row['path']}", 66)
        actual_size = local_path.stat().st_size
        if actual_size != row["size"]:
            fail(f"size mismatch for {row['path']}")
        digest = hashlib.sha256()
        with local_path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        sample_id = f"{cohort}-{row['rank'][:12]}"
        selected.append(
            {
                "id": sample_id,
                "cohort": cohort,
                "path": row["path"],
                "size": row["size"],
                "width": row["width"],
                "height": row["height"],
                "sha256": digest.hexdigest(),
            }
        )

sample_ids = [sample["id"] for sample in selected]
if len(sample_ids) != len(set(sample_ids)):
    fail("deterministic sample id collision")

json.dump(
    {
        "savingsSeed": int(seed_text),
        "savingsPanel": [
            {
                "id": sample["id"],
                "cohort": sample["cohort"],
                "path": sample["path"],
                "sizeBytes": sample["size"],
                "width": sample["width"],
                "height": sample["height"],
                "sha256": sample["sha256"],
            }
            for sample in selected
        ],
    },
    sys.stdout,
    indent=2,
    sort_keys=True,
)
sys.stdout.write("\n")
PYTHON
