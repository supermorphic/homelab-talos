"""Guarded, operator-only qbit_manage real-download policy E2E.

The host-side workflow uses Python for structured state, JSON/YAML handling,
deadlines, evidence, and failure-safe teardown. Kubernetes mutations still flow
through the repository's pinned kubectl binary, and qBittorrent credentials
remain inside the ephemeral curl helper pod.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, ClassVar

import yaml

FIXTURE_URL = "https://webtorrent.io/torrents/sintel.torrent"
FIXTURE_HASH = "08ada5a7a6183aae1e09d831df6748d566095a10"
QBM_IMAGE = "ghcr.io/stuffanthings/qbit_manage:v4.10.0"
NAMESPACE = "media"


class ScenarioFailure(RuntimeError):
    """A sanitized E2E failure safe to write to result artifacts."""


class AssertionFailure(ScenarioFailure):
    """The product behavior or a safety assertion failed."""


class ExternalDependencyFailure(ScenarioFailure):
    """The public fixture could not be obtained within its bounded window."""


class TerminationRequested(ScenarioFailure):
    """Chainsaw or the operator requested termination; teardown must still run."""


class CommandFailure(ScenarioFailure):
    """A subprocess failed; stdout/stderr are deliberately not embedded."""

    def __init__(self, argv: list[str], returncode: int, stderr: str = ""):
        super().__init__(f"{Path(argv[0]).name} exited with status {returncode}")
        self.argv = tuple(argv)
        self.returncode = returncode
        self.stderr = stderr


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run_command(
    argv: list[str],
    *,
    input_text: str | None = None,
    timeout: float | None = None,
    visible: bool = False,
) -> str:
    """Run an argument-vector command without a host shell."""
    result = subprocess.run(
        argv,
        input=input_text,
        text=True,
        stdout=None if visible else subprocess.PIPE,
        stderr=None if visible else subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        raise CommandFailure(argv, result.returncode, result.stderr or "")
    return "" if visible else result.stdout


def classify_api_command_failure(error: CommandFailure) -> str:
    stderr = error.stderr
    if "ModuleNotFoundError" in stderr or "ImportError" in stderr:
        return "missing-client-module"
    if "SyntaxError" in stderr or "IndentationError" in stderr:
        return "helper-syntax"
    if "unknown flag: --stdin" in stderr:
        return "kubectl-stdin-unsupported"
    if "unable to upgrade connection" in stderr or "error dialing backend" in stderr:
        return "exec-transport"
    exceptions = re.findall(
        r"(?:^|\n)([A-Za-z_][A-Za-z0-9_.]{0,63}(?:Error|Exception)):",
        stderr,
    )
    if exceptions:
        error_type = exceptions[-1].rsplit(".", maxsplit=1)[-1]
        lines = re.findall(r'File "<stdin>", line ([1-9][0-9]{0,3})', stderr)
        suffix = f"-L{lines[-1]}" if lines else ""
        return f"python-{error_type}{suffix}"
    if "command terminated with exit code" in stderr:
        return "helper-process"
    return "unclassified-command"


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


class EnvReference(str):
    """A qbit_manage !ENV scalar retained by the safe YAML loader/dumper."""


class PolicyLoader(yaml.SafeLoader):
    pass


class PolicyDumper(yaml.SafeDumper):
    pass


def _construct_env(loader: PolicyLoader, node: yaml.Node) -> EnvReference:
    return EnvReference(loader.construct_scalar(node))


def _represent_env(dumper: PolicyDumper, value: EnvReference) -> yaml.Node:
    return dumper.represent_scalar("!ENV", str(value))


PolicyLoader.add_constructor("!ENV", _construct_env)
PolicyDumper.add_representer(EnvReference, _represent_env)


def load_policy_yaml(text: str) -> dict[str, Any]:
    value = yaml.load(text, Loader=PolicyLoader)
    if not isinstance(value, dict):
        raise TypeError("qbit_manage config must be a mapping")
    return value


def dump_policy_yaml(value: dict[str, Any]) -> str:
    return yaml.dump(value, Dumper=PolicyDumper, sort_keys=False)


def validate_run_id(run_id: str) -> None:
    if not re.fullmatch(r"[a-z0-9]{8,24}", run_id):
        raise ValueError(f"unsafe E2E run ID: {run_id!r}")


@dataclass(frozen=True)
class RunIdentity:
    run_id: str

    def __post_init__(self) -> None:
        validate_run_id(self.run_id)

    @classmethod
    def from_run_dir(cls, run_dir: Path) -> RunIdentity:
        normalized = re.sub(r"[^a-z0-9]", "", run_dir.name.lower())
        if len(normalized) < 8:
            raise ValueError("could not derive a safe E2E run ID")
        return cls(normalized[-20:])

    @property
    def category(self) -> str:
        return f"e2e-qbm-{self.run_id}"

    @property
    def run_tag(self) -> str:
        return self.category

    @property
    def limit_tag(self) -> str:
        return f"e2e-qbm-limit-{self.run_id}"

    @property
    def group(self) -> str:
        return f"e2e_qbm_{self.run_id}"

    @property
    def group_tag(self) -> str:
        return f"~e2e_qbm_{self.run_id}_1.{self.group}"

    @property
    def owned_tags(self) -> tuple[str, ...]:
        return (
            self.run_tag,
            self.limit_tag,
            self.group_tag,
            f"e2e_qbm_min_seed_{self.run_id}",
            f"e2e_qbm_min_seeds_{self.run_id}",
            f"e2e_qbm_last_active_{self.run_id}",
        )

    @property
    def download_root(self) -> str:
        return f"/data/downloads/.e2e-qbit-manage-{self.run_id}"

    @property
    def media_root(self) -> str:
        return f"/data/media/.e2e-qbit-manage-{self.run_id}"

    @property
    def media_path(self) -> str:
        return f"{self.media_root}/payload"

    @property
    def sentinel_path(self) -> str:
        return f"{self.download_root}/.e2e-sentinel-{self.run_id}"

    @property
    def resource_selector(self) -> str:
        return f"homelab-talos/e2e-run={self.run_id}"

    @property
    def api_name(self) -> str:
        return f"qbm-e2e-{self.run_id}-api"


def validate_relative_payload(path: str) -> None:
    candidate = PurePosixPath(path)
    if not path or candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"unsafe relative fixture payload: {path!r}")


def validate_owned_path(identity: RunIdentity, path: str) -> None:
    if not path or ".." in PurePosixPath(path).parts:
        raise ValueError(f"unsafe E2E path: {path!r}")
    candidate = PurePosixPath(path)
    download = PurePosixPath(identity.download_root)
    media = PurePosixPath(identity.media_root)
    recycle = PurePosixPath("/data/downloads/.RecycleBin")
    if candidate == download or download in candidate.parents:
        return
    if candidate == media or media in candidate.parents:
        return
    if recycle in candidate.parents and identity.run_id in path:
        return
    raise ValueError(f"path is not owned by run {identity.run_id}: {path!r}")


def normalized_save_path(value: str) -> str:
    return value.rstrip("/")


def validate_no_qbit_collisions(
    identity: RunIdentity,
    fixture_info: list[dict[str, Any]],
    categories: dict[str, Any],
    tags: list[str],
) -> None:
    if fixture_info:
        raise AssertionFailure("refusing to adopt the pre-existing Sintel fixture")
    if identity.category in categories:
        raise AssertionFailure("run-named qBittorrent category already exists")
    if set(identity.owned_tags).intersection(tags):
        raise AssertionFailure("run-named qBittorrent tag already exists")


def validate_production_isolation(config: dict[str, Any]) -> None:
    commands = config.get("commands")
    settings = config.get("settings")
    share_limits = config.get("share_limits")
    if (
        not isinstance(commands, dict)
        or not isinstance(settings, dict)
        or not isinstance(share_limits, dict)
    ):
        raise AssertionFailure("deployed production category/private isolation drifted")

    public = share_limits.get("public")
    if not isinstance(public, dict):
        raise AssertionFailure("deployed production category/private isolation drifted")

    categories = public.get("categories")
    excluded_tags = public.get("exclude_any_tags")
    if (
        commands.get("tag_update") is not True
        or commands.get("share_limits") is not True
        or settings.get("private_tag") != "tracker-private"
        or config.get("directory", {}).get("root_dir") != "/data/downloads"
        or not isinstance(categories, list)
        or len(categories) != 2
        or set(categories) != {"movies", "tv"}
        or not isinstance(excluded_tags, list)
        or "tracker-private" not in excluded_tags
    ):
        raise AssertionFailure("deployed production category/private isolation drifted")


class PolicyConfig:
    TOP_KEYS: ClassVar[set[str]] = {
        "commands",
        "qbt",
        "settings",
        "directory",
        "recyclebin",
        "share_limits",
    }
    COMMANDS: ClassVar[dict[str, bool]] = {
        "dry_run": False,
        "recheck": False,
        "cat_update": False,
        "tag_update": False,
        "rem_unregistered": False,
        "tag_tracker_error": False,
        "rem_orphaned": False,
        "tag_nohardlinks": False,
        "share_limits": True,
        "skip_cleanup": True,
    }

    @staticmethod
    def build(source: dict[str, Any], identity: RunIdentity, cleanup: bool) -> dict[str, Any]:
        if not isinstance(cleanup, bool):
            raise TypeError("cleanup must be a boolean")
        for key in ("qbt", "directory", "recyclebin"):
            if not isinstance(source.get(key), dict):
                raise TypeError(f"deployed config is missing mapping {key}")
        recyclebin = copy.deepcopy(source["recyclebin"])
        recyclebin.update({"enabled": True, "save_torrents": False})
        return {
            "commands": copy.deepcopy(PolicyConfig.COMMANDS),
            "qbt": copy.deepcopy(source["qbt"]),
            "settings": {
                "disable_qbt_default_share_limits": False,
                "share_limits_filter_completed": True,
                "share_limits_tag": f"~e2e_qbm_{identity.run_id}",
                "share_limits_min_seeding_time_tag": (f"e2e_qbm_min_seed_{identity.run_id}"),
                "share_limits_min_num_seeds_tag": (f"e2e_qbm_min_seeds_{identity.run_id}"),
                "share_limits_last_active_tag": (f"e2e_qbm_last_active_{identity.run_id}"),
            },
            "directory": copy.deepcopy(source["directory"]),
            "recyclebin": recyclebin,
            "share_limits": {
                identity.group: {
                    "priority": 1,
                    "categories": [identity.category],
                    "include_all_tags": [identity.run_tag],
                    "exclude_any_tags": ["tracker-private"],
                    "custom_tag": identity.limit_tag,
                    "add_group_to_tag": True,
                    "max_ratio": 0.01,
                    "min_seeding_time": "1m",
                    "max_seeding_time": "2m",
                    "share_limit_action": "Stop",
                    "cleanup": cleanup,
                }
            },
        }

    @staticmethod
    def validate(config: dict[str, Any], identity: RunIdentity, cleanup: bool) -> None:
        def require(condition: bool, reason: str) -> None:
            if not condition:
                raise ValueError(reason)

        require(set(config) == PolicyConfig.TOP_KEYS, "unexpected policy top-level keys")
        require(config.get("commands") == PolicyConfig.COMMANDS, "unsafe command authority")
        qbt = config.get("qbt", {})
        require(
            qbt.get("host") == "http://qbittorrent.media.svc.cluster.local:8080",
            "unexpected qBittorrent host",
        )
        require(
            isinstance(qbt.get("user"), EnvReference) and qbt["user"] == "QBT_USER",
            "qBittorrent user must remain !ENV QBT_USER",
        )
        require(
            isinstance(qbt.get("pass"), EnvReference) and qbt["pass"] == "QBT_PASS",
            "qBittorrent password must remain !ENV QBT_PASS",
        )
        require(
            config.get("directory", {}).get("root_dir") == "/data/downloads",
            "unexpected download root",
        )
        recyclebin = config.get("recyclebin", {})
        require(
            recyclebin.get("enabled") is True and recyclebin.get("save_torrents") is False,
            "unsafe recycle-bin settings",
        )
        expected_settings = PolicyConfig.build(
            {
                "qbt": qbt,
                "directory": config["directory"],
                "recyclebin": recyclebin,
            },
            identity,
            cleanup,
        )["settings"]
        require(config.get("settings") == expected_settings, "unsafe share-limit settings")
        groups = config.get("share_limits")
        require(
            isinstance(groups, dict) and set(groups) == {identity.group},
            "policy must contain exactly one run group",
        )
        expected_group = {
            "priority": 1,
            "categories": [identity.category],
            "include_all_tags": [identity.run_tag],
            "exclude_any_tags": ["tracker-private"],
            "custom_tag": identity.limit_tag,
            "add_group_to_tag": True,
            "max_ratio": 0.01,
            "min_seeding_time": "1m",
            "max_seeding_time": "2m",
            "share_limit_action": "Stop",
            "cleanup": cleanup,
        }
        require(groups[identity.group] == expected_group, "unsafe run group")


def job_manifest(identity: RunIdentity, phase: str, image: str, config_map: str) -> dict[str, Any]:
    if not re.fullmatch(r"[a-z0-9-]{2,16}", phase):
        raise ValueError(f"unsafe Job phase: {phase!r}")
    if not image or not config_map:
        raise ValueError("Job image and ConfigMap are required")
    name = f"qbm-e2e-{identity.run_id}-{phase}"
    labels = {
        "homelab-talos/e2e-run": identity.run_id,
        "homelab-talos/e2e-target": "qbit-manage-policy",
    }
    restricted = {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
    }
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "namespace": NAMESPACE, "labels": labels},
        "spec": {
            "backoffLimit": 0,
            "activeDeadlineSeconds": 120,
            "ttlSecondsAfterFinished": 600,
            "template": {
                "metadata": {"labels": labels},
                "spec": {
                    "restartPolicy": "Never",
                    "automountServiceAccountToken": False,
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 568,
                        "runAsGroup": 568,
                        "fsGroup": 568,
                        "fsGroupChangePolicy": "OnRootMismatch",
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "initContainers": [
                        {
                            "name": "init-config",
                            "image": image,
                            "command": [
                                "/bin/sh",
                                "-c",
                                "cp /config-src/config.yml /config/config.yml",
                            ],
                            "securityContext": restricted,
                            "volumeMounts": [
                                {"name": "config", "mountPath": "/config"},
                                {
                                    "name": "config-src",
                                    "mountPath": "/config-src",
                                    "readOnly": True,
                                },
                            ],
                        }
                    ],
                    "containers": [
                        {
                            "name": "app",
                            "image": image,
                            "args": ["python3", "qbit_manage.py", "--run"],
                            "env": [
                                {"name": "QBT_WEB_SERVER", "value": "false"},
                                {"name": "QBT_CONFIG_DIR", "value": "/config"},
                                {"name": "QBT_LOGFILE", "value": "qbit_manage.log"},
                                {"name": "QBT_LOG_LEVEL", "value": "INFO"},
                                {"name": "PYTHONDONTWRITEBYTECODE", "value": "1"},
                            ],
                            "envFrom": [{"secretRef": {"name": "qbit-manage-secret"}}],
                            "securityContext": restricted,
                            "volumeMounts": [
                                {"name": "config", "mountPath": "/config"},
                                {
                                    "name": "data",
                                    "mountPath": "/data/downloads",
                                    "subPath": "downloads",
                                },
                            ],
                        }
                    ],
                    "volumes": [
                        {"name": "config", "emptyDir": {}},
                        {
                            "name": "config-src",
                            "configMap": {"name": config_map},
                        },
                        {
                            "name": "data",
                            "persistentVolumeClaim": {"claimName": "media-data"},
                        },
                    ],
                },
            },
        },
    }


class ResultRecorder:
    def __init__(self, run_dir: Path, identity: RunIdentity):
        self.run_dir = run_dir
        for child in ("logs", "manifests", "diagnostics"):
            (run_dir / child).mkdir(parents=True, exist_ok=True)
        self.evidence: dict[str, Any] = {
            "schemaVersion": 1,
            "target": "qbit-manage-policy",
            "runId": identity.run_id,
            "fixture": {"infoHash": FIXTURE_HASH},
            "ownership": {
                "category": identity.category,
                "downloadRoot": identity.download_root,
                "mediaRoot": identity.media_root,
            },
            "phases": {},
            "jobs": {},
        }
        self.write_status("assertion", "not-classified", "workflow not completed")
        self.write_status(
            "external-dependency", "not-classified", "fixture download not attempted"
        )
        self.write_status("cleanup", "not-attempted", "teardown not started")
        self.write_status("recovery", "not-attempted", "teardown not started")
        self.flush_evidence()

    def write_status(self, name: str, status: str, reason: str) -> None:
        atomic_write_json(self.run_dir / f"{name}.json", {"status": status, "reason": reason})

    def flush_evidence(self) -> None:
        atomic_write_json(self.run_dir / "evidence.json", self.evidence)

    def phase(self, name: str, value: dict[str, Any]) -> None:
        self.evidence["phases"][name] = value
        self.flush_evidence()

    def job(self, phase: str, name: str) -> None:
        self.evidence["jobs"][phase] = {"name": name, "status": "passed"}
        self.flush_evidence()

    def manifest_path(self, name: str) -> Path:
        return self.run_dir / "manifests" / name

    def write_manifest(self, name: str, value: dict[str, Any]) -> Path:
        path = self.manifest_path(name)
        atomic_write_json(path, value)
        return path


class Kubectl:
    def __init__(self, kubeconfig: str, namespace: str = NAMESPACE):
        self.kubeconfig = kubeconfig
        self.namespace = namespace

    def call(
        self,
        *args: str,
        input_text: str | None = None,
        timeout: float | None = None,
    ) -> str:
        argv = [
            "kubectl",
            "--kubeconfig",
            self.kubeconfig,
            "--namespace",
            self.namespace,
            *args,
        ]
        return run_command(argv, input_text=input_text, timeout=timeout)

    def get_json(self, resource: str, name: str | None = None, *args: str) -> Any:
        command = ["get", resource]
        if name:
            command.append(name)
        command.extend(args)
        command.extend(["--output", "json"])
        return json.loads(self.call(*command))

    def apply(self, path: Path) -> None:
        self.call("apply", "-f", str(path), timeout=180)

    def exec(
        self,
        pod: str,
        argv: list[str],
        *,
        container: str | None = None,
        input_text: str | None = None,
        timeout: float | None = 60,
    ) -> str:
        command = ["exec", pod]
        if input_text is not None:
            command.append("--stdin")
        if container:
            command.extend(["-c", container])
        command.extend(["--", *argv])
        return self.call(*command, input_text=input_text, timeout=timeout)

    def delete_labeled(self, selector: str) -> None:
        self.call(
            "delete",
            "job,configmap,pod",
            "--selector",
            selector,
            "--ignore-not-found=true",
            "--wait=true",
            "--timeout=2m",
            timeout=150,
        )

    def labeled_names(self, selector: str) -> list[str]:
        output = self.call(
            "get",
            "job,configmap,pod",
            "--selector",
            selector,
            "--output",
            "name",
            "--ignore-not-found",
        )
        return [line for line in output.splitlines() if line]


class QbitClient:
    def __init__(self, kube: Kubectl, pod: str, helper: str):
        self.kube = kube
        self.pod = pod
        self.helper = helper

    def call(self, command: str, *args: str) -> str:
        try:
            return self.kube.exec(
                self.pod,
                ["python3", "-", command, *args],
                container="app",
                input_text=self.helper,
                timeout=45,
            )
        except CommandFailure as error:
            reason = classify_api_command_failure(error)
            raise ScenarioFailure(f"in-pod API execution failed ({reason})") from error

    def json(self, command: str, *args: str) -> Any:
        return json.loads(self.call(command, *args))

    def info(self, info_hash: str) -> list[dict[str, Any]]:
        value = self.json("info", info_hash)
        if not isinstance(value, list):
            raise ScenarioFailure("qBittorrent info response was not a list")
        return value

    def files(self, info_hash: str) -> list[dict[str, Any]]:
        value = self.json("files", info_hash)
        if not isinstance(value, list):
            raise ScenarioFailure("qBittorrent files response was not a list")
        return value

    def categories(self) -> dict[str, Any]:
        value = self.json("categories")
        if not isinstance(value, dict):
            raise ScenarioFailure("qBittorrent categories response was not an object")
        return value

    def tags(self) -> list[str]:
        value = self.json("tags")
        if not isinstance(value, list) or not all(isinstance(tag, str) for tag in value):
            raise ScenarioFailure("qBittorrent tags response was not a string list")
        return value

    def health(self) -> dict[str, str]:
        value = self.json("health")
        if not isinstance(value, dict) or value.get("status") not in {"passed", "failed"}:
            raise ScenarioFailure("qBittorrent API health response was invalid")
        return value

    def add(self, url: str, save_path: str, category: str, name: str) -> str:
        return self.call("add", url, save_path, category, name).strip()

    def delete(self, info_hash: str) -> None:
        self.call("delete", info_hash)

    def add_tags(self, info_hash: str, tags: str) -> None:
        self.call("add-tags", info_hash, tags)

    def remove_tags(self, info_hash: str, tags: str) -> None:
        self.call("remove-tags", info_hash, tags)

    def create_category(self, category: str, save_path: str) -> None:
        self.call("create-category", category, save_path)

    def remove_category(self, category: str) -> None:
        self.call("remove-category", category)

    def create_tags(self, tags: str) -> None:
        self.call("create-tags", tags)

    def delete_tags(self, tags: str) -> None:
        self.call("delete-tags", tags)


class RemoteFilesystem:
    def __init__(self, kube: Kubectl, pod: str):
        self.kube = kube
        self.pod = pod

    def script(self, script: str, *args: str, timeout: float = 120) -> str:
        return self.kube.exec(
            self.pod,
            ["sh", "-eu", "-c", script, "qbm-e2e", *args],
            container="app",
            timeout=timeout,
        )

    def assert_absent(self, *paths: str) -> None:
        self.script('for path do [ ! -e "$path" ] || exit 1; done', *paths)

    def remove(self, identity: RunIdentity, path: str) -> None:
        validate_owned_path(identity, path)
        self.script('rm -rf -- "$1"', path)

    def discover_recycle(self, run_id: str) -> list[str]:
        output = self.script(
            """
root=/data/downloads/.RecycleBin
[ -d "$root" ] || exit 0
find "$root" -mindepth 1 -maxdepth 2 -name "*$1*" -print
""".strip(),
            run_id,
        )
        return [line for line in output.splitlines() if line]

    def verify_cleanup(self, paths: list[str], run_id: str, check_recycle: bool) -> None:
        for path in paths:
            self.assert_absent(path)
        if check_recycle and self.discover_recycle(run_id):
            raise ScenarioFailure("run-owned recycle paths remain")

    def exists_all(self, *paths: str) -> bool:
        output = self.script(
            'for path do if [ -f "$path" ]; then printf "1\\n"; else printf "0\\n"; fi; done',
            *paths,
        )
        presence = output.splitlines()
        if len(presence) != len(paths) or any(value not in {"0", "1"} for value in presence):
            raise ScenarioFailure("could not determine run-owned file presence")
        return all(value == "1" for value in presence)

    def hardlink(self, source: str, media_root: str) -> tuple[int, int, int, str]:
        output = self.script(
            """
mkdir -p "$2"
ln "$1" "$2/payload"
printf "%s %s %s %s" \
  "$(stat -c %i "$1")" "$(stat -c %h "$1")" "$(stat -c %s "$1")" \
  "$(sha256sum "$1" | cut -d " " -f 1)"
""".strip(),
            source,
            media_root,
            timeout=300,
        )
        return parse_stats(output)

    def stats(self, path: str) -> tuple[int, int, int, str]:
        output = self.script(
            """
printf "%s %s %s %s" \
  "$(stat -c %i "$1")" "$(stat -c %h "$1")" "$(stat -c %s "$1")" \
  "$(sha256sum "$1" | cut -d " " -f 1)"
""".strip(),
            path,
            timeout=300,
        )
        return parse_stats(output)

    def write_sentinel(self, path: str, run_id: str) -> None:
        self.script('printf "%s" "$2" >"$1"', path, run_id)


def parse_stats(text: str) -> tuple[int, int, int, str]:
    fields = text.strip().split()
    if len(fields) != 4 or not all(field.isdigit() for field in fields[:3]):
        raise AssertionFailure("could not parse hardlink stat evidence")
    digest = fields[3]
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise AssertionFailure("could not parse hardlink digest evidence")
    return int(fields[0]), int(fields[1]), int(fields[2]), digest


@dataclass
class OwnershipLedger:
    fixture_attempted: bool = False
    category_attempted: bool = False
    tags_attempted: bool = False
    download_path_attempted: bool = False
    media_path_attempted: bool = False
    recycle_attempted: bool = False
    resources_attempted: bool = False


class Teardown:
    """Best-effort exact teardown that continues after every individual failure."""

    def __init__(
        self,
        identity: RunIdentity,
        ledger: OwnershipLedger,
        recorder: ResultRecorder,
        kube: Kubectl,
        *,
        qbit: QbitClient | None,
        filesystem: RemoteFilesystem | None,
    ):
        self.identity = identity
        self.ledger = ledger
        self.recorder = recorder
        self.kube = kube
        self.qbit = qbit
        self.filesystem = filesystem
        self.ok = True

    def attempt(self, label: str, action: Callable[[], Any]) -> Any | None:
        try:
            return action()
        except Exception:  # noqa: BLE001 - teardown must continue after each operation
            self.ok = False
            print(f"Teardown warning: {label} failed.", file=sys.stderr)
            return None

    def _fixture_is_owned(self, info: list[dict[str, Any]]) -> bool:
        if len(info) != 1:
            return False
        torrent = info[0]
        return (
            torrent.get("hash") == FIXTURE_HASH
            and torrent.get("category") == self.identity.category
            and normalized_save_path(str(torrent.get("save_path", "")))
            == self.identity.download_root
        )

    def run(self) -> bool:
        self.recorder.write_status(
            "cleanup", "not-attempted", "exact run-owned teardown in progress"
        )
        self.recorder.write_status(
            "recovery", "not-attempted", "exact run-owned teardown in progress"
        )

        if self.qbit is not None:
            if self.ledger.fixture_attempted:
                info = self.attempt("query owned fixture", lambda: self.qbit.info(FIXTURE_HASH))
                if info:
                    if self._fixture_is_owned(info):
                        self.attempt(
                            "delete owned fixture", lambda: self.qbit.delete(FIXTURE_HASH)
                        )
                    else:
                        self.ok = False
                        print(
                            "Teardown warning: fixed fixture no longer has the run ownership markers; refusing deletion.",
                            file=sys.stderr,
                        )
                remaining = self.attempt(
                    "verify fixture absence", lambda: self.qbit.info(FIXTURE_HASH)
                )
                if remaining:
                    self.ok = False
            if self.ledger.category_attempted:
                self.attempt(
                    "remove owned category",
                    lambda: self.qbit.remove_category(self.identity.category),
                )
                categories = self.attempt("verify category absence", self.qbit.categories)
                if categories is None or self.identity.category in categories:
                    self.ok = False
            if self.ledger.tags_attempted:
                owned_csv = ",".join(self.identity.owned_tags)
                self.attempt("remove owned tags", lambda: self.qbit.delete_tags(owned_csv))
                tags = self.attempt("verify tag absence", self.qbit.tags)
                if tags is None or set(self.identity.owned_tags).intersection(tags):
                    self.ok = False
        elif (
            self.ledger.fixture_attempted
            or self.ledger.category_attempted
            or self.ledger.tags_attempted
        ):
            self.ok = False

        paths: list[str] = []
        if self.ledger.download_path_attempted:
            paths.append(self.identity.download_root)
        if self.ledger.media_path_attempted:
            paths.append(self.identity.media_root)
        if self.filesystem is not None:
            for path in paths:
                self.attempt(
                    f"remove owned path {path}",
                    lambda path=path: self.filesystem.remove(self.identity, path),
                )
            if self.ledger.recycle_attempted:
                recycle_paths = self.attempt(
                    "discover owned recycle paths",
                    lambda: self.filesystem.discover_recycle(self.identity.run_id),
                )
                if recycle_paths is None:
                    recycle_paths = []
                for path in recycle_paths:
                    try:
                        validate_owned_path(self.identity, path)
                    except ValueError:
                        self.ok = False
                        continue
                    self.attempt(
                        f"remove owned recycle path {path}",
                        lambda path=path: self.filesystem.remove(self.identity, path),
                    )
            if paths or self.ledger.recycle_attempted:
                self.attempt(
                    "verify filesystem cleanup",
                    lambda: self.filesystem.verify_cleanup(
                        paths, self.identity.run_id, self.ledger.recycle_attempted
                    ),
                )
        elif paths or self.ledger.recycle_attempted:
            self.ok = False

        if self.ledger.resources_attempted:
            self.attempt(
                "remove run-labeled Kubernetes resources",
                lambda: self.kube.delete_labeled(self.identity.resource_selector),
            )
            remaining = self.attempt(
                "verify Kubernetes resource cleanup",
                lambda: self.kube.labeled_names(self.identity.resource_selector),
            )
            if remaining is None or remaining:
                self.ok = False

        if self.ok:
            reason = "all exact run-owned state removed"
            self.recorder.write_status("cleanup", "passed", reason)
            self.recorder.write_status("recovery", "passed", reason)
        else:
            reason = (
                f"manual check required for run {self.identity.run_id}: "
                f"{self.identity.download_root}, {self.identity.media_root}, "
                "and run-labeled media resources"
            )
            self.recorder.write_status("cleanup", "failed", reason)
            self.recorder.write_status("recovery", "failed", reason)
        return self.ok


class Scenario:
    def __init__(
        self,
        repo_root: Path,
        kubeconfig: str,
        run_dir: Path,
        *,
        sleeper: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic,
    ):
        self.repo_root = repo_root
        self.kubeconfig = kubeconfig
        self.run_dir = run_dir
        self.identity = RunIdentity.from_run_dir(run_dir)
        self.recorder = ResultRecorder(run_dir, self.identity)
        self.kube = Kubectl(kubeconfig)
        self.ledger = OwnershipLedger()
        self.qbit: QbitClient | None = None
        self.filesystem: RemoteFilesystem | None = None
        self.sleeper = sleeper
        self.monotonic = monotonic
        self.live_config: dict[str, Any] | None = None
        self.qbm_image = ""
        self.source_path = ""
        self.media_before: tuple[int, int, int, str] | None = None

    def fail(self, reason: str) -> None:
        raise AssertionFailure(reason)

    @staticmethod
    def torrent_tags(info: list[dict[str, Any]]) -> set[str]:
        if len(info) != 1:
            return set()
        return {tag.strip() for tag in str(info[0].get("tags", "")).split(",") if tag.strip()}

    def wait_for(self, timeout: float, interval: float, predicate: Callable[[], bool]) -> bool:
        deadline = self.monotonic() + timeout
        while True:
            if predicate():
                return True
            if self.monotonic() >= deadline:
                return False
            self.sleeper(interval)

    def connect_api_helper(self) -> None:
        helper = (self.repo_root / "scripts/test/helpers/qbit_manage_policy_api.py").read_text(
            encoding="utf-8"
        )
        pods = self.kube.get_json(
            "pod",
            None,
            "--selector",
            "app.kubernetes.io/name=qbit-manage",
        )
        running = [
            item["metadata"]["name"]
            for item in pods.get("items", [])
            if item.get("status", {}).get("phase") == "Running"
        ]
        if len(running) != 1:
            raise ScenarioFailure("expected exactly one running qbit_manage API host pod")
        self.qbit = QbitClient(self.kube, running[0], helper)
        health = self.qbit.health()
        if health.get("status") != "passed":
            error_type = str(health.get("errorType", "unknown"))
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", error_type):
                error_type = "unknown"
            stage = str(health.get("stage", "unknown"))
            if stage not in {"import", "client-init", "auth"}:
                stage = "unknown"
            raise ScenarioFailure(
                f"qbit_manage in-pod API helper health failed ({stage}:{error_type})"
            )

    def preflight(self) -> None:
        print(
            f"Preflight: validating live qBittorrent/qbit_manage and run isolation ({self.identity.run_id})."
        )
        run_command(["scripts/verify/qbittorrent.sh", self.kubeconfig], visible=True)
        run_command(["scripts/verify/qbit-manage.sh", self.kubeconfig], visible=True)
        for app in ("qbittorrent", "sonarr"):
            self.kube.call(
                "wait",
                "--for=condition=Ready",
                "pod",
                "--selector",
                f"app.kubernetes.io/name={app}",
                "--timeout=5m",
                timeout=310,
            )
        pods = self.kube.get_json("pod", None, "--selector", "app.kubernetes.io/name=sonarr")
        running = [
            item["metadata"]["name"]
            for item in pods.get("items", [])
            if item.get("status", {}).get("phase") == "Running"
        ]
        if not running:
            self.fail("no running Sonarr hardlink-probe pod")
        self.filesystem = RemoteFilesystem(self.kube, running[0])

        deployment = self.kube.get_json("deployment", "qbit-manage")
        pod_spec = deployment["spec"]["template"]["spec"]
        containers = {item["name"]: item for item in pod_spec.get("containers", [])}
        init_containers = {item["name"]: item for item in pod_spec.get("initContainers", [])}
        app = containers.get("app", {})
        init = init_containers.get("init-config", {})
        if app.get("image") != QBM_IMAGE or init.get("image") != QBM_IMAGE:
            self.fail("live qbit_manage image differs from the validated interface")
        security = pod_spec.get("securityContext", {})
        expected_security = {
            "runAsNonRoot": True,
            "runAsUser": 568,
            "runAsGroup": 568,
            "fsGroup": 568,
        }
        if any(security.get(key) != value for key, value in expected_security.items()):
            self.fail("live qbit_manage pod security context drifted")
        if security.get("seccompProfile", {}).get("type") != "RuntimeDefault":
            self.fail("live qbit_manage seccomp profile drifted")
        app_security = app.get("securityContext", {})
        if app_security.get("allowPrivilegeEscalation") is not False or app_security.get(
            "capabilities", {}
        ).get("drop") != ["ALL"]:
            self.fail("live qbit_manage app security context drifted")
        env = {item["name"]: item.get("value") for item in app.get("env", [])}
        if env.get("QBT_SCHEDULE") != "15":
            self.fail("live qbit_manage schedule drifted")
        self.qbm_image = app["image"]

        config_map_name = next(
            (
                volume["configMap"]["name"]
                for volume in pod_spec.get("volumes", [])
                if volume.get("name") == "config-src"
            ),
            "",
        )
        if not config_map_name:
            self.fail("live qbit_manage ConfigMap wiring drifted")
        config_map = self.kube.get_json("configmap", config_map_name)
        config_text = config_map.get("data", {}).get("config.yml", "")
        if not config_text:
            self.fail("live qbit_manage config is empty")
        atomic_write_text(self.recorder.manifest_path("deployed-config.yml"), config_text)
        self.live_config = load_policy_yaml(config_text)
        validate_production_isolation(self.live_config)

        if self.kube.labeled_names(self.identity.resource_selector):
            self.fail("run-labeled Kubernetes resources already exist")
        self.filesystem.assert_absent(self.identity.download_root, self.identity.media_root)
        if self.filesystem.discover_recycle(self.identity.run_id):
            self.fail("run-owned recycle path already exists")

        self.connect_api_helper()
        assert self.qbit is not None
        validate_no_qbit_collisions(
            self.identity,
            self.qbit.info(FIXTURE_HASH),
            self.qbit.categories(),
            self.qbit.tags(),
        )

        self.ledger.category_attempted = True
        self.qbit.create_category(self.identity.category, self.identity.download_root)
        self.ledger.tags_attempted = True
        self.qbit.create_tags(self.identity.run_tag)

    def download(self) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        assert self.qbit is not None
        print(
            "Download: adding the legal Sintel fixture through the VPN-backed qBittorrent instance."
        )
        self.ledger.fixture_attempted = True
        self.ledger.download_path_attempted = True
        response = self.qbit.add(
            FIXTURE_URL,
            self.identity.download_root,
            self.identity.category,
            self.identity.category,
        )
        if response != "Ok.":
            raise ExternalDependencyFailure("qBittorrent rejected the public fixture URL")
        observed: tuple[list[dict[str, Any]], list[dict[str, Any]]] = ([], [])

        def complete() -> bool:
            nonlocal observed
            info = self.qbit.info(FIXTURE_HASH)
            if len(info) != 1:
                return False
            torrent = info[0]
            if not (
                torrent.get("hash") == FIXTURE_HASH
                and torrent.get("category") == self.identity.category
                and normalized_save_path(str(torrent.get("save_path", "")))
                == self.identity.download_root
                and torrent.get("progress") == 1
                and torrent.get("amount_left") == 0
            ):
                return False
            files = self.qbit.files(FIXTURE_HASH)
            if not files or not all(item.get("progress") == 1 for item in files):
                return False
            if not any(int(item.get("size", 0)) > 0 for item in files):
                return False
            observed = (info, files)
            return True

        if not self.wait_for(20 * 60, 10, complete):
            raise ExternalDependencyFailure(
                "Sintel did not complete through VPN egress within 20 minutes"
            )
        info, files = observed
        self.recorder.write_status(
            "external-dependency", "passed", "public fixture downloaded and verified complete"
        )
        self.recorder.phase(
            "download",
            {
                "status": "passed",
                "sizeBytes": int(info[0]["size"]),
                "completionOn": int(info[0]["completion_on"]),
                "fileCount": len(files),
            },
        )
        return info, files

    def classification(self) -> None:
        assert self.qbit is not None
        print(
            "Classification: waiting for the deployed 15-minute scheduler to add tracker-public."
        )

        def classified() -> bool:
            tags = self.torrent_tags(self.qbit.info(FIXTURE_HASH))
            return "tracker-public" in tags and "tracker-private" not in tags

        if not self.wait_for(20 * 60, 10, classified):
            self.fail("production scheduler did not classify the fixture public within 20 minutes")
        self.recorder.phase(
            "classification",
            {
                "status": "passed",
                "classifiedAt": utc_now(),
                "tags": ["tracker-public"],
            },
        )
        self.qbit.add_tags(FIXTURE_HASH, self.identity.run_tag)

    def representative_hardlink(self) -> None:
        assert self.qbit is not None and self.filesystem is not None
        files = self.qbit.files(FIXTURE_HASH)
        payloads = [
            item for item in files if int(item.get("size", 0)) > 0 and item.get("progress") == 1
        ]
        if not payloads:
            self.fail("fixture has no completed non-empty payload")
        payload = max(payloads, key=lambda item: int(item["size"]))
        relative = str(payload.get("name", ""))
        validate_relative_payload(relative)
        self.source_path = f"{self.identity.download_root}/{relative}"
        validate_owned_path(self.identity, self.source_path)

        self.ledger.media_path_attempted = True
        source_stats = self.filesystem.hardlink(self.source_path, self.identity.media_root)
        media_stats = self.filesystem.stats(self.identity.media_path)
        if not (
            source_stats[0] == media_stats[0]
            and source_stats[1] >= 2
            and media_stats[1] >= 2
            and source_stats[2:] == media_stats[2:]
        ):
            self.fail("representative import did not produce a verified hardlink")
        self.filesystem.write_sentinel(self.identity.sentinel_path, self.identity.run_id)
        self.media_before = media_stats
        self.recorder.phase(
            "hardlink",
            {
                "status": "passed",
                "sourcePath": self.source_path,
                "mediaPath": self.identity.media_path,
                "inode": source_stats[0],
                "initialLinkCount": source_stats[1],
                "sizeBytes": source_stats[2],
                "sha256": source_stats[3],
            },
        )

    def wait_for_job(self, name: str) -> None:
        def completed() -> bool:
            job = self.kube.get_json("job", name)
            conditions = {
                item.get("type"): item.get("status")
                for item in job.get("status", {}).get("conditions", [])
            }
            if conditions.get("Failed") == "True":
                raise AssertionFailure(
                    "qbit_manage one-shot Job failed; application logs were not collected"
                )
            return conditions.get("Complete") == "True"

        if not self.wait_for(120, 5, completed):
            self.fail("qbit_manage one-shot Job exceeded its two-minute deadline")

    def run_policy_job(self, phase: str, cleanup: bool) -> None:
        assert self.live_config is not None
        config = PolicyConfig.build(self.live_config, self.identity, cleanup)
        PolicyConfig.validate(config, self.identity, cleanup)
        config_name = f"qbm-e2e-{self.identity.run_id}-{phase}"
        config_text = dump_policy_yaml(config)
        atomic_write_text(self.recorder.manifest_path(f"{phase}-config.yml"), config_text)
        labels = {
            "homelab-talos/e2e-run": self.identity.run_id,
            "homelab-talos/e2e-target": "qbit-manage-policy",
        }
        config_map = {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": config_name,
                "namespace": NAMESPACE,
                "labels": labels,
            },
            "data": {"config.yml": config_text},
        }
        config_path = self.recorder.write_manifest(f"{phase}-configmap.json", config_map)
        job_path = self.recorder.write_manifest(
            f"{phase}-job.json",
            job_manifest(self.identity, phase, self.qbm_image, config_name),
        )
        self.kube.apply(config_path)
        self.kube.apply(job_path)
        self.wait_for_job(config_name)
        self.recorder.job(phase, config_name)
        self.kube.call(
            "delete",
            "job",
            config_name,
            "--ignore-not-found=true",
            "--wait=true",
            "--timeout=2m",
            timeout=150,
        )
        self.kube.call(
            "delete",
            "configmap",
            config_name,
            "--ignore-not-found=true",
            "--wait=true",
            "--timeout=2m",
            timeout=150,
        )

    def private_exclusion(self) -> None:
        assert self.qbit is not None and self.filesystem is not None
        print("Private exclusion: proving tracker-private prevents the isolated cleanup policy.")
        self.qbit.add_tags(FIXTURE_HASH, "tracker-private")
        tags = self.torrent_tags(self.qbit.info(FIXTURE_HASH))
        if "tracker-private" not in tags or self.identity.run_tag not in tags:
            self.fail("private-exclusion premise was absent immediately before the Job")
        self.run_policy_job("private", True)
        info = self.qbit.info(FIXTURE_HASH)
        if len(info) != 1 or info[0].get("category") != self.identity.category:
            self.fail("private fixture was removed or recategorized")
        if self.identity.limit_tag in self.torrent_tags(info):
            self.fail("private fixture incorrectly received the isolated limit tag")
        if not self.filesystem.exists_all(
            self.source_path,
            self.identity.media_path,
            self.identity.sentinel_path,
        ):
            self.fail("private exclusion did not preserve all run-owned files")
        self.qbit.remove_tags(FIXTURE_HASH, "tracker-private")
        tags = self.torrent_tags(self.qbit.info(FIXTURE_HASH))
        if "tracker-private" in tags or self.identity.run_tag not in tags:
            self.fail("failed to remove only the temporary private tag")
        self.recorder.phase("privateExclusion", {"status": "passed"})

    def limits(self) -> None:
        assert self.qbit is not None and self.filesystem is not None
        print("Limits: applying the isolated two-minute stop policy without cleanup.")
        self.run_policy_job("limits", False)
        observed: list[dict[str, Any]] = []

        def applied() -> bool:
            nonlocal observed
            info = self.qbit.info(FIXTURE_HASH)
            if len(info) != 1:
                return False
            torrent = info[0]
            ratio = float(torrent.get("ratio_limit", -1))
            if (
                torrent.get("category") == self.identity.category
                and 0.009999 <= ratio <= 0.010001
                and torrent.get("seeding_time_limit") == 120
                and torrent.get("state") in {"stoppedUP", "pausedUP"}
                and self.identity.limit_tag in self.torrent_tags(info)
            ):
                observed = info
                return True
            return False

        if not self.wait_for(3 * 60, 5, applied):
            self.fail("qbit_manage limits/tag/Stop state were not observed within three minutes")
        if not self.filesystem.exists_all(
            self.source_path,
            self.identity.media_path,
            self.identity.sentinel_path,
        ):
            self.fail("limit application removed run-owned files before cleanup")
        self.recorder.phase(
            "limits",
            {
                "status": "passed",
                "ratioLimit": 0.01,
                "seedingTimeLimitSeconds": 120,
                "state": observed[0]["state"],
            },
        )

    def cleanup_policy(self) -> None:
        assert (
            self.qbit is not None and self.filesystem is not None and self.media_before is not None
        )
        print("Cleanup: running the recycle-bin policy and verifying hardlink survival.")
        self.ledger.recycle_attempted = True
        self.run_policy_job("cleanup", True)
        if not self.wait_for(60, 5, lambda: not self.qbit.info(FIXTURE_HASH)):
            self.fail("cleanup Job did not remove the owned torrent")
        if self.filesystem.exists_all(self.source_path):
            self.fail("cleanup did not remove the payload-side path")
        if not self.filesystem.exists_all(self.identity.media_path, self.identity.sentinel_path):
            self.fail("cleanup removed the media hardlink or unrelated sentinel")
        recycle_before = self.filesystem.discover_recycle(self.identity.run_id)
        if not recycle_before:
            self.fail("cleanup did not create run-owned recycle-bin data")
        for path in recycle_before:
            validate_owned_path(self.identity, path)
        media_after = self.filesystem.stats(self.identity.media_path)
        if (
            media_after[0] != self.media_before[0]
            or media_after[2] != self.media_before[2]
            or media_after[3] != self.media_before[3]
        ):
            self.fail("media hardlink inode, size, or digest changed during cleanup")

        self.run_policy_job("cleanup2", True)
        if self.qbit.info(FIXTURE_HASH):
            self.fail("idempotent cleanup unexpectedly recreated the torrent")
        recycle_after = self.filesystem.discover_recycle(self.identity.run_id)
        if recycle_after != recycle_before:
            self.fail("idempotent cleanup created a duplicate recycle entry")
        self.recorder.phase(
            "cleanup",
            {
                "status": "passed",
                "mediaPostCleanupLinkCount": media_after[1],
                "recyclePaths": recycle_after,
            },
        )

    def run(self) -> None:
        self.preflight()
        self.download()
        self.classification()
        self.representative_hardlink()
        self.private_exclusion()
        self.limits()
        self.cleanup_policy()
        self.recorder.write_status(
            "assertion",
            "passed",
            "classification, private exclusion, limits, recycle cleanup, hardlink survival, and idempotency passed",
        )
        print(
            f"PASS: qbit_manage real-download policy E2E completed for owned run "
            f"{self.identity.run_id}. Evidence: {self.run_dir}"
        )

    def teardown(self) -> bool:
        return Teardown(
            self.identity,
            self.ledger,
            self.recorder,
            self.kube,
            qbit=self.qbit,
            filesystem=self.filesystem,
        ).run()


def build_run_dir(repo_root: Path) -> Path:
    configured = os.environ.get("HOMELAB_TEST_RUN_DIR", "")
    if configured:
        run_dir = Path(configured).resolve()
        run_dir.mkdir(parents=True, exist_ok=True)
        return run_dir
    results = repo_root / ".test-results"
    results.mkdir(parents=True, exist_ok=True)
    revision = run_command(["git", "rev-parse", "--short=12", "HEAD"]).strip()
    timestamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    return Path(tempfile.mkdtemp(prefix=f"{timestamp}-{revision}-qbm-policy.", dir=results))


def require_confirmation() -> None:
    expected = "e2e:qbit-manage-policy"
    if os.environ.get("CLUSTER_E2E_CONFIRM") != expected:
        raise ScenarioFailure(f"refusing state-changing E2E: set CLUSTER_E2E_CONFIRM={expected}")


def install_termination_handler() -> None:
    def terminate(signum: int, _frame: Any) -> None:
        raise TerminationRequested(f"received signal {signum}")

    signal.signal(signal.SIGTERM, terminate)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kubeconfig", help="guarded live-cluster kubeconfig path")
    args = parser.parse_args(argv)
    try:
        require_confirmation()
        repo_root = Path(run_command(["git", "rev-parse", "--show-toplevel"]).strip()).resolve()
        os.chdir(repo_root)
        run_dir = build_run_dir(repo_root)
        scenario = Scenario(repo_root, args.kubeconfig, run_dir)
        install_termination_handler()
    except Exception as error:  # noqa: BLE001 - sanitize initialization failures
        print(f"qbit_manage policy E2E could not initialize: {error}", file=sys.stderr)
        return 1

    primary_ok = False
    try:
        scenario.run()
        primary_ok = True
    except ExternalDependencyFailure as error:
        scenario.recorder.write_status("external-dependency", "failed", str(error))
        scenario.recorder.write_status(
            "assertion",
            "not-classified",
            "workflow stopped at the external fixture dependency",
        )
        print(f"External dependency failure: {error}", file=sys.stderr)
    except AssertionFailure as error:
        scenario.recorder.write_status("assertion", "failed", str(error))
        print(f"Assertion failure: {error}", file=sys.stderr)
    except (KeyboardInterrupt, TerminationRequested):
        scenario.recorder.write_status(
            "assertion", "failed", "operator interrupted the E2E workflow"
        )
        print("Operator interrupted the E2E workflow; running exact teardown.", file=sys.stderr)
    except ScenarioFailure as error:
        scenario.recorder.write_status("assertion", "failed", str(error))
        print(f"Scenario failure: {error}", file=sys.stderr)
    except Exception:  # noqa: BLE001 - sanitize unexpected failures before teardown
        scenario.recorder.write_status(
            "assertion", "failed", "unexpected orchestrator or infrastructure failure"
        )
        print(
            "Unexpected orchestrator or infrastructure failure; sensitive subprocess output was suppressed.",
            file=sys.stderr,
        )
    try:
        cleanup_ok = scenario.teardown()
    except Exception:  # noqa: BLE001 - teardown reporting itself must fail closed
        cleanup_ok = False
        print(
            "Exact teardown encountered an unexpected failure; inspect recovery artifacts before rerunning.",
            file=sys.stderr,
        )
        try:
            reason = (
                f"manual check required for run {scenario.identity.run_id}: "
                f"{scenario.identity.download_root}, {scenario.identity.media_root}, "
                "and run-labeled media resources"
            )
            scenario.recorder.write_status("cleanup", "failed", reason)
            scenario.recorder.write_status("recovery", "failed", reason)
        except Exception:  # noqa: BLE001, S110 - no safe secondary recovery remains
            pass
    return 0 if primary_ok and cleanup_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
