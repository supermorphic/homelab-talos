"""Credential-redacted qBittorrent API bridge for the guarded policy E2E."""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Callable
from typing import Any

QBITTORRENT_URL = "http://qbittorrent.media.svc.cluster.local:8080"


def require_args(args: list[str], count: int) -> None:
    if len(args) != count:
        raise SystemExit(2)


def emit_json(value: Any) -> None:
    print(json.dumps(value))


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
    result = operation(*operands)
    print("Ok." if result is None else result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
