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
        for kind in ("app", "db", "feeds", "scheduler", "network", "data", "dbdata")
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

    def wait_ready():
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            ready = run("exec", names["app"], "php", "/opt/news/ready.php", success=False)
            if ready.returncode == 0:
                return
            time.sleep(1)
        logs = run("logs", names["app"], success=False)
        diagnostic = (logs.stdout + logs.stderr).decode(errors="replace")
        for value in passwords.values():
            diagnostic = diagnostic.replace(value, "[redacted]")
        raise AssertionError("FreshRSS not ready: " + diagnostic[-2000:])

    try:
        run("info")
        run("pull", "--platform", "linux/amd64", image)
        run("pull", "--platform", "linux/amd64", db_image)
        create("network", names["network"], "--internal")
        for key in ("data", "dbdata"):
            create("volume", names[key])
        with tempfile.TemporaryDirectory(prefix="news-runtime-") as temporary:
            tmp = Path(temporary)
            # Exercise the real supervisor/refresh scripts with fast, controlled
            # child commands: a transient refresh failure must not kill scheduling.
            fakebin = tmp / "bin"
            fakebin.mkdir()
            commands = {
                "sleep": "exec /bin/sleep 0.05\n",
                "php": 'case "$1" in */bootstrap.php) exit 0;; esac\n'
                "if [ ! -f /tmp/attempt ]; then touch /tmp/attempt; exit 1; fi\n"
                "touch /tmp/refreshed\n",
                "httpd": 'i=0\nwhile [ "$i" -lt 40 ]; do\n'
                "  [ ! -f /tmp/refreshed ] || exit 0\n"
                "  /bin/sleep 0.05; i=$((i+1))\ndone\nexit 3\n",
            }
            for name, body in commands.items():
                path = fakebin / name
                path.write_text("#!/bin/sh\n" + body)
                path.chmod(0o755)
            container(
                names["scheduler"],
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
                "--entrypoint",
                "/bin/sh",
                image,
                "/opt/news/start.sh",
            )
            assert run("wait", names["scheduler"], timeout=15).stdout.strip() == b"0", (
                "refresh scheduler stopped after a failed refresh"
            )
            db_env = tmp / "db.env"
            db_env.touch(mode=0o600)
            db_env.write_text(
                "\n".join(f"{k}={v}" for k, v in passwords.items())
                + "\nPOSTGRES_DB=postgres\nPGDATA=/var/lib/postgresql/data/pgdata\n"
                "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=trust\n"
            )
            container(
                names["db"],
                "--user",
                "70:70",
                "--env-file",
                str(db_env),
                "--network-alias",
                "news-postgresql",
                "--tmpfs",
                "/var/run/postgresql:rw,mode=1777,size=16m",
                "--tmpfs",
                "/tmp:rw,size=64m",
                "-v",
                names["dbdata"] + ":/var/lib/postgresql/data:U",
                "-v",
                str(DB / "scripts") + ":/docker-entrypoint-initdb.d:ro",
                db_image,
            )
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if (
                    run(
                        "exec", names["db"], "pg_isready", "-U", "postgres", success=False
                    ).returncode
                    == 0
                ):
                    break
                time.sleep(1)
            else:
                raise AssertionError("database startup timed out")
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

            def start_app():
                container(
                    names["app"],
                    "--user",
                    "1000:1000",
                    "--env-file",
                    str(app_env),
                    "--tmpfs",
                    "/tmp:rw,size=128m",
                    "--tmpfs",
                    "/run/news:rw,mode=1777,size=16m",
                    "-v",
                    names["data"] + ":/var/www/FreshRSS/data:U",
                    "-v",
                    str(APP / "scripts") + ":/opt/news:ro",
                    "-v",
                    str(APP / "httpd.conf") + ":/opt/news-httpd.conf:ro",
                    "-p",
                    "127.0.0.1::8080",
                    "--entrypoint",
                    "/bin/sh",
                    image,
                    "/opt/news/start.sh",
                )
                wait_ready()
                port = (
                    run("port", names["app"], "8080/tcp").stdout.decode().strip().rsplit(":", 1)[1]
                )
                return "http://127.0.0.1:" + port

            base = start_app()
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

            def request(path, data=None, authenticated=True):
                headers = (
                    {"Authorization": "GoogleLogin auth=" + auth} if authenticated and auth else {}
                )
                payload = (
                    urllib.parse.urlencode(data, doseq=True).encode() if data is not None else None
                )
                req = urllib.request.Request(
                    base + "/api/greader.php" + path, data=payload, headers=headers
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
            run("stop", names["feeds"])
            run("exec", names["app"], "sh", "/opt/news/refresh.sh")
            assert len(items()) == 3, "feed outage dropped stored items"
            run("stop", names["db"])
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
            args = ("rm", "-f", name) if kind == "container" else (kind, "rm", name)
            if run(*args, success=False).returncode:
                failed.append(name)
        if failed:
            raise AssertionError("Owned local resources require cleanup: " + ", ".join(failed))


if __name__ == "__main__":
    main()
