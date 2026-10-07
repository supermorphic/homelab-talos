"""Run-owned synthetic recovery resources; never consumes production credentials."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "kubernetes/apps/news/freshrss/app"
DB = ROOT / "kubernetes/apps/news/postgresql/app"
NAMESPACE = "news-recovery-test"
CONFIRMATION = "restore:news:disposable"
LABEL = "homelab-talos/run-id"
FAMILY = "news-restore-drill"


def prefix(run):
    if not re.fullmatch(r"[0-9a-f]{12}", run):
        raise ValueError("invalid recovery run")
    return "news-drill-" + run


def metadata(run, suffix):
    return {
        "name": prefix(run) + "-" + suffix,
        "namespace": NAMESPACE,
        "labels": {LABEL: run, "homelab-talos/test": FAMILY},
    }


def images():
    app = yaml.safe_load((APP / "deployment.yaml").read_text())
    db = yaml.safe_load((DB / "statefulset.yaml").read_text())
    return (
        app["spec"]["template"]["spec"]["containers"][0]["image"],
        db["spec"]["template"]["spec"]["containers"][0]["image"],
    )


def config_data():
    data = {p.name: p.read_text() for p in sorted((APP / "scripts").iterdir())}
    data["release.json"] = (ROOT / "kubernetes/apps/news/graby/app/release.json").read_text()
    data.update(
        {
            p.name: p.read_text()
            for p in sorted((APP / "extensions/xExtension-CommunityExtraction").iterdir())
            if p.is_file()
        }
    )
    data["httpd.conf"] = (APP / "httpd.conf").read_text()
    data["init-news.sh"] = (DB / "scripts/init-news.sh").read_text()
    for name in ("drill-start.sh", "drill-helper.sh", "drill.php"):
        data[name] = (Path(__file__).parent / name).read_text()
    for name in ("full-feed.xml", "truncated-feed.xml"):
        data[name] = (ROOT / "tests/fixtures/news" / name).read_text()
    return data


def resources(run):
    result = []
    for suffix in ("source-db", "source-data", "backups", "restored-db", "restored-data"):
        result.append(
            {
                "apiVersion": "v1",
                "kind": "PersistentVolumeClaim",
                "metadata": metadata(run, suffix),
                "spec": {
                    "storageClassName": "longhorn",
                    "accessModes": ["ReadWriteOnce"],
                    "resources": {"requests": {"storage": "1Gi"}},
                },
            }
        )
    result.append(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": metadata(run, "credentials"),
            "type": "Opaque",
            "immutable": True,
            "stringData": {
                key: secrets.token_hex(24)
                for key in (
                    "postgres-password",
                    "db-password",
                    "backup-password",
                    "monitoring-password",
                    "operator-password",
                    "api-password",
                )
            },
        }
    )
    result.append(
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": metadata(run, "scripts"),
            "immutable": True,
            "data": config_data(),
        }
    )
    return result


def pod(run, phase, selected="", *, avoid_node=""):
    name = prefix(run)
    if (
        phase not in {"source", "reattached", "restored"}
        or (phase == "restored" and not re.fullmatch(r"set-[0-9]{10}-[A-Za-z0-9]{6}", selected))
        or (phase != "restored" and selected)
        or (
            phase == "reattached"
            and (
                len(avoid_node) > 253
                or not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", avoid_node)
            )
        )
        or (phase != "reattached" and avoid_node)
    ):
        raise ValueError("invalid recovery phase or set")
    app_image, db_image = images()
    storage_phase = "restored" if phase == "restored" else "source"

    def env(**values):
        return [
            {"name": key, **({"value": value} if value else {})} for key, value in values.items()
        ]

    def credential(variable, key):
        return {
            "name": variable,
            "valueFrom": {
                "secretKeyRef": {
                    "name": name + "-credentials",
                    "key": key,
                }
            },
        }

    def mount(volume, path, read_only=False):
        item = {"name": volume, "mountPath": path}
        if read_only:
            item["readOnly"] = True
        return item

    def container(kind, image, uid, memory, command, environment, mounts):
        return {
            "name": kind,
            "image": image,
            "imagePullPolicy": "IfNotPresent",
            "command": command,
            "env": environment,
            "volumeMounts": mounts,
            "resources": {
                "requests": {"cpu": "50m", "memory": "128Mi"},
                "limits": {"cpu": "1", "memory": memory},
            },
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": uid,
                "runAsGroup": uid,
                "allowPrivilegeEscalation": False,
                "readOnlyRootFilesystem": True,
                "capabilities": {"drop": ["ALL"]},
            },
        }

    scripts = mount("scripts", "/opt/news", True)
    runtime = mount("runtime", "/run/news")
    app = container(
        "app",
        app_image,
        1000,
        "1Gi",
        ["sh", "/opt/news/drill-start.sh", storage_phase],
        env(
            NEWS_DB_HOST="127.0.0.1",
            NEWS_OPERATOR_NAME="reader",
            NEWS_BASE_URL="http://localhost:8080",
            DATA_PATH="/var/www/FreshRSS/data/instance",
            INTERNAL_HOST_ALLOWLIST="127.0.0.1:8080",
            NEWS_POLLING_ENABLED="false",
        )
        + [
            credential(k, v)
            for k, v in (
                ("NEWS_DB_PASSWORD", "db-password"),
                ("NEWS_OPERATOR_PASSWORD", "operator-password"),
                ("NEWS_API_PASSWORD", "api-password"),
            )
        ],
        [
            scripts,
            mount("extraction-release", "/opt/news-extraction", True),
            mount("extraction-extension", "/opt/news-extraction/extension", True),
            mount(
                "extraction-extension",
                "/var/www/FreshRSS/extensions/xExtension-CommunityExtraction",
                True,
            ),
            runtime,
            mount("app-data", "/var/www/FreshRSS/data"),
            mount("app-tmp", "/tmp"),
            {**mount("httpd", "/opt/news-httpd.conf", True), "subPath": "httpd.conf"},
            {
                **mount("fixtures", "/var/www/FreshRSS/p/full-feed.xml", True),
                "subPath": "full-feed.xml",
            },
            {
                **mount("fixtures", "/var/www/FreshRSS/p/truncated-feed.xml", True),
                "subPath": "truncated-feed.xml",
            },
        ],
    )
    app["readinessProbe"] = {
        "exec": {"command": ["php", "/opt/news/ready.php"]},
        "timeoutSeconds": 1,
        "successThreshold": 1,
        "periodSeconds": 5,
        "failureThreshold": 120,
    }
    db = container(
        "database",
        db_image,
        70,
        "1Gi",
        ["docker-entrypoint.sh", "postgres", "-c", "listen_addresses=127.0.0.1"],
        env(
            POSTGRES_DB="postgres",
            POSTGRES_USER="postgres",
            PGDATA="/var/lib/postgresql/data/pgdata",
            POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256 --auth-local=trust",
        )
        + [
            credential(k, v)
            for k, v in (
                ("POSTGRES_PASSWORD", "postgres-password"),
                ("FRESHRSS_PASSWORD", "db-password"),
                ("BACKUP_PASSWORD", "backup-password"),
                ("MONITORING_PASSWORD", "monitoring-password"),
            )
        ],
        [
            mount("database-data", "/var/lib/postgresql/data"),
            mount("pg-run", "/var/run/postgresql"),
            mount("db-tmp", "/tmp"),
            mount("init", "/docker-entrypoint-initdb.d", True),
        ],
    )
    helper = container(
        "helper",
        db_image,
        1000,
        "256Mi",
        ["sh", "/opt/news/drill-helper.sh", storage_phase],
        env(
            PGHOST="127.0.0.1",
            PGDATABASE="freshrss",
            PGUSER="news_backup" if phase != "restored" else "freshrss",
            DATA_PATH="/data/instance",
            BACKUP_DIR="/backups/news",
            NEWS_SELECTED_SET=selected,
            NEWS_APP_IMAGE=app_image,
            NEWS_DATABASE_IMAGE=db_image,
        )
        + [credential("PGPASSWORD", "backup-password" if phase != "restored" else "db-password")],
        [
            scripts,
            mount("extraction-release", "/opt/news-extraction", True),
            mount("extraction-extension", "/opt/news-extraction/extension", True),
            runtime,
            mount("app-data", "/data", phase != "restored"),
            mount("backups", "/backups", phase == "restored"),
            mount("helper-tmp", "/tmp"),
            {**mount("httpd", "/opt/news-httpd.conf", True), "subPath": "httpd.conf"},
        ],
    )
    volumes = [
        {
            "name": "app-data",
            "persistentVolumeClaim": {"claimName": name + "-" + storage_phase + "-data"},
        },
        {
            "name": "database-data",
            "persistentVolumeClaim": {"claimName": name + "-" + storage_phase + "-db"},
        },
        {
            "name": "backups",
            "persistentVolumeClaim": {
                "claimName": name + "-backups",
                **({"readOnly": True} if phase == "restored" else {}),
            },
        },
    ]
    for volume, keys in (
        ("scripts", list(config_data())),
        ("extraction-release", ["release.json"]),
        (
            "extraction-extension",
            [
                p.name
                for p in sorted((APP / "extensions/xExtension-CommunityExtraction").iterdir())
                if p.is_file()
            ],
        ),
        ("httpd", ["httpd.conf"]),
        ("fixtures", ["full-feed.xml", "truncated-feed.xml"]),
        ("init", ["init-news.sh"]),
    ):
        volumes.append(
            {
                "name": volume,
                "configMap": {
                    "name": name + "-scripts",
                    "defaultMode": 292,
                    "items": [{"key": key, "path": key} for key in keys],
                },
            }
        )
    volumes.extend(
        {"name": volume, "emptyDir": {"sizeLimit": "128Mi"}}
        for volume in (
            "runtime",
            "app-tmp",
            "db-tmp",
            "helper-tmp",
            "pg-run",
        )
    )
    result = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": metadata(run, phase),
        "spec": {
            "automountServiceAccountToken": False,
            "enableServiceLinks": False,
            "restartPolicy": "Never",
            "activeDeadlineSeconds": 1800,
            "terminationGracePeriodSeconds": 30,
            "securityContext": {"fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [app, db, helper],
            "volumes": volumes,
        },
    }
    if phase == "reattached":
        result["spec"]["affinity"] = {
            "nodeAffinity": {
                "requiredDuringSchedulingIgnoredDuringExecution": {
                    "nodeSelectorTerms": [
                        {
                            "matchFields": [
                                {
                                    "key": "metadata.name",
                                    "operator": "NotIn",
                                    "values": [avoid_node],
                                }
                            ]
                        }
                    ]
                }
            }
        }
    return result


class Cluster:
    def __init__(self, config, directory):
        self.config, self.directory = config, directory
        self.run = hashlib.sha256(directory.name.encode()).hexdigest()[:12]
        self.ledger = directory / "diagnostics/news-owned.jsonl"
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        if self.ledger.exists():
            raise ValueError("refusing an existing ownership ledger")
        self.kc = [
            "kubectl",
            "--kubeconfig",
            str(config),
            "--namespace",
            NAMESPACE,
            "--request-timeout=20s",
        ]

    def call(self, argv, *, content=None, timeout=60):
        result = subprocess.run(
            argv, input=content, capture_output=True, text=True, timeout=timeout, check=False
        )
        if result.returncode:
            raise RuntimeError("scoped recovery operation failed")
        return result.stdout

    def owned(self, operation, *args, content=None):
        if operation == "create":
            command = 'source scripts/test/lib/owned-resources.sh; test_create_owned_stream "$1" kubectl --kubeconfig "$2" --namespace news-recovery-test'
        else:
            command = 'source scripts/test/lib/owned-resources.sh; test_delete_owned "$1" "$3" news-recovery-test "$4" kubectl --kubeconfig "$2" --namespace news-recovery-test'
        return self.call(
            [
                "bash",
                "-eu",
                "-c",
                command,
                "news-owned",
                str(self.ledger),
                str(self.config),
                *args,
            ],
            content=content,
            timeout=360,
        )

    def preflight(self):
        self.call(
            [
                "bash",
                "-eu",
                "-c",
                'source scripts/lib/lease.sh; verify_test_lease_holder "$1" "$2"',
                "news-lease",
                str(self.config),
                os.environ.get("TEST_CAMPAIGN_LEASE_HOLDER") or self.directory.name,
            ]
        )
        namespace = json.loads(
            self.call(self.kc + ["get", "namespace", NAMESPACE, "--output=json"])
        )
        if (
            namespace["metadata"]["labels"].get("pod-security.kubernetes.io/enforce")
            != "restricted"
        ):
            raise ValueError("recovery namespace is not restricted")
        policy = json.loads(
            self.call(self.kc + ["get", "ciliumnetworkpolicy", "isolation", "--output=json"])
        )
        if policy["spec"] != {
            "endpointSelector": {},
            "ingressDeny": [{"fromEntities": ["all"]}],
            "egressDeny": [{"toEntities": ["all"]}],
        }:
            raise ValueError("recovery network baseline changed")
        quota = json.loads(
            self.call(self.kc + ["get", "resourcequota", "recovery", "--output=json"])
        )
        baseline = list(
            yaml.safe_load_all(
                (ROOT / "kubernetes/apps/news/recovery/app/namespace.yaml").read_text()
            )
        )
        if (
            quota["spec"]["hard"]
            != next(o for o in baseline if o["kind"] == "ResourceQuota")["spec"]["hard"]
        ):
            raise ValueError("recovery resource baseline changed")

    def create_inputs(self):
        self.owned("create", content=json.dumps(resources(self.run)))

    def create_pod(self, phase, selected="", *, avoid_node=""):
        self.owned(
            "create", content=json.dumps(pod(self.run, phase, selected, avoid_node=avoid_node))
        )
        self.call(
            self.kc
            + [
                "wait",
                "--for=condition=Ready",
                "pod/" + prefix(self.run) + "-" + phase,
                "--timeout=660s",
            ],
            timeout=690,
        )

    def execute(self, phase, expected=None):
        command = self.kc + ["exec"]
        if expected is not None:
            command.append("--stdin")
        command += [
            prefix(self.run) + "-" + phase,
            "--container=app",
            "--",
            "php",
            "/opt/news/drill.php",
            phase,
        ]
        result = self.call(
            command, content=None if expected is None else json.dumps(expected), timeout=900
        )
        if phase == "source":
            state = json.loads(result)
            helper = self.kc + [
                "exec",
                prefix(self.run) + "-source",
                "--container=helper",
                "--",
                "sh",
                "/opt/news/drill-helper.sh",
            ]
            self.preflight()
            self.call(helper + ["capture"])
            deadline = time.monotonic() + 660
            while True:
                captured = subprocess.run(
                    helper + ["captured"], capture_output=True, text=True, timeout=30, check=False
                )
                if captured.returncode == 0:
                    selected = captured.stdout.strip()
                    if not re.fullmatch(r"set-[0-9]{10}-[A-Za-z0-9]{6}", selected):
                        raise ValueError("invalid paired capture name")
                    return json.dumps({"set": selected, **state})
                if captured.returncode != 75 or time.monotonic() >= deadline:
                    raise RuntimeError("paired capture did not finish")
                time.sleep(1)
        return result

    def snapshot(self, phase):
        name = prefix(self.run) + "-" + phase
        records = [json.loads(line) for line in self.ledger.read_text().splitlines()]
        recorded = [r for r in records if r["kind"] == "Pod" and r["metadata"]["name"] == name]
        if len(recorded) != 1:
            raise RuntimeError("fixture Pod ownership is not recorded")
        current = json.loads(self.call(self.kc + ["get", "pod", name, "--output=json"]))
        if any(
            current["metadata"].get(k) != recorded[0]["metadata"].get(k)
            for k in ("name", "namespace", "uid", "labels")
        ):
            raise RuntimeError("fixture Pod ownership changed")
        return current

    def database_outage(self):
        self.preflight()
        source = self.snapshot("source")
        node = source.get("spec", {}).get("nodeName", "")
        # Use the constructor's bounded node validation before stopping anything.
        pod(self.run, "reattached", avoid_node=node)
        database = next(
            c for c in source["status"]["containerStatuses"] if c["name"] == "database"
        )
        if "running" not in database.get("state", {}):
            raise RuntimeError("disposable database was not running before the outage")
        self.call(
            self.kc
            + [
                "exec",
                prefix(self.run) + "-source",
                "--container=database",
                "--",
                "pg_ctl",
                "--pgdata=/var/lib/postgresql/data/pgdata",
                "--mode=fast",
                "--no-wait",
                "stop",
            ],
            timeout=90,
        )
        # Waiting pg_ctl can be killed along with PID1 before its exec result is
        # returned. Request shutdown first, then independently observe completion.
        deadline = time.monotonic() + 60
        while True:
            current = self.snapshot("source")
            database = next(
                c for c in current["status"]["containerStatuses"] if c["name"] == "database"
            )
            terminated = database.get("state", {}).get("terminated")
            if terminated is not None:
                if terminated.get("exitCode") != 0:
                    raise RuntimeError("disposable database did not shut down cleanly")
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("disposable database shutdown timed out")
            time.sleep(1)
        self.preflight()
        self.snapshot("source")
        self.call(
            self.kc
            + [
                "exec",
                prefix(self.run) + "-source",
                "--container=app",
                "--",
                "php",
                "/opt/news/drill.php",
                "unavailable",
            ],
            timeout=30,
        )
        return node

    def verify_reattached(self, expected, old_node):
        current = self.snapshot("reattached")
        node = current.get("spec", {}).get("nodeName", "")
        if not node or node == old_node:
            raise RuntimeError("source claims were not rescheduled to a different node")
        self.execute("reattached", expected)

    def delete_source(self):
        self.owned("delete", "Pod", prefix(self.run) + "-source")

    def delete_reattached(self):
        self.owned("delete", "Pod", prefix(self.run) + "-reattached")

    def cleanup(self):
        failures = 0
        if self.ledger.exists():
            for line in reversed(self.ledger.read_text().splitlines()):
                record = json.loads(line)
                try:
                    self.owned("delete", record["kind"], record["metadata"]["name"])
                except (RuntimeError, OSError, subprocess.SubprocessError):
                    failures += 1
        if failures:
            raise RuntimeError("recorded resource cleanup did not finish")


def run_drill(client):
    from scripts.test.scenarios.resilience_support import atomic_write_json

    outcome = {
        "assertions": "failed",
        "cleanup": "pending",
        "off_cluster": "not-tested",
        "database_outage": "not-tested",
        "storage_rescheduling": "not-tested",
        "phase": "preflight",
    }
    try:
        client.preflight()
        outcome["phase"] = "inputs"
        client.create_inputs()
        outcome["phase"] = "source-start"
        client.preflight()
        client.create_pod("source")
        outcome["phase"] = "capture"
        client.preflight()
        expected = json.loads(client.execute("source"))
        if set(expected) != {
            "set",
            "items_sha256",
            "subscriptions_sha256",
            "articles",
            "subscriptions",
        } or (
            not re.fullmatch(r"set-[0-9]{10}-[A-Za-z0-9]{6}", expected["set"])
            or any(
                not re.fullmatch(r"[0-9a-f]{64}", expected[key])
                for key in ("items_sha256", "subscriptions_sha256")
            )
            or expected["articles"] != 3
            or expected["subscriptions"] != 2
        ):
            raise ValueError("invalid synthetic capture outcome")
        outcome["phase"] = "database-outage"
        client.preflight()
        old_node = client.database_outage()
        outcome["database_outage"] = "passed"
        outcome["phase"] = "reattach-source"
        client.preflight()
        client.delete_source()
        client.preflight()
        client.create_pod("reattached", avoid_node=old_node)
        outcome["phase"] = "verify-reattached"
        client.preflight()
        client.verify_reattached(expected, old_node)
        outcome["storage_rescheduling"] = "passed"
        outcome["phase"] = "remove-reattached"
        client.preflight()
        client.delete_reattached()
        outcome["phase"] = "restore-start"
        client.preflight()
        client.create_pod("restored", expected["set"])
        outcome["phase"] = "verify-restored"
        client.preflight()
        client.execute("restored", expected)
        outcome["assertions"] = "passed"
        outcome["phase"] = "complete"
    finally:
        try:
            outcome["cleanup"] = "failed"
            client.cleanup()
            outcome["cleanup"] = "passed"
        finally:
            atomic_write_json(client.directory / "diagnostics/news-recovery.json", outcome)


def main():
    # Refuse before connection lookup, credential issuance, or Kubernetes requests.
    if os.environ.get("NEWS_RESTORE_DRILL_CONFIRM") != CONFIRMATION:
        raise ValueError("NEWS_RESTORE_DRILL_CONFIRM must equal restore:news:disposable")
    from scripts.test import access
    from scripts.test.scenarios.resilience_support import install_interrupt_handlers

    config, directory = access.suite_inputs(ROOT, "test.news-restore-drill")
    if sys.argv[1:] != [str(config)]:
        raise ValueError("the selected suite-bound kubeconfig is required")
    install_interrupt_handlers()
    run_drill(Cluster(config, directory))
    print(
        "News synthetic cluster recovery passed; publisher, off-cluster and native acceptance remain separate"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 -- Never render credential-bearing exceptions.
        print(
            "News scoped restore drill failed; inspect the run's sanitized outcome and ownership ledger",
            file=sys.stderr,
        )
        sys.exit(1)
