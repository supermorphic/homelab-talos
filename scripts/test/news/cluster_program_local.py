"""Execute the cluster fixture program with native Podman and synthetic volumes."""

import json
import re
import secrets
import subprocess
import tempfile
import time
from pathlib import Path

import yaml

from scripts.test.news import cluster_recovery as recovery


def run_program():
    marker = secrets.token_hex(6)
    base = recovery.prefix(marker)
    owned = []

    def command(*args, content=None, timeout=60, required=True):
        result = subprocess.run(
            ["podman", *args],
            input=content,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        if required and result.returncode:
            detail = re.search(r"News recovery phase failed at fixture line [0-9]+", result.stderr)
            raise RuntimeError(
                detail.group(0) if detail else "local recovery operation failed: " + args[0]
            )
        return result

    def inspect(kind, name):
        result = command(kind, "inspect", name, required=False)
        return json.loads(result.stdout)[0] if result.returncode == 0 else None

    def identity(kind, obj):
        if kind == "volume":
            if obj.get("Labels", {}).get("homelab-talos.test-run") != marker:
                raise RuntimeError("local recovery volume ownership changed")
            return obj["CreatedAt"]
        return obj["Id"] if kind == "pod" else obj["ID"]

    def record(kind, name):
        obj = inspect(kind, name)
        if obj is None:
            return
        owned.append((kind, name, identity(kind, obj)))

    def remove(kind, name, expected):
        obj = inspect(kind, name)
        if obj is None:
            return
        if identity(kind, obj) != expected:
            raise RuntimeError("local recovery ownership changed")
        if kind == "pod":
            command("pod", "rm", "--force", expected)
        else:
            command(kind, "rm", expected if kind == "secret" else name)

    # Namespace projection differs in Podman: it ignores ConfigMap.items. Keep
    # the canonical Pod and split only each local ConfigMap projection.
    def local_pod(phase, selected=""):
        obj = recovery.pod(marker, phase, selected)
        obj["metadata"]["labels"]["homelab-talos.test-run"] = marker
        if phase == "restored":
            # Native directory volumes lack ext4's filesystem-root entry. Keep
            # this outside DATA_PATH to exercise the fresh Longhorn case.
            obj["spec"]["containers"][2]["command"] = [
                "sh",
                "-c",
                "mkdir -p /data/lost+found; exec sh /opt/news/drill-helper.sh restored",
            ]
        maps = []
        data = recovery.config_data()
        for volume in obj["spec"]["volumes"]:
            if "configMap" not in volume:
                continue
            projection = volume["configMap"]
            name = base + "-" + volume["name"]
            maps.append(
                {
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "metadata": {"name": name},
                    "data": {item["key"]: data[item["key"]] for item in projection["items"]},
                }
            )
            projection["name"] = name
        return obj, maps

    with tempfile.TemporaryDirectory(prefix="news-local-drill-") as temporary:
        directory = Path(temporary)
        inputs = recovery.resources(marker)
        inputs = [obj for obj in inputs if obj["kind"] != "ConfigMap"]
        for obj in inputs:
            obj["metadata"]["labels"]["homelab-talos.test-run"] = marker
            kind = "volume" if obj["kind"] == "PersistentVolumeClaim" else "secret"
            if inspect(kind, obj["metadata"]["name"]) is not None:
                raise RuntimeError("local recovery name already exists")
            if kind == "volume":
                uid = "70" if obj["metadata"]["name"].endswith("-db") else "1000"
                obj["metadata"]["annotations"] = {
                    "volume.podman.io/uid": uid,
                    "volume.podman.io/gid": uid,
                }
        try:
            expected = None
            for phase in ("source", "restored"):
                obj, maps = local_pod(phase, "" if expected is None else expected["set"])
                name = obj["metadata"]["name"]
                if inspect("pod", name) is not None:
                    raise RuntimeError("local recovery Pod already exists")
                config = directory / "maps.yaml"
                manifest = directory / "inputs.yaml"
                config.write_text(yaml.safe_dump_all(maps))
                manifest.write_text(
                    yaml.safe_dump_all((inputs if phase == "source" else []) + [obj])
                )
                config.chmod(0o600)
                manifest.chmod(0o600)
                try:
                    command(
                        "kube",
                        "play",
                        "--network=none",
                        "--start=false",
                        "--configmap",
                        str(config),
                        str(manifest),
                        timeout=120,
                    )
                finally:
                    if phase == "source":
                        for item in inputs:
                            kind = (
                                "volume" if item["kind"] == "PersistentVolumeClaim" else "secret"
                            )
                            record(kind, item["metadata"]["name"])
                    record("pod", name)
                command("pod", "start", name)
                app = name + "-app"
                deadline = time.monotonic() + 180
                while command(
                    "exec", app, "php", "/opt/news/ready.php", required=False
                ).returncode:
                    if time.monotonic() >= deadline:
                        # Only public fixed initialization logs, never env or Secrets.
                        raise RuntimeError("local recovery readiness timed out")
                    time.sleep(1)
                print("Local recovery phase ready:", phase, flush=True)
                result = command(
                    "exec",
                    *(["--interactive"] if expected is not None else []),
                    app,
                    "php",
                    "/opt/news/drill.php",
                    phase,
                    content=None if expected is None else json.dumps(expected),
                    timeout=720,
                )
                if phase == "source":
                    expected = json.loads(result.stdout)
                    helper = name + "-helper"
                    command("exec", helper, "sh", "/opt/news/drill-helper.sh", "capture")
                    deadline = time.monotonic() + 660
                    while True:
                        result = command(
                            "exec",
                            helper,
                            "sh",
                            "/opt/news/drill-helper.sh",
                            "captured",
                            required=False,
                        )
                        if result.returncode == 0:
                            selected = result.stdout.strip()
                            if not re.fullmatch(r"set-[0-9]{10}-[A-Za-z0-9]{6}", selected):
                                raise RuntimeError("invalid local capture set")
                            expected = {"set": selected, **expected}
                            break
                        if result.returncode != 75 or time.monotonic() >= deadline:
                            raise RuntimeError("local capture did not finish")
                        time.sleep(1)
                    remove(*owned[-1])
            print("PASS: canonical recovery programs with source removed and fresh local targets")
        except (RuntimeError, subprocess.SubprocessError):
            diagnostics = recovery.ROOT / ".tmp/news/033-execution" / (base + "-failure.log")
            diagnostics.parent.mkdir(parents=True, exist_ok=True)
            chunks = []
            for kind, name, _ in owned:
                if kind != "pod":
                    continue
                for container in ("app", "database", "helper"):
                    status = inspect("container", name + "-" + container)
                    if status:
                        chunks.append(json.dumps(status.get("State", {})))
                    logs = command("logs", "--tail=20", name + "-" + container, required=False)
                    chunks.append(container + ":\n" + logs.stdout + logs.stderr)
            combined = "\n".join(chunks)
            passwords = inputs[-1]["stringData"].values()
            if any(value in combined for value in passwords):
                combined = "Runtime diagnostics withheld: credential detected"
            diagnostics.write_text(combined)
            diagnostics.chmod(0o600)
            print("Private fixture diagnostics:", diagnostics, flush=True)
            raise
        finally:
            failures = []
            for item in reversed(owned):
                try:
                    remove(*item)
                except (RuntimeError, OSError, subprocess.SubprocessError):
                    failures.append(item[1])
            if failures:
                raise RuntimeError("owned local recovery cleanup incomplete")


if __name__ == "__main__":
    run_program()
