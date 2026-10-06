"""Disposable amd64 PostgreSQL acceptance for the deployed bootstrap and restrictions."""

from __future__ import annotations

import secrets
import subprocess
import tempfile
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "kubernetes/apps/news/postgresql/app"
INIT = APP / "scripts/init-news.sh"


def main():
    if not INIT.is_file():
        raise AssertionError("news role/database bootstrap is missing")
    stateful = yaml.safe_load((APP / "statefulset.yaml").read_text())
    image = stateful["spec"]["template"]["spec"]["containers"][0]["image"]
    marker = "news-db-" + secrets.token_hex(8)
    container, volume = marker + "-postgres", marker + "-data"
    label = "homelab-talos.test-run=" + marker
    owned = []
    passwords = {
        role: secrets.token_hex(24)
        for role in (
            "POSTGRES_PASSWORD",
            "FRESHRSS_PASSWORD",
            "BACKUP_PASSWORD",
            "MONITORING_PASSWORD",
        )
    }

    def run(*args, input=None, success=True):
        result = subprocess.run(
            ["podman", *args], input=input, capture_output=True, timeout=180, check=False
        )
        if success and result.returncode:
            diagnostic = result.stderr.decode(errors="replace")
            for password in passwords.values():
                diagnostic = diagnostic.replace(password, "[redacted]")
            raise AssertionError(f"Podman operation failed: {args[0]}: {diagnostic[-800:]}")
        # No generated password may leave this process through test output.
        return result

    def sql(statement, role="postgres", database="freshrss", success=True):
        result = run(
            "exec",
            "-i",
            container,
            "sh",
            "-c",
            'case "$1" in freshrss) export PGPASSWORD="$FRESHRSS_PASSWORD";; '
            'news_backup) export PGPASSWORD="$BACKUP_PASSWORD";; '
            'news_monitoring) export PGPASSWORD="$MONITORING_PASSWORD";; '
            'postgres) export PGPASSWORD="$POSTGRES_PASSWORD";; esac; '
            'exec psql -X -h 127.0.0.1 -U "$1" -d "$2" -At -v ON_ERROR_STOP=1',
            "sql",
            role,
            database,
            input=statement.encode(),
            success=success,
        )
        return result

    def wait():
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            result = sql("SELECT 1;", success=False)
            if result.returncode == 0 and result.stdout.strip() == b"1":
                return
            time.sleep(1)
        raise AssertionError("news database did not become ready within 90 seconds")

    def start(envfile):
        run(
            "run",
            "-d",
            "--name",
            container,
            "--label",
            label,
            "--platform",
            "linux/amd64",
            "--network",
            "none",
            "--user",
            "70:70",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--memory",
            "1g",
            "--env-file",
            str(envfile),
            "--tmpfs",
            "/tmp:rw,nosuid,nodev,size=64m",
            "--tmpfs",
            "/var/run/postgresql:rw,nosuid,nodev,mode=1777,size=16m",
            "-v",
            volume + ":/var/lib/postgresql/data:U",
            "-v",
            str(INIT.parent) + ":/docker-entrypoint-initdb.d:ro",
            image,
        )
        owned.append(("container", container))
        wait()

    try:
        run("info")
        run("pull", "--platform", "linux/amd64", image)
        run("volume", "create", "--label", label, volume)
        owned.append(("volume", volume))
        with tempfile.TemporaryDirectory(prefix="news-postgresql-") as temporary:
            envfile = Path(temporary) / "environment"
            envfile.touch(mode=0o600)
            envfile.write_text(
                "\n".join(f"{key}={value}" for key, value in passwords.items())
                + "\nPOSTGRES_DB=postgres\nPOSTGRES_USER=postgres\n"
                "PGDATA=/var/lib/postgresql/data/pgdata\n"
                "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=trust\n"
            )
            start(envfile)
            assert sql("SELECT current_user;", role="freshrss").stdout.strip() == b"freshrss"
            sql(
                "CREATE TABLE acceptance (id int PRIMARY KEY, body text);"
                "INSERT INTO acceptance VALUES (1, 'synthetic article');",
                role="freshrss",
            )
            assert (
                sql("SELECT body FROM acceptance;", role="news_backup").stdout.strip()
                == b"synthetic article"
            )
            assert (
                sql(
                    "UPDATE acceptance SET body='unauthorized';", role="news_backup", success=False
                ).returncode
                != 0
            )
            assert (
                sql(
                    "CREATE TABLE forbidden(id int);", role="news_backup", success=False
                ).returncode
                != 0
            )
            assert (
                sql("SELECT * FROM acceptance;", role="news_monitoring", success=False).returncode
                != 0
            )
            assert (
                sql(
                    "SELECT pg_has_role(current_user, 'pg_monitor', 'MEMBER');",
                    role="news_monitoring",
                ).stdout.strip()
                == b"t"
            )
            assert (
                sql("SELECT 1;", role="freshrss", database="postgres", success=False).returncode
                != 0
            )
            assert sql("CREATE ROLE forbidden;", role="freshrss", success=False).returncode != 0
            # Re-run the real bootstrap: no duplicate-role/database failure or data loss.
            run("exec", container, "sh", "/docker-entrypoint-initdb.d/init-news.sh")
            assert (
                sql("SELECT body FROM acceptance;", role="freshrss").stdout.strip()
                == b"synthetic article"
            )
            run("restart", container)
            wait()
            assert (
                sql("SELECT body FROM acceptance;", role="freshrss").stdout.strip()
                == b"synthetic article"
            )
            # Recreate the Pod equivalent using the same retained database volume.
            run("rm", "-f", container)
            owned.remove(("container", container))
            start(envfile)
            assert (
                sql("SELECT body FROM acceptance;", role="freshrss").stdout.strip()
                == b"synthetic article"
            )
            # Bootstrap into a separate empty database verifies deterministic ownership.
            sql("DROP DATABASE freshrss WITH (FORCE);", database="postgres")
            run("exec", container, "sh", "/docker-entrypoint-initdb.d/init-news.sh")
            sql("CREATE TABLE restored(id int);", role="freshrss")
            assert (
                sql("SELECT tableowner FROM pg_tables WHERE tablename='restored';").stdout.strip()
                == b"freshrss"
            )
            logs = run("logs", container).stdout
            assert not any(value.encode() in logs for value in passwords.values()), (
                "bootstrap logged a password"
            )
        print(
            "PASS: amd64 restricted PostgreSQL; roles, idempotency, restart, recreation and ownership"
        )
    finally:
        failures = []
        for kind, name in reversed(owned):
            result = run(kind, "inspect", name, success=False)
            if result.returncode:
                failures.append(name)
                continue
            objects = __import__("json").loads(result.stdout)
            labels = (
                objects[0].get("Labels")
                if kind == "volume"
                else objects[0]["Config"].get("Labels")
            )
            if not labels or labels.get("homelab-talos.test-run") != marker:
                failures.append(name)
                continue
            result = (
                run("rm", "-f", name, success=False)
                if kind == "container"
                else run("volume", "rm", name, success=False)
            )
            if result.returncode:
                failures.append(name)
        if failures:
            raise AssertionError(
                "Owned local test resources require cleanup: " + ", ".join(failures)
            )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, subprocess.TimeoutExpired, OSError) as error:
        print(f"FAIL: {error}")
        raise SystemExit(1)
