"""Credential-redacted qBittorrent API bridge for the guarded policy E2E."""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Callable, Mapping, Sequence
from typing import Any
from urllib.parse import urlsplit

QBITTORRENT_URL = "http://qbittorrent.media.svc.cluster.local:8080"


def require_args(args: list[str], count: int) -> None:
    if len(args) != count:
        raise SystemExit(2)


def normalize_json(value: Any) -> Any:
    if value is None or isinstance(value, bool | int | float | str):
        return value
    if isinstance(value, Mapping):
        return {str(key): normalize_json(item) for key, item in value.items()}
    if isinstance(value, Sequence):
        return [normalize_json(item) for item in value]
    data = getattr(value, "data", None)
    if data is not None:
        return normalize_json(data)
    raise TypeError(f"unsupported qBittorrent response type: {type(value).__name__}")


def emit_json(value: Any) -> None:
    print(json.dumps(normalize_json(value)))


def discovery_summary(client: Any, info_hash: str) -> dict[str, Any]:
    """Return only allowlisted discovery signals for one registered fixture."""
    info = normalize_json(client.torrents_info(torrent_hashes=info_hash))
    if len(info) != 1 or info[0].get("hash") != info_hash:
        return {"status": "fixture-missing"}

    torrent = info[0]
    preferences = normalize_json(client.app_preferences())
    transfer = normalize_json(client.transfer_info())
    trackers = normalize_json(client.torrents_trackers(torrent_hash=info_hash))
    webseeds = normalize_json(client.torrents_webseeds(torrent_hash=info_hash))
    summary: dict[str, Any] = {
        "status": "observed",
        "discoveryEnabled": {
            name: preferences[name] if type(preferences.get(name)) is bool else None
            for name in ("dht", "pex", "lsd")
        },
        "trackers": {},
        "webSeedCount": min(len(webseeds), 64),
    }
    for source, target in (
        (torrent.get("num_complete"), "knownSeeds"),
        (torrent.get("num_incomplete"), "knownLeechers"),
        (transfer.get("dht_nodes"), "dhtNodes"),
    ):
        if type(source) is int and 0 <= source <= 10_000_000:
            summary[target] = source
    status = transfer.get("connection_status")
    summary["connectionStatus"] = (
        status
        if isinstance(status, str) and status in {"connected", "firewalled", "disconnected"}
        else "unknown"
    )

    status_names = {
        0: "disabled",
        1: "notContacted",
        2: "working",
        3: "updating",
        4: "notWorking",
        5: "trackerError",
        6: "unreachable",
    }
    for tracker in trackers[:64]:
        try:
            scheme = urlsplit(str(tracker.get("url", ""))).scheme.lower()
        except ValueError:
            continue
        if scheme not in {"udp", "http", "https"}:
            continue
        counts = summary["trackers"].setdefault(scheme, {})
        tracker_status = tracker.get("status")
        label = (
            status_names.get(tracker_status, "unknown")
            if type(tracker_status) is int
            else "unknown"
        )
        counts[label] = counts.get(label, 0) + 1
        for source, target in (
            (tracker.get("num_seeds"), "maxReportedSeeds"),
            (tracker.get("num_leeches"), "maxReportedLeechers"),
        ):
            if type(source) is int and 0 <= source <= 10_000_000:
                counts[target] = max(counts.get(target, 0), source)
        message = str(tracker.get("msg", "")).lower()
        if label in {"notWorking", "trackerError", "unreachable"}:
            if any(
                phrase in message
                for phrase in ("could not resolve", "name or service not known", "host not found")
            ):
                counts["dnsErrors"] = counts.get("dnsErrors", 0) + 1
            elif "timed out" in message or "timeout" in message:
                counts["timeoutErrors"] = counts.get("timeoutErrors", 0) + 1
    return summary


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        return 2
    command, *operands = args
    username = os.environ.get("QBT_USER")
    password = os.environ.get("QBT_PASS")
    if not username or not password:
        return 1

    def health_failure(stage: str, error: Exception) -> int:
        if command != "health":
            raise error
        emit_json(
            {
                "status": "failed",
                "stage": stage,
                "errorType": type(error).__name__,
            }
        )
        return 0

    try:
        import qbittorrentapi
    except Exception as error:  # noqa: BLE001
        return health_failure("import", error)

    try:
        client = qbittorrentapi.Client(
            host=QBITTORRENT_URL,
            username=username,
            password=password,
            REQUESTS_ARGS={"timeout": 30},
        )
    except Exception as error:  # noqa: BLE001
        return health_failure("client-init", error)

    try:
        client.auth_log_in()
    except Exception as error:  # noqa: BLE001
        return health_failure("auth", error)

    if command == "health":
        require_args(operands, 0)
        emit_json({"status": "passed"})
        return 0

    if command == "discovery":
        require_args(operands, 1)
        emit_json(discovery_summary(client, operands[0]))
        return 0

    readers: dict[str, tuple[int, Callable[..., Any]]] = {
        "info": (
            1,
            lambda info_hash: client.torrents_info(torrent_hashes=info_hash),
        ),
        "files": (
            1,
            lambda info_hash: client.torrents_files(torrent_hash=info_hash),
        ),
        "categories": (0, client.torrents_categories),
        "tags": (0, client.torrents_tags),
    }
    if command in readers:
        count, operation = readers[command]
        require_args(operands, count)
        emit_json(operation(*operands))
        return 0

    mutations: dict[str, tuple[int, Callable[..., Any]]] = {
        "force-start": (
            2,
            lambda info_hash, enabled: client.torrents_set_force_start(
                torrent_hashes=info_hash,
                enable=enabled == "true",
            ),
        ),
        "add": (
            4,
            lambda url, save_path, category, name: client.torrents_add(
                urls=url,
                save_path=save_path,
                category=category,
                rename=name,
                is_root_folder=True,
                use_auto_torrent_management=False,
                is_paused=False,
            ),
        ),
        "add-tags": (
            2,
            lambda info_hash, tags: client.torrents_add_tags(
                torrent_hashes=info_hash,
                tags=tags,
            ),
        ),
        "remove-tags": (
            2,
            lambda info_hash, tags: client.torrents_remove_tags(
                torrent_hashes=info_hash,
                tags=tags,
            ),
        ),
        "create-category": (
            2,
            lambda category, save_path: client.torrents_create_category(
                name=category,
                save_path=save_path,
            ),
        ),
        "remove-category": (
            1,
            lambda category: client.torrents_remove_categories(categories=category),
        ),
        "create-tags": (1, lambda tags: client.torrents_create_tags(tags=tags)),
        "delete-tags": (1, lambda tags: client.torrents_delete_tags(tags=tags)),
        "delete": (
            1,
            lambda info_hash: client.torrents_delete(
                torrent_hashes=info_hash,
                delete_files=True,
            ),
        ),
    }
    if command not in mutations:
        return 2
    count, operation = mutations[command]
    require_args(operands, count)
    if command == "force-start" and operands[1] not in {"true", "false"}:
        return 2
    result = operation(*operands)
    print("Ok." if result is None else result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
