#!/usr/bin/env python3
"""Emit a credential-redacted qBittorrent inode/lifecycle inventory."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

QBITTORRENT_URL = "http://qbittorrent.media.svc.cluster.local:8080"
PRODUCTION_DOWNLOAD_ROOT = PurePosixPath("/data/downloads")
STATE_PRIORITY = {
    "public-awaiting-cleanup": 1,
    "private-permanent": 2,
    "active": 3,
}


@dataclass(frozen=True)
class InodeState:
    lifecycle_state: str
    torrent_hash: str
    category: str
    tags: str


def normalized_tags(raw_tags: str) -> tuple[str, set[str]]:
    tags = {tag.strip() for tag in raw_tags.split(",") if tag.strip()}
    return ",".join(sorted(tags)), tags


def lifecycle_state(torrent_state: str, tags: set[str]) -> str:
    if torrent_state not in {"stoppedUP", "pausedUP"}:
        return "active"
    if "tracker-private" in tags or "tracker-czteam" in tags:
        return "private-permanent"
    return "public-awaiting-cleanup"


def download_root() -> Path:
    override = os.environ.get("BENCHMARK_DOWNLOAD_ROOT")
    test_mode = os.environ.get("BENCHMARK_TEST_MODE") == "1"
    if override and not test_mode:
        raise ValueError("BENCHMARK_DOWNLOAD_ROOT requires BENCHMARK_TEST_MODE=1")
    return Path(override) if override else Path(PRODUCTION_DOWNLOAD_ROOT)


def mapped_download_path(root: Path, save_path: str, file_name: str) -> Path:
    logical_path = PurePosixPath(save_path) / PurePosixPath(file_name)
    try:
        relative_path = logical_path.relative_to(PRODUCTION_DOWNLOAD_ROOT)
    except ValueError as error:
        raise ValueError(f"torrent path outside /data/downloads: {logical_path}") from error
    candidate = root.joinpath(*relative_path.parts)
    resolved_root = root.resolve()
    resolved_candidate = candidate.resolve()
    if not resolved_candidate.is_relative_to(resolved_root):
        raise ValueError(f"torrent path escapes download root: {logical_path}")
    return resolved_candidate


def client_for(username: str, password: str) -> Any:
    import qbittorrentapi

    client = qbittorrentapi.Client(
        host=QBITTORRENT_URL,
        username=username,
        password=password,
        REQUESTS_ARGS={"timeout": 30},
    )
    client.auth_log_in()
    return client


def main() -> int:
    try:
        root = download_root()
    except ValueError as error:
        print(error, file=sys.stderr)
        return 64

    username = os.environ.get("QBT_USER")
    password = os.environ.get("QBT_PASS")
    if not username or not password:
        print("QBT_USER and QBT_PASS are required", file=sys.stderr)
        return 64

    client = client_for(username, password)
    by_inode: dict[int, InodeState] = {}
    torrents = sorted(
        client.torrents_info(category="movies"), key=lambda torrent: torrent.hash
    )
    for torrent in torrents:
        if torrent.category != "movies":
            continue
        tags_text, tags = normalized_tags(torrent.tags)
        state = lifecycle_state(torrent.state, tags)
        inode_state = InodeState(
            lifecycle_state=state,
            torrent_hash=torrent.hash,
            category=torrent.category,
            tags=tags_text,
        )
        for file_info in client.torrents_files(torrent_hash=torrent.hash):
            path = mapped_download_path(root, torrent.save_path, file_info.name)
            try:
                inode = path.stat().st_ino
            except FileNotFoundError:
                continue
            current = by_inode.get(inode)
            if current is None or STATE_PRIORITY[state] > STATE_PRIORITY[current.lifecycle_state]:
                by_inode[inode] = inode_state

    # JSON Lines, not TSV. The consumer runs inside the ffmpeg runtime image,
    # which has no python3; jq is present and parses quoting, embedded tabs and
    # embedded newlines correctly, so emitting JSON removes the parsing burden
    # rather than relocating it into a hand-written awk state machine.
    for inode in sorted(by_inode):
        item = by_inode[inode]
        json.dump(
            {
                "inode": inode,
                "lifecycle_state": item.lifecycle_state,
                "torrent_hash": item.torrent_hash,
                "category": item.category,
                "tags": item.tags,
            },
            sys.stdout,
            separators=(",", ":"),
            sort_keys=True,
        )
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"qBittorrent inventory failed: {type(error).__name__}", file=sys.stderr)
        raise SystemExit(1) from None
