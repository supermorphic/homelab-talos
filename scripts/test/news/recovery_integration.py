"""Restore a paired set into owned local targets without the source service."""

import hashlib
import io
import json
import tarfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

APP = Path(__file__).resolve().parents[3] / "kubernetes/apps/news/freshrss/app"


def write_fault_tools(directory):
    directory.mkdir()
    with tarfile.open(directory / "unsafe.tar.gz", "w:gz") as archive:
        for name in ("./config.php", "./news-bootstrap.complete"):
            entry = tarfile.TarInfo(name)
            entry.size = len(b"synthetic")
            archive.addfile(entry, io.BytesIO(b"synthetic"))
        entry = tarfile.TarInfo("./escape")
        entry.type = tarfile.SYMTYPE
        entry.linkname = "/tmp/outside"
        archive.addfile(entry)
    for command, phase, real in (
        ("pg_dump", "dump", "/usr/local/bin/pg_dump"),
        ("tar", "archive", "/bin/tar"),
        ("pg_restore", "validation", "/usr/local/bin/pg_restore"),
        ("mv", "publication", "/bin/mv"),
    ):
        hold = (
            'if [ "${NEWS_TEST_FAIL:-}" = hold ]; then\n'
            "  touch /run/news/test-capture\n"
            "  while [ ! -f /run/news/test-release ]; do sleep 1; done\nfi\n"
            if phase == "dump"
            else ""
        )
        path = directory / command
        path.write_text(
            "#!/bin/sh\nset -eu\n"
            f'if [ "${{NEWS_TEST_FAIL:-}}" = {phase} ]; then exit 9; fi\n'
            + hold
            + f'exec {real} "$@"\n'
        )
        path.chmod(0o755)


def exercise_backup_failures(*, run, names, wait_ready, request, items, token, identity, base_url):
    helper = names["backup"]
    injected_path = "PATH=/faults:/usr/local/bin:/usr/bin:/bin"

    def complete_sets():
        return run("exec", helper, "sh", "-c", "printf '%s\\n' /backups/set-*").stdout

    def wait_file(path, present=True):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            exists = run("exec", helper, "test", "-e", path, success=False).returncode == 0
            if exists == present:
                return
            time.sleep(0.2)
        raise AssertionError("backup fault did not reach expected stage: " + path)

    baseline = complete_sets()
    stored = items()
    original_status = run("exec", helper, "cat", "/run/news/last-backup").stdout
    corrupt = "/backups/set-9999999999-status-test"
    run(
        "exec",
        helper,
        "sh",
        "-c",
        'source=$(printf "%s\\n" /backups/set-* | sort | tail -1); '
        'cp -a "$source" "$1"; printf invalid > "$1/database.dump"; '
        'stamp=$(cat /run/news/last-backup); while [ "$(date +%s)" -le "$stamp" ]; do sleep 1; done; '
        'sed -i "s/^created_epoch=.*/created_epoch=$(date +%s)/" "$1/manifest"; '
        '(cd "$1" && sha256sum database.dump data.tar.gz manifest > SHA256SUMS); '
        "rm /run/news/last-backup",
        "sh",
        corrupt,
    )
    run("exec", helper, "sh", "/opt/news/backup-status.sh")
    assert run("exec", helper, "cat", "/run/news/last-backup").stdout == original_status
    run("exec", helper, "rm", "-rf", corrupt)
    for phase in ("dump", "archive", "validation", "publication"):
        failed = run(
            "exec",
            "-e",
            injected_path,
            "-e",
            "NEWS_TEST_FAIL=" + phase,
            helper,
            "sh",
            "/opt/news/backup.sh",
            success=False,
        )
        assert failed.returncode != 0, "injected backup failure reported success: " + phase
        wait_ready()
        assert complete_sets() == baseline and items() == stored
        assert run("exec", helper, "cat", "/run/news/last-backup").stdout == original_status
    # A real tiny tmpfs exercises ENOSPC without touching any publisher or live volume.
    assert (
        run(
            "exec",
            "-e",
            "BACKUP_DIR=/small",
            helper,
            "sh",
            "/opt/news/backup.sh",
            success=False,
        ).returncode
        != 0
    ), "full backup filesystem reported success"
    wait_ready()
    assert complete_sets() == baseline
    # A request without a live owner must not strand the app in maintenance.
    run("exec", helper, "touch", "/run/news/maintenance-request")
    wait_file("/run/news/maintenance-request", present=False)
    wait_ready()

    # Hold capture after the real supervisor has drained HTTP and refresh writers.
    def slow_request():
        with urllib.request.urlopen(base_url + "/drain-probe.php", timeout=20) as response:
            return response.read()

    pool = ThreadPoolExecutor(max_workers=1)
    draining = pool.submit(slow_request)
    wait_file("/var/www/FreshRSS/data/.test-drain-start")
    run(
        "exec",
        "-d",
        "-e",
        injected_path,
        "-e",
        "NEWS_TEST_FAIL=hold",
        helper,
        "sh",
        "-c",
        "echo $$ > /run/news/test-parent; exec sh /opt/news/backup.sh --worker",
    )
    wait_file("/run/news/test-capture")
    assert draining.result(timeout=10) == b"complete", "backup interrupted an in-flight write"
    pool.shutdown()
    assert (
        run("exec", helper, "cat", "/var/www/FreshRSS/data/.test-drain-done").stdout == b"complete"
    )
    run("exec", names["app"], "sh", "/opt/news/live.sh")
    try:
        status, _ = request(
            "/reader/api/0/edit-tag",
            {"T": token, "i": identity, "r": "user/-/state/com.google/starred"},
        )
        assert status >= 500, "native client write entered the paired backup window"
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        pass
    refresh_stamp = run("exec", names["app"], "cat", "/run/news/last-refresh").stdout
    run("exec", names["app"], "sh", "/opt/news/refresh.sh")
    assert run("exec", names["app"], "cat", "/run/news/last-refresh").stdout == refresh_stamp
    # A competing request skips instead of starting a second capture.
    run("exec", helper, "sh", "/opt/news/backup.sh")
    assert complete_sets() == baseline
    # The orphan dump still owns its inherited lock after the coordinating shell dies.
    run("exec", helper, "sh", "-c", 'kill -KILL "$(cat /run/news/test-parent)"')
    time.sleep(1)
    assert run("exec", names["app"], "php", "/opt/news/ready.php", success=False).returncode != 0
    run("exec", helper, "touch", "/run/news/test-release")
    wait_ready()
    assert complete_sets() == baseline and items() == stored
    # A later successful capture must recover past the abandoned staging directory.
    run("exec", helper, "sh", "/opt/news/backup.sh")
    wait_ready()
    assert not run("exec", helper, "find", "/backups", "-name", ".pending-*").stdout.strip()
    # Historical complete sets use valid artifacts/checksums, with deliberately
    # older independent timestamps. Retention must preserve the newest seven.
    run(
        "exec",
        helper,
        "sh",
        "-c",
        'source=$(printf "%s\\n" /backups/set-* | sort | tail -1); '
        "for n in 1 2 3 4 5 6 7; do target=/backups/set-000000000$n-history; "
        'cp -a "$source" "$target"; sed -i "s/^created_epoch=.*/created_epoch=$n/" "$target/manifest"; '
        '(cd "$target" && sha256sum database.dump data.tar.gz manifest > SHA256SUMS); done',
    )
    run("exec", helper, "sh", "/opt/news/backup.sh")
    wait_ready()
    sets = complete_sets().decode().splitlines()
    assert len(sets) == 7 and "/backups/set-0000000001-history" not in sets


def exercise_restore(
    *,
    run,
    container,
    create,
    start_database,
    start_app,
    request,
    names,
    passwords,
    db_image,
    image,
    tmp,
    app_env,
    expected_items,
    expected_subscriptions,
    extraction_mounts,
    extraction_snapshot,
    expected_extraction,
):
    for key in ("restore-data", "restore-dbdata", "restore-runtime", "restore-backups"):
        names[key] = names["network"] + "-" + key
        ownership = ("--uid", "70", "--gid", "1000") if key == "restore-data" else ()
        create("volume", names[key], *ownership)
    for key in ("restore-db", "restore-app", "restore-tool", "restore-owner", "restore-import"):
        names[key] = names["network"] + "-" + key
    selected = run("exec", names["backup"], "sh", "-c", "printf '%s\\n' /backups/set-*")
    sets = selected.stdout.decode().splitlines()
    assert sets and all(path.startswith("/backups/set-") for path in sets)
    backup = max(sets)
    # Copy the complete recovery unit out through the host, then import it into
    # different storage. No source volume or running helper may serve recovery.
    portable = tmp / "portable-backups"
    portable.mkdir(mode=0o700)
    first = min(path for path in sets if not path.endswith("-history"))
    sets = sorted({first, backup})
    for selected_set in sets:
        run("cp", names["backup"] + ":" + selected_set, str(portable))
    expected_hashes = {
        path.relative_to(portable).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for directory in portable.iterdir()
        for path in directory.iterdir()
    }
    run("stop", names["app"], names["db"], names["backup"])
    for key in ("app", "db", "backup"):
        assert (
            run("inspect", "--format", "{{.State.Running}}", names[key]).stdout.strip() == b"false"
        )
    container(
        names["restore-import"],
        "--user",
        "1000:1000",
        "-v",
        names["restore-backups"] + ":/backups:U",
        "-v",
        str(tmp / "faults") + ":/faults:ro",
        "--entrypoint",
        "/bin/sh",
        db_image,
        "-c",
        "exec sleep infinity",
    )
    run("cp", str(portable) + "/.", names["restore-import"] + ":/backups")
    for relative, digest in expected_hashes.items():
        actual = run("exec", names["restore-import"], "sha256sum", "/backups/" + relative)
        assert actual.stdout.decode().split()[0] == digest, "portable backup copy changed bytes"
    start_database(names["restore-db"], names["restore-dbdata"], "news-restored")
    env = tmp / "restore.env"
    env.touch(mode=0o600)
    env.write_text(
        "PGHOST=news-restored\nPGDATABASE=freshrss\nPGUSER=freshrss\n"
        f"PGPASSWORD={passwords['FRESHRSS_PASSWORD']}\nDATA_PATH=/restore-data\n"
        f"NEWS_APP_IMAGE={image}\nNEWS_DATABASE_IMAGE={db_image}\n"
    )
    # Model a fresh PVC whose root is group-writable but owned by another UID.
    container(
        names["restore-owner"],
        "--user",
        "70:1000",
        "-v",
        names["restore-data"] + ":/restore-data:U",
        "--entrypoint",
        "/bin/sh",
        db_image,
        "-c",
        "chmod 0770 /restore-data",
    )
    assert run("wait", names["restore-owner"]).stdout.strip() == b"0"
    container(
        names["restore-tool"],
        "--user",
        "1000:1000",
        "--env-file",
        str(env),
        "--tmpfs",
        "/tmp:rw,size=64m",
        "-v",
        names["restore-backups"] + ":/backups:ro",
        "-v",
        names["restore-data"] + ":/restore-data",
        "-v",
        str(APP / "scripts") + ":/opt/news:ro",
        "-v",
        str(APP / "httpd.conf") + ":/opt/news-httpd.conf:ro",
        *extraction_mounts,
        "--entrypoint",
        "/bin/sh",
        db_image,
        "-c",
        "exec sleep infinity",
    )

    def empty_targets():
        assert (
            run("exec", names["restore-tool"], "stat", "-c", "%u", "/restore-data").stdout.strip()
            == b"70"
        )
        assert not run(
            "exec", names["restore-tool"], "find", "/restore-data", "-mindepth", "1"
        ).stdout.strip()
        assert (
            run(
                "exec",
                names["restore-tool"],
                "psql",
                "-XAtc",
                "SELECT count(*) FROM pg_tables WHERE schemaname='public'",
            ).stdout.strip()
            == b"0"
        )

    bad = "/backups/set-0000000000-corrupt"
    for damage in ("checksum", "dump", "archive", "mixed", "release", "inputs", "legacy"):
        run("exec", names["restore-import"], "cp", "-a", backup, bad)
        if damage == "checksum":
            run(
                "exec",
                names["restore-import"],
                "sh",
                "-c",
                'printf bad >> "$1/data.tar.gz"',
                "sh",
                bad,
            )
        elif damage == "dump":
            run(
                "exec",
                names["restore-import"],
                "sh",
                "-c",
                'printf invalid > "$1/database.dump"',
                "sh",
                bad,
            )
        elif damage == "archive":
            run(
                "exec",
                names["restore-import"],
                "cp",
                "/faults/unsafe.tar.gz",
                bad + "/data.tar.gz",
            )
        elif damage in ("release", "inputs", "legacy"):
            key = "extraction_release_id" if damage == "release" else "extraction_inputs_sha256"
            command = 'sed -i "s/^' + key + "=.*/" + key + "=" + "0" * 64 + '/" "$1/manifest"'
            if damage == "legacy":
                command = 'sed -i "/^extraction_/d;s/news-paired-v2/news-paired-v1/" "$1/manifest"'
            run("exec", names["restore-import"], "sh", "-c", command, "sh", bad)
        else:
            first = min(path for path in sets if not path.endswith("-history"))
            assert (
                run(
                    "exec",
                    names["restore-import"],
                    "cmp",
                    first + "/database.dump",
                    backup + "/database.dump",
                    success=False,
                ).returncode
                != 0
            )
            run(
                "exec",
                names["restore-import"],
                "cp",
                first + "/database.dump",
                bad + "/database.dump",
            )
        if damage in ("dump", "archive", "release", "inputs", "legacy"):
            run(
                "exec",
                names["restore-import"],
                "sh",
                "-c",
                'cd "$1" && sha256sum database.dump data.tar.gz manifest > SHA256SUMS',
                "sh",
                bad,
            )
        if damage == "legacy":
            run("exec", names["restore-tool"], "sh", "/opt/news/validate-backup.sh", bad)
        assert (
            run(
                "exec", names["restore-tool"], "sh", "/opt/news/restore.sh", bad, success=False
            ).returncode
            != 0
        ), damage
        empty_targets()
        run("exec", names["restore-import"], "rm", "-rf", bad)
    assert (
        run(
            "exec",
            "-e",
            "NEWS_APP_IMAGE=incompatible:1",
            names["restore-tool"],
            "sh",
            "/opt/news/restore.sh",
            backup,
            success=False,
        ).returncode
        != 0
    )
    empty_targets()
    run("exec", names["restore-tool"], "sh", "/opt/news/restore.sh", backup)
    # A second restore must refuse both populated filesystem and database targets.
    assert (
        run(
            "exec", names["restore-tool"], "sh", "/opt/news/restore.sh", backup, success=False
        ).returncode
        != 0
    )
    run("exec", names["restore-tool"], "mkdir", "/tmp/empty-target")
    assert (
        run(
            "exec",
            "-e",
            "DATA_PATH=/tmp/empty-target",
            names["restore-tool"],
            "sh",
            "/opt/news/restore.sh",
            backup,
            success=False,
        ).returncode
        != 0
    )
    assert not run(
        "exec", names["restore-tool"], "find", "/tmp/empty-target", "-mindepth", "1"
    ).stdout.strip()
    restored_env = tmp / "restored-app.env"
    restored_env.touch(mode=0o600)
    restored_env.write_text(
        app_env.read_text().replace("NEWS_DB_HOST=news-postgresql", "NEWS_DB_HOST=news-restored")
        + "NEWS_POLLING_ENABLED=false\n"
    )
    base = start_app(
        names["restore-app"], names["restore-data"], restored_env, names["restore-runtime"]
    )
    run("exec", names["restore-app"], "sh", "/opt/news/refresh.sh")
    assert (
        run(
            "exec",
            names["restore-app"],
            "test",
            "!",
            "-e",
            "/run/news/last-refresh",
            success=False,
        ).returncode
        == 0
    ), "isolated recovery fetched feeds"
    assert (
        request(
            "/accounts/ClientLogin",
            {"Email": "reader", "Passwd": "wrong"},
            authenticated=False,
            base_url=base,
        )[0]
        == 401
    )
    status, login = request(
        "/accounts/ClientLogin",
        {"Email": "reader", "Passwd": passwords["NEWS_API_PASSWORD"]},
        authenticated=False,
        base_url=base,
    )
    assert status == 200
    recovered_auth = dict(line.split("=", 1) for line in login.decode().splitlines())["Auth"]
    status, body = request(
        "/reader/api/0/stream/contents/reading-list?output=json&n=100",
        base_url=base,
        authorization=recovered_auth,
    )
    assert status == 200 and json.loads(body)["items"] == expected_items
    assert (
        request(
            "/reader/api/0/subscription/list?output=json",
            base_url=base,
            authorization=recovered_auth,
        )[1]
        == expected_subscriptions
    )
    assert extraction_snapshot(names["restore-app"]) == expected_extraction, (
        "restore lost original RSS, provenance or article state"
    )
    source_volumes = {names[key] for key in ("data", "dbdata", "runtime", "backups")}
    for key in ("restore-app", "restore-db", "restore-tool", "restore-import"):
        mounts = json.loads(run("inspect", names[key]).stdout)[0]["Mounts"]
        assert not any(mount.get("Name") in source_volumes for mount in mounts), (
            "recovery mounted source storage"
        )
        if key == "restore-tool":
            backup_mount = next(m for m in mounts if m["Destination"] == "/backups")
            assert not backup_mount["RW"], "restore source is writable"
    for name in (names["app"], names["db"], names["backup"]):
        assert run("inspect", "--format", "{{.State.Running}}", name).stdout.strip() == b"false"
    for name in (names["restore-app"], names["restore-db"], names["restore-tool"]):
        logs = run("logs", name)
        assert not any(value.encode() in logs.stdout + logs.stderr for value in passwords.values())
