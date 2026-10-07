"""Run extraction behavior in the published PHP image, never host PHP."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APP = Path(
    os.environ.get("NEWS_EXTRACTION_CANDIDATE", str(ROOT / "kubernetes/apps/news/graby/app"))
)
IMAGE = "docker.io/thecodingmachine/php:8.4-v5-cli@sha256:16aceb03a41e9da89f03a3a6d9ad08fb226af6cd1312bc4a0603452a37ff9399"


def container(command, *, network="none", app=APP, timeout=330, slow_dns=False, corpus=None):
    name = "news-extraction-" + secrets.token_hex(8)
    try:
        result = subprocess.run(
            [
                "podman",
                "run",
                "--rm",
                "--name",
                name,
                "--label",
                "homelab-talos.test-run=" + name,
                "--platform",
                "linux/amd64",
                "--read-only",
                "--user",
                "1000:1000",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--memory",
                "512m",
                "--pids-limit",
                "64",
                "--network",
                network,
                *(["--sysctl", "net.ipv4.ip_unprivileged_port_start=0"] if slow_dns else []),
                "--tmpfs",
                "/tmp:rw,size=256m",
                "--tmpfs",
                "/work:rw,mode=1777,size=512m",
                "--tmpfs",
                "/run/news-graby:rw,mode=1777,size=16m",
                "-v",
                str(ROOT) + ":/repo:ro",
                "-v",
                str(app) + ":/app:ro",
                *(
                    [
                        "-v",
                        str(ROOT / "tests/fixtures/news/extraction/resolv.conf")
                        + ":/etc/resolv.conf:ro",
                    ]
                    if slow_dns
                    else []
                ),
                *(["-v", str(corpus) + ":/corpus:ro"] if corpus is not None else []),
                "--entrypoint",
                "/bin/sh",
                json.loads((app / "release.json").read_text())["image"],
                "-c",
                command,
            ],
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    finally:
        subprocess.run(
            ["podman", "rm", "--force", name], capture_output=True, timeout=30, check=False
        )
    if result.returncode:
        raise AssertionError((result.stdout + result.stderr).decode(errors="replace")[-2400:])
    return result.stdout.decode()


def initialization():
    # Cold and warm starts, interrupted staging, absent Tidy, modified installed
    # rules, and real Composer script/plugin suppression use the production binary.
    with tempfile.TemporaryDirectory(prefix="init-", dir=ROOT / ".tmp") as temporary:
        app = Path(temporary) / "app"
        shutil.copytree(APP, app)
        composer = json.loads((app / "composer.json").read_text())
        composer["scripts"] = {"post-install-cmd": "touch /work/script-executed"}
        (app / "composer.json").write_text(json.dumps(composer))
        release = json.loads((app / "release.json").read_text())
        release.pop("id")
        release["files"]["composer.json"] = hashlib.sha256(
            (app / "composer.json").read_bytes()
        ).hexdigest()
        release["id"] = hashlib.sha256(
            json.dumps(release, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        (app / "release.json").write_text(json.dumps(release))
        print(
            container(
                """set -eu
mkdir /work/staging-interrupted
if /usr/bin/php8.4 -d extension=tidy /app/scripts/ready.php; then exit 1; fi
sh /app/scripts/initialize.sh
test ! -e /work/script-executed
sh /app/scripts/initialize.sh
/usr/bin/php8.4 -d extension=tidy /app/scripts/ready.php
if /usr/bin/php8.4 /app/scripts/ready.php; then exit 1; fi
printf altered > /work/current/rules/arstechnica.com.txt
if /usr/bin/php8.4 -d extension=tidy /app/scripts/ready.php; then exit 1; fi
echo cold-warm-tamper-platform-passed
""",
                network="bridge",
                app=app,
            ),
            end="",
        )
        for name in ("composer.json", "composer.lock"):
            shutil.copyfile(
                ROOT / "tests/fixtures/news/extraction/plugin-install" / name, app / name
            )
        release.pop("id")
        for name in ("composer.json", "composer.lock"):
            release["files"][name] = hashlib.sha256((app / name).read_bytes()).hexdigest()
        release["id"] = hashlib.sha256(
            json.dumps(release, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        (app / "release.json").write_text(json.dumps(release))
        output = container(
            """set -eu
if sh /app/scripts/initialize.sh; then exit 1; fi
test ! -e /work/script-executed
test ! -e /work/plugin-executed
test ! -e /work/current
echo synthetic-plugin-script-suppression-passed
""",
            network="bridge",
            app=app,
        )
        assert output.count("installation_attempt") == 1, (
            "synthetic package installation did not succeed"
        )
        print(output, end="")
    print(
        container("""set -eu
sh /app/scripts/initialize.sh & child=$!
sleep 1
kill -TERM "$child"
wait "$child" && exit 1
if /usr/bin/php8.4 -d extension=tidy /app/scripts/ready.php; then exit 1; fi
echo interrupted-install-passed
"""),
        end="",
    )
    output = container("""set -eu
if sh /app/scripts/initialize.sh; then exit 1; fi
if /usr/bin/php8.4 -d extension=tidy /app/scripts/ready.php; then exit 1; fi
echo package-outage-fallback-passed
""")
    assert 1 <= output.count("installation_attempt") <= 2, (
        "outage did not exercise locked installation"
    )
    print(output, end="")


def record_evidence(phase):
    release = json.loads((APP / "release.json").read_text())
    report = {
        "schema": 1,
        "phase": phase,
        "status": "pass",
        "release_id": release["id"],
        "rules_commit": release["rules"]["commit"],
    }
    if phase == "runtime":
        report["checks"] = ["fetch", "extraction", "service"]
    run = os.environ.get("HOMELAB_TEST_RUN_DIR")
    if run:
        target = Path(run) / "diagnostics" / ("news-extraction-" + phase + ".json")
        target.write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--phase",
        choices=(
            "initialization",
            "fetch",
            "extraction",
            "service",
            "ingestion",
            "recovery",
            "all",
        ),
        default="all",
    )
    args = parser.parse_args()
    if args.phase in ("ingestion", "recovery"):
        from freshrss_integration import main as freshrss

        freshrss(
            extraction=args.phase == "ingestion", extraction_recovery=args.phase == "recovery"
        )
        record_evidence(args.phase)
        return
    assert (APP / "scripts/initialize.sh").is_file(), "release initializer is missing"
    print(
        container(
            (
                "sh /app/scripts/initialize.sh && "
                if args.phase in ("extraction", "service", "all")
                else ""
            )
            + "/usr/bin/php8.4 -d extension=tidy /repo/scripts/test/news/extraction-tests.php "
            + args.phase,
            network="bridge"
            if args.phase in ("fetch", "extraction", "service", "all")
            else "none",
        ),
        end="",
    )
    if args.phase in ("initialization", "all"):
        initialization()
    if args.phase in ("fetch", "all"):
        print(
            container(
                "/usr/bin/php8.4 /repo/scripts/test/news/extraction-dns-tests.php", slow_dns=True
            ),
            end="",
        )
    if args.phase in ("initialization", "all"):
        record_evidence("initialization")
    if args.phase == "all":
        record_evidence("runtime")
        from freshrss_integration import main as freshrss

        freshrss(extraction=True)
        record_evidence("ingestion")


if __name__ == "__main__":
    main()
