"""Exercise the deployed FreshRSS runtime against disposable PostgreSQL and feeds."""

from __future__ import annotations

import json
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import yaml
from recovery_integration import exercise_backup_failures, exercise_restore, write_fault_tools

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "kubernetes/apps/news/freshrss/app"
DB = ROOT / "kubernetes/apps/news/postgresql/app"


def main():
    assert (APP / "scripts/start.sh").is_file(), "FreshRSS restricted startup is missing"
    deployment = yaml.safe_load((APP / "deployment.yaml").read_text())
    image = deployment["spec"]["template"]["spec"]["containers"][0]["image"]
    database = yaml.safe_load((DB / "statefulset.yaml").read_text())
    db_image = database["spec"]["template"]["spec"]["containers"][0]["image"]
    marker = "news-app-" + secrets.token_hex(6)
    label = "homelab-talos.test-run=" + marker
    names = {
        kind: marker + "-" + kind
        for kind in (
            "app",
            "db",
            "feeds",
            "scheduler",
            "backup",
            "network",
            "data",
            "dbdata",
            "runtime",
            "backups",
        )
    }
    passwords = {
        key: secrets.token_hex(24)
        for key in (
            "POSTGRES_PASSWORD",
            "FRESHRSS_PASSWORD",
            "BACKUP_PASSWORD",
            "MONITORING_PASSWORD",
            "NEWS_OPERATOR_PASSWORD",
            "NEWS_API_PASSWORD",
        )
    }
    owned = []

    def run(*args, input=None, success=True, timeout=180):
        result = subprocess.run(
            ["podman", *args], input=input, capture_output=True, timeout=timeout, check=False
        )
        if success and result.returncode:
            diagnostic = (result.stdout + result.stderr).decode(errors="replace")
            for value in passwords.values():
                diagnostic = diagnostic.replace(value, "[redacted]")
            raise AssertionError(f"Podman {args[0]} failed: {diagnostic[-1400:]}")
        return result

    def create(kind, name, *args):
        # Track the name before start: create-success/start-failure must still clean up.
        command = ("create",) if kind == "container" else (kind, "create")
        run(*command, "--label", label, *args, *(() if kind == "container" else (name,)))
        owned.append((kind, name))

    def container(name, *args):
        create(
            "container",
            name,
            "--name",
            name,
            "--platform",
            "linux/amd64",
            "--network",
            names["network"],
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--memory",
            "1g",
            *args,
        )
        run("start", name)

    def wait_ready(target=None):
        target = target or names["app"]
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            ready = run("exec", target, "php", "/opt/news/ready.php", success=False)
            if ready.returncode == 0:
                return
            time.sleep(1)
        logs = run("logs", target, success=False)
        diagnostic = (logs.stdout + logs.stderr).decode(errors="replace")
        for value in passwords.values():
            diagnostic = diagnostic.replace(value, "[redacted]")
        raise AssertionError("FreshRSS not ready: " + diagnostic[-2000:])

    try:
        run("info")
        run("pull", "--platform", "linux/amd64", image)
        run("pull", "--platform", "linux/amd64", db_image)
        create("network", names["network"], "--internal")
        for key in ("data", "dbdata", "runtime", "backups"):
            create("volume", names[key])
        with tempfile.TemporaryDirectory(prefix="news-runtime-") as temporary:
            tmp = Path(temporary)
            drain_probe = tmp / "drain-probe.php"
            drain_probe.write_text(
                "<?php $d=getenv('DATA_PATH'); "
                "file_put_contents($d.'/.test-drain-start','started'); sleep(3); "
                "file_put_contents($d.'/.test-drain-done','complete'); echo 'complete';"
            )
            # Exercise the real supervisor/refresh scripts with fast, controlled
            # child commands: a transient refresh failure must not kill scheduling.
            fakebin = tmp / "bin"
            fakebin.mkdir()
            commands = {
                "sleep": '[ "$1" != 900 ] || touch /tmp/scheduler-started\nexec /bin/sleep 0.05\n',
                "php": 'case "$1" in */bootstrap.php) exit 0;; esac\n'
                "if [ ! -f /tmp/attempt ]; then touch /tmp/attempt; exit 1; fi\n"
                "touch /tmp/refreshed\n",
                "httpd": 'if [ "${NEWS_POLLING_ENABLED:-true}" = false ]; then\n'
                '  i=0; while [ "$i" -lt 40 ]; do\n'
                "    [ ! -f /tmp/scheduler-started ] || exit 1\n"
                "    /bin/sleep 0.05; i=$((i+1))\n"
                "  done; exit 0\nfi\n"
                'i=0\nwhile [ "$i" -lt 40 ]; do\n'
                "  [ ! -f /tmp/refreshed ] || exit 0\n"
                "  /bin/sleep 0.05; i=$((i+1))\ndone\nexit 3\n",
            }
            for name, body in commands.items():
                path = fakebin / name
                path.write_text("#!/bin/sh\n" + body)
                path.chmod(0o755)
            for polling in ("true", "false"):
                target = names["scheduler"] + "-" + polling
                container(
                    target,
                    "--user",
                    "1000:1000",
                    "--tmpfs",
                    "/tmp:rw,size=16m",
                    "--tmpfs",
                    "/run/news:rw,mode=1777,size=16m",
                    "-v",
                    str(fakebin) + ":/testbin:ro",
                    "-v",
                    str(APP / "scripts") + ":/opt/news:ro",
                    "-e",
                    "PATH=/testbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    *(("-e", "NEWS_POLLING_ENABLED=false") if polling == "false" else ()),
                    "--entrypoint",
                    "/bin/sh",
                    image,
                    "/opt/news/start.sh",
                )
                assert run("wait", target, timeout=15).stdout.strip() == b"0", (
                    "scheduler ignored polling intent or stopped after a failed refresh"
                )
            db_env = tmp / "db.env"
            db_env.touch(mode=0o600)
            db_env.write_text(
                "\n".join(f"{k}={v}" for k, v in passwords.items())
                + "\nPOSTGRES_DB=postgres\nPGDATA=/var/lib/postgresql/data/pgdata\n"
                "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=trust\n"
            )

            def start_database(target, volume, alias):
                container(
                    target,
                    "--user",
                    "70:70",
                    "--env-file",
                    str(db_env),
                    "--network-alias",
                    alias,
                    "--tmpfs",
                    "/var/run/postgresql:rw,mode=1777,size=16m",
                    "--tmpfs",
                    "/tmp:rw,size=64m",
                    "-v",
                    volume + ":/var/lib/postgresql/data:U",
                    "-v",
                    str(DB / "scripts") + ":/docker-entrypoint-initdb.d:ro",
                    db_image,
                )
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    if (
                        run(
                            "exec", target, "pg_isready", "-U", "postgres", success=False
                        ).returncode
                        == 0
                    ):
                        break
                    time.sleep(1)
                else:
                    raise AssertionError("database startup timed out")

            start_database(names["db"], names["dbdata"], "news-postgresql")
            fixtures = tmp / "feeds"
            fixtures.mkdir()
            for name in ("full-feed.xml", "truncated-feed.xml"):
                source = (ROOT / "tests/fixtures/news" / name).read_text()
                if name == "full-feed.xml":
                    source = source.replace(
                        "</article>",
                        '<script>alert("synthetic")</script><img src="x" onerror="alert(1)"/></article>',
                    )
                (fixtures / name).write_text(source)
            container(
                names["feeds"],
                "--user",
                "1000:1000",
                "--network-alias",
                "news-fixtures",
                "--tmpfs",
                "/tmp:rw,size=16m",
                "-v",
                str(fixtures) + ":/fixtures:ro",
                "-v",
                str(Path(__file__).with_name("fixture-router.php")) + ":/router.php:ro",
                "--entrypoint",
                "php",
                image,
                "-S",
                "0.0.0.0:8000",
                "-t",
                "/fixtures",
                "/router.php",
            )
            app_env = tmp / "app.env"
            app_env.touch(mode=0o600)
            app_env.write_text(
                "NEWS_DB_HOST=news-postgresql\nNEWS_OPERATOR_NAME=reader\n"
                "NEWS_BASE_URL=http://localhost:8080\nDATA_PATH=/var/www/FreshRSS/data\n"
                "INTERNAL_HOST_ALLOWLIST=news-fixtures:8000\n"
                f"NEWS_DB_PASSWORD={passwords['FRESHRSS_PASSWORD']}\n"
                f"NEWS_OPERATOR_PASSWORD={passwords['NEWS_OPERATOR_PASSWORD']}\n"
                f"NEWS_API_PASSWORD={passwords['NEWS_API_PASSWORD']}\n"
            )

            def start_app(target=None, volume=None, environment=None, runtime=None):
                target = target or names["app"]
                volume = volume or names["data"]
                environment = environment or app_env
                runtime = runtime or names["runtime"]
                container(
                    target,
                    "--user",
                    "1000:1000",
                    "--env-file",
                    str(environment),
                    "--tmpfs",
                    "/tmp:rw,size=128m",
                    "-v",
                    runtime + ":/run/news:U",
                    "-v",
                    volume + ":/var/www/FreshRSS/data:U",
                    "-v",
                    str(APP / "scripts") + ":/opt/news:ro",
                    "-v",
                    str(APP / "httpd.conf") + ":/opt/news-httpd.conf:ro",
                    "-v",
                    str(drain_probe) + ":/var/www/FreshRSS/p/drain-probe.php:ro",
                    "-p",
                    "127.0.0.1::8080",
                    "-p",
                    "127.0.0.1::9090",
                    "--entrypoint",
                    "/bin/sh",
                    image,
                    "/opt/news/start.sh",
                )
                wait_ready(target)
                port = run("port", target, "8080/tcp").stdout.decode().strip().rsplit(":", 1)[1]
                return "http://127.0.0.1:" + port

            base = start_app()

            def metrics():
                port = (
                    run("port", names["app"], "9090/tcp").stdout.decode().strip().rsplit(":", 1)[1]
                )
                with urllib.request.urlopen(
                    "http://127.0.0.1:" + port + "/metrics", timeout=10
                ) as response:
                    assert response.headers["Content-Type"].startswith("text/plain")
                    body = response.read().decode()
                assert not any(value in body for value in passwords.values())
                assert (
                    "news-fixtures" not in body and "garden" not in body and "reader" not in body
                )
                run("exec", names["app"], "php", "-l", "/opt/news/metrics.php")
                parsed = subprocess.run(
                    ["promtool", "check", "metrics"],
                    input=body,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                assert parsed.returncode == 0, parsed.stderr
                return {
                    line.split()[0]: float(line.split()[1])
                    for line in body.splitlines()
                    if line and not line.startswith("#")
                }

            cold = metrics()
            assert cold["news_database_up"] == 1 and cold["news_feeds_active"] == 0
            assert cold["news_backup_last_success_timestamp_seconds"] == 0
            run("exec", names["app"], "touch", "/var/www/FreshRSS/data/.news-restore-incomplete")
            assert (
                run(
                    "exec", names["app"], "php", "/opt/news/bootstrap.php", success=False
                ).returncode
                != 0
            )
            run("exec", names["app"], "rm", "/var/www/FreshRSS/data/.news-restore-incomplete")
            # Upstream creates the user directory/config before its SQL tables.
            # Reproduce each interruption using only this disposable empty account.
            for interrupted_at in ("schema", "directory"):
                run(
                    "exec",
                    names["app"],
                    "php",
                    "-r",
                    "require '/var/www/FreshRSS/cli/_cli.php'; "
                    "if (!FreshRSS_Factory::createUserDao('reader')->deleteUser()) exit(1); "
                    "$home=getenv('DATA_PATH').'/users/reader'; "
                    "if ($argv[1]==='directory') { foreach (new DirectoryIterator($home) as $f) { "
                    "if (!$f->isDot() && (!$f->isFile() || !unlink($f->getPathname()))) exit(1); }}",
                    interrupted_at,
                )
                assert (
                    run(
                        "exec", names["app"], "php", "/opt/news/ready.php", success=False
                    ).returncode
                    != 0
                ), "readiness accepted an account without its schema"
                run(
                    "exec",
                    names["app"],
                    "php",
                    "-r",
                    "unlink(getenv('DATA_PATH').'/news-bootstrap.complete');",
                )
                run("restart", names["app"])
                wait_ready()
            # Simulate interruption after the user file was created but before API
            # credentials were saved; the next start must repair initial bootstrap.
            run(
                "exec",
                names["app"],
                "php",
                "-r",
                "$p=getenv('DATA_PATH').'/users/reader/config.php'; $c=require $p; "
                "$c['apiPasswordHash']=''; file_put_contents($p,'<?php return '.var_export($c,true).';'); "
                "@unlink(getenv('DATA_PATH').'/news-bootstrap.complete');",
            )
            # A stale saved policy must not retain an internal-fetch exception.
            run(
                "exec",
                names["app"],
                "php",
                "-r",
                "$p=getenv('DATA_PATH').'/config.php'; $c=require $p; "
                "$c['internal_host_allowlist']=['*']; "
                "file_put_contents($p,'<?php return '.var_export($c,true).';');",
            )
            # PID 1 is guaranteed to exist after restart; a stale pid file must
            # not be mistaken for a running Apache in the new container.
            run("exec", names["app"], "sh", "-c", "echo 1 > /run/news/httpd.pid")
            run("restart", names["app"])
            wait_ready()
            policy = run(
                "exec",
                names["app"],
                "php",
                "-r",
                "$c=require getenv('DATA_PATH').'/config.php'; "
                "echo json_encode($c['internal_host_allowlist']);",
            )
            assert json.loads(policy.stdout) == [], (
                "restart retained stale private-fetch allowance"
            )
            auth = ""

            def request(path, data=None, authenticated=True, base_url=None, authorization=None):
                credential = auth if authorization is None else authorization
                headers = (
                    {"Authorization": "GoogleLogin auth=" + credential}
                    if authenticated and credential
                    else {}
                )
                payload = (
                    urllib.parse.urlencode(data, doseq=True).encode() if data is not None else None
                )
                req = urllib.request.Request(
                    (base_url or base) + "/api/greader.php" + path, data=payload, headers=headers
                )
                try:
                    with urllib.request.urlopen(req, timeout=30) as response:
                        return response.status, response.read()
                except urllib.error.HTTPError as error:
                    return error.code, error.read()

            assert (
                request("/reader/api/0/subscription/list?output=json", authenticated=False)[0]
                == 401
            )
            assert (
                request("/accounts/ClientLogin", {"Email": "reader", "Passwd": "wrong"})[0] == 401
            )
            # The web password must not authenticate the synchronization API.
            assert (
                request(
                    "/accounts/ClientLogin",
                    {"Email": "reader", "Passwd": passwords["NEWS_OPERATOR_PASSWORD"]},
                )[0]
                == 401
            )
            status, body = request(
                "/accounts/ClientLogin",
                {"Email": "reader", "Passwd": passwords["NEWS_API_PASSWORD"]},
            )
            assert status == 200, "API login rejected correct credentials"
            auth = dict(line.split("=", 1) for line in body.decode().splitlines())["Auth"]
            token = request("/reader/api/0/token")[1].decode().strip()
            assert (
                json.loads(request("/reader/api/0/subscription/list?output=json")[1])[
                    "subscriptions"
                ]
                == []
            )
            for feed in ("full-feed.xml", "truncated-feed.xml"):
                status, body = request(
                    "/reader/api/0/subscription/quickadd",
                    {"quickadd": "http://news-fixtures:8000/" + feed},
                )
                assert status == 200 and json.loads(body)["numResults"] == 1, (
                    "fixture subscription failed"
                )
            subs = json.loads(request("/reader/api/0/subscription/list?output=json")[1])[
                "subscriptions"
            ]
            assert len(subs) == 2
            assert (
                request(
                    "/reader/api/0/subscription/edit",
                    {"s": subs[0]["id"], "ac": "edit", "a": "user/-/label/News"},
                )[0]
                == 200
            )
            categorized = json.loads(request("/reader/api/0/subscription/list?output=json")[1])[
                "subscriptions"
            ]
            assert any(c["label"] == "News" for s in categorized for c in s["categories"])

            def items():
                status, body = request(
                    "/reader/api/0/stream/contents/reading-list?output=json&n=100"
                )
                assert status == 200
                return json.loads(body)["items"]

            entries = items()
            assert len(entries) == 3, f"expected 3 fixture items, got {len(entries)}"
            full = next(item for item in entries if "figcaption" in item["summary"]["content"])
            content = full["summary"]["content"]
            assert "community garden" in content and "figcaption" in content and "<img" in content
            assert "<script" not in content and "onerror=" not in content
            identity = full["id"]
            assert (
                request(
                    "/reader/api/0/edit-tag",
                    {
                        "T": token,
                        "i": identity,
                        "a": ["user/-/state/com.google/read", "user/-/state/com.google/starred"],
                    },
                )[0]
                == 200
            )
            before = run("exec", names["feeds"], "cat", "/tmp/request-count").stdout
            run("exec", names["app"], "sh", "/opt/news/refresh.sh")
            run("exec", names["app"], "sh", "/opt/news/refresh.sh")
            after = run("exec", names["feeds"], "cat", "/tmp/request-count").stdout
            assert before == after, "normal polling fetched recently refreshed feeds again"
            healthy = metrics()
            assert healthy["news_feeds_active"] == 2 and healthy["news_feeds_failed"] == 0
            assert healthy["news_feeds_stale"] == 0
            assert healthy["news_feed_oldest_success_timestamp_seconds"] > 0
            assert healthy["news_refresh_last_completed_timestamp_seconds"] > 0
            assert {i["id"] for i in items()} == {i["id"] for i in entries}
            probe = (
                "require '/var/www/FreshRSS/cli/_cli.php'; "
                "$result=FreshRSS_http_Util::httpGet($argv[1]); "
                "echo json_encode(['fail'=>$result['fail'],'size'=>strlen($result['body']),"
                "'status'=>$result['status']]);"
            )
            for path in ("redirect-private", "redirect-loop", "oversized", "slow"):
                start = time.monotonic()
                result = run(
                    "exec", names["app"], "php", "-r", probe, "http://news-fixtures:8000/" + path
                )
                checked = json.loads(result.stdout)
                assert checked["fail"] or checked["status"] == 302, (
                    f"fetch limit did not reject {path}"
                )
                assert time.monotonic() - start < 20, "feed timeout was not bounded"
                assert checked["size"] <= 5242880
                if path == "redirect-loop":
                    counts = run(
                        "exec", names["feeds"], "cat", "/tmp/request-count"
                    ).stdout.splitlines()
                    assert counts.count(b"/redirect-loop") == 5, "redirect budget exceeded"
            rejected = run(
                "exec",
                "-e",
                "INTERNAL_HOST_ALLOWLIST=",
                names["app"],
                "php",
                "-r",
                probe,
                "http://news-fixtures:8000/full-feed.xml",
            )
            assert json.loads(rejected.stdout)["fail"], (
                "default policy allowed private feed target"
            )
            # A malformed feed cannot remove an existing subscription or article.
            request(
                "/reader/api/0/subscription/quickadd",
                {"quickadd": "http://news-fixtures:8000/malformed"},
            )
            assert len(items()) == 3
            assert (
                len(
                    json.loads(request("/reader/api/0/subscription/list?output=json")[1])[
                        "subscriptions"
                    ]
                )
                == 2
            )
            run("restart", names["app"])
            wait_ready()
            saved = next(i for i in items() if i["id"] == identity)
            assert any(c.endswith("/read") for c in saved["categories"])
            assert any(c.endswith("/starred") for c in saved["categories"])
            assert saved["summary"]["content"] == content
            backup_env = tmp / "backup.env"
            faults = tmp / "faults"
            write_fault_tools(faults)
            backup_env.touch(mode=0o600)
            backup_env.write_text(
                "PGHOST=news-postgresql\nPGDATABASE=freshrss\nPGUSER=news_backup\n"
                f"PGPASSWORD={passwords['BACKUP_PASSWORD']}\n"
                "DATA_PATH=/var/www/FreshRSS/data\nBACKUP_DIR=/backups\n"
                f"NEWS_APP_IMAGE={image}\nNEWS_DATABASE_IMAGE={db_image}\n"
            )
            container(
                names["backup"],
                "--user",
                "1000:1000",
                "--env-file",
                str(backup_env),
                "--tmpfs",
                "/tmp:rw,size=64m",
                "--tmpfs",
                "/small:rw,mode=1777,size=4096",
                "-v",
                str(faults) + ":/faults:ro",
                "-v",
                names["data"] + ":/var/www/FreshRSS/data:ro",
                "-v",
                names["runtime"] + ":/run/news:U",
                "-v",
                names["backups"] + ":/backups:U",
                "-v",
                str(APP / "scripts") + ":/opt/news:ro",
                "-v",
                str(APP / "httpd.conf") + ":/opt/news-httpd.conf:ro",
                "--entrypoint",
                "/bin/sh",
                db_image,
                "-c",
                "while :; do sleep 3600; done",
            )
            entries_before_backup = items()
            run("exec", names["backup"], "sh", "/opt/news/backup.sh")
            wait_ready()
            assert items() == entries_before_backup, "backup changed article state"
            assert metrics()["news_backup_last_success_timestamp_seconds"] > 0
            exercise_backup_failures(
                run=run,
                names=names,
                wait_ready=wait_ready,
                request=request,
                items=items,
                token=token,
                identity=identity,
                base_url=base,
            )
            before_outage = items()
            before_subscriptions = request("/reader/api/0/subscription/list?output=json")[1]
            # Make both synthetic feeds due and remove their cached responses.
            # Otherwise this test can pass without attempting a network fetch.
            run(
                "exec",
                names["app"],
                "php",
                "-r",
                "require '/var/www/FreshRSS/cli/_cli.php'; cliInitUser('reader'); "
                "$dao=FreshRSS_Factory::createFeedDao(); foreach ($dao->listFeeds() as $feed) { "
                "if (!$dao->updateFeed($feed->id(),['lastUpdate'=>1,'error'=>0])) exit(1); "
                "$cache=$feed->cacheFilename(); if (is_file($cache) && !unlink($cache)) exit(1); }",
            )
            run("stop", names["feeds"])
            run("exec", names["app"], "sh", "/opt/news/refresh.sh")
            failures = run(
                "exec",
                names["app"],
                "php",
                "-r",
                "require '/var/www/FreshRSS/cli/_cli.php'; cliInitUser('reader'); "
                "$feeds=FreshRSS_Factory::createFeedDao()->listFeeds(); "
                "echo json_encode(array_values(array_map(fn($f)=>$f->lastError(),$feeds)));",
            )
            errors = json.loads(failures.stdout)
            assert len(errors) == 2 and all(error > 0 for error in errors), (
                "outage test did not attempt failed feed fetches"
            )
            failed = metrics()
            assert failed["news_database_up"] == 1 and failed["news_feeds_failed"] == 2
            assert failed["news_feeds_stale"] == 2
            assert failed["news_feed_oldest_success_timestamp_seconds"] == 1
            assert failed["news_refresh_last_completed_timestamp_seconds"] > 1
            assert items() == before_outage, "feed outage changed saved content or state"
            assert (
                request("/reader/api/0/subscription/list?output=json")[1] == before_subscriptions
            )
            run("stop", names["db"])
            unavailable = metrics()
            assert unavailable["news_database_up"] == 0 and "news_feeds_active" not in unavailable
            assert (
                run("exec", names["app"], "php", "/opt/news/ready.php", success=False).returncode
                != 0
            )
            run("start", names["db"])
            wait_ready()
            assert len(items()) == 3
            for name in (names["app"], names["db"]):
                logs = run("logs", name)
                assert not any(
                    value.encode() in logs.stdout + logs.stderr for value in passwords.values()
                ), "runtime logged a password"
            exercise_restore(
                run=run,
                container=container,
                create=create,
                start_database=start_database,
                start_app=start_app,
                request=request,
                names=names,
                passwords=passwords,
                db_image=db_image,
                image=image,
                tmp=tmp,
                app_env=app_env,
                expected_items=entries_before_backup,
                expected_subscriptions=before_subscriptions,
            )
        print(
            "PASS: restricted FreshRSS, PostgreSQL, API authentication, feed bodies, categories, state, restart and failures"
        )
    finally:
        failed = []
        for kind, name in reversed(owned):
            result = run(kind, "inspect", name, success=False)
            if result.returncode:
                failed.append(name)
                continue
            obj = json.loads(result.stdout)[0]
            labels = (
                obj.get("Labels") or obj.get("labels") or obj.get("Config", {}).get("Labels", {})
            )
            if labels.get("homelab-talos.test-run") != marker:
                failed.append(name)
                continue
            args = ("rm", "-f", "--time", "0", name) if kind == "container" else (kind, "rm", name)
            if run(*args, success=False).returncode:
                failed.append(name)
        if failed:
            raise AssertionError("Owned local resources require cleanup: " + ", ".join(failed))


if __name__ == "__main__":
    main()
