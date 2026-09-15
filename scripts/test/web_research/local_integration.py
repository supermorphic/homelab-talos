#!/usr/bin/env python3
"""Run the disposable, container-native web-research acceptance workflow."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import yaml
from gateway_fixture import translate

OWNER_LABEL = "homelab-talos.test-run"
GATUS_CHART_VERSION = "1.5.0"
GATUS_IMAGE = (
    "ghcr.io/twin/gatus:v5.34.0@"
    "sha256:3fff895e77d35ee62e898860f4613755bc2344127d93e3f326429d40270e2115"
)


class AcceptanceFailure(RuntimeError):
    """A fixed-label local acceptance failure."""


class WorkflowFailures(RuntimeError):
    """Preserve primary and cleanup failures without formatting their messages."""

    def __init__(self, primary: BaseException | None, cleanup: BaseException | None) -> None:
        self.primary = primary
        self.cleanup = cleanup
        super().__init__("local acceptance failed")


def failure_phase(error: BaseException, fallback: str) -> str:
    phase = error.args[0] if isinstance(error, AcceptanceFailure) and error.args else fallback
    return re.sub(r"[^a-z0-9-]", "-", str(phase).lower())[:64]


def failure_lines(failures: WorkflowFailures) -> list[str]:
    lines = []
    if failures.primary is not None:
        lines.append(
            f"FAIL primary {failure_phase(failures.primary, 'workflow')} "
            f"({type(failures.primary).__name__})"
        )
    if failures.cleanup is not None:
        lines.append(
            f"FAIL cleanup {failure_phase(failures.cleanup, 'exact-cleanup')} "
            f"({type(failures.cleanup).__name__})"
        )
    return lines


def raise_workflow_failures(primary: BaseException | None, cleanup: BaseException | None) -> None:
    if primary is not None or cleanup is not None:
        raise WorkflowFailures(primary, cleanup)


def load_yaml(path: Path) -> list[dict]:
    return [item for item in yaml.safe_load_all(path.read_text()) if item]


def deployment_image(path: Path, container: str) -> str:
    document = next(item for item in load_yaml(path) if item["kind"] == "Deployment")
    containers = document["spec"]["template"]["spec"]["containers"]
    return next(item["image"] for item in containers if item["name"] == container)


def envoy_image(path: Path) -> str:
    document = next(item for item in load_yaml(path) if item["kind"] == "EnvoyProxy")
    return document["spec"]["provider"]["kubernetes"]["envoyDeployment"]["container"]["image"]


class PodmanRun:
    def __init__(self, root: Path, directory: Path):
        self.root = root
        self.directory = directory
        self.owner = f"web-research-local-{uuid.uuid4().hex[:16]}"
        self.network = f"{self.owner}-network"
        self.containers: list[str] = []
        self.network_created = False

    def command(
        self,
        *arguments: str,
        capture: bool = False,
        timeout: float | None = None,
        stdin: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["podman", *arguments],
            input=stdin,
            text=True,
            check=True,
            timeout=timeout,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
        )

    def inspect_label(self, kind: str, name: str) -> str:
        if kind == "container":
            template = f'{{{{ index .Config.Labels "{OWNER_LABEL}" }}}}'
            return self.command("inspect", "--format", template, name, capture=True).stdout.strip()
        template = f'{{{{ index .Labels "{OWNER_LABEL}" }}}}'
        return self.command(
            "network", "inspect", "--format", template, name, capture=True
        ).stdout.strip()

    def exists(self, kind: str, name: str) -> bool:
        arguments = (
            ["container", "exists", name] if kind == "container" else ["network", "exists", name]
        )
        result = subprocess.run(
            ["podman", *arguments],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode not in (0, 1):
            raise AcceptanceFailure("resource-inspection")
        return result.returncode == 0

    def create_network(self) -> None:
        if self.exists("network", self.network):
            raise AcceptanceFailure("resource-collision")
        self.network_created = True
        self.command("network", "create", "--label", f"{OWNER_LABEL}={self.owner}", self.network)

    def run_container(self, name: str, arguments: list[str]) -> None:
        if self.exists("container", name):
            raise AcceptanceFailure("resource-collision")
        self.containers.append(name)
        self.command(
            "run",
            "--detach",
            "--name",
            name,
            "--label",
            f"{OWNER_LABEL}={self.owner}",
            *arguments,
        )

    def exec_fixture(self, native: str, mode: str, timeout: float) -> None:
        result = self.command(
            "exec",
            "-i",
            native,
            "python3",
            "/opt/test/native_fixture.py",
            mode,
            capture=True,
            timeout=timeout,
            stdin="",
        )
        expected = {
            "readiness": "PASS native-readiness",
            "metrics": "PASS credential-agent-metrics-capture",
            "gateway": "PASS translated-gateway-contract",
            "rotation": "PASS credential-rotation-contract",
            "searx": "PASS searxng-contract",
            "gatus": "PASS gatus-production-conditions",
        }[mode]
        lines = [line for line in result.stdout.splitlines() if line.startswith("PASS ")]
        if lines != [expected]:
            raise AcceptanceFailure(f"{mode}-output")
        print(lines[0], flush=True)

    def cleanup(self) -> None:
        failed = False
        for name in reversed(self.containers):
            try:
                if self.exists("container", name):
                    if self.inspect_label("container", name) != self.owner:
                        failed = True
                        continue
                    self.command("rm", "--force", name)
                    if self.exists("container", name):
                        failed = True
            except (AcceptanceFailure, subprocess.SubprocessError):
                failed = True
        if self.network_created:
            try:
                if self.exists("network", self.network):
                    if self.inspect_label("network", self.network) != self.owner:
                        failed = True
                    else:
                        self.command("network", "rm", self.network)
                        if self.exists("network", self.network):
                            failed = True
            except (AcceptanceFailure, subprocess.SubprocessError):
                failed = True
        if failed:
            raise AcceptanceFailure("exact-cleanup")


def verify_host(images: list[str]) -> None:
    if sys.platform not in ("darwin", "linux"):
        raise AcceptanceFailure("unsupported-platform")
    if subprocess.run(
        ["podman", "info"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode:
        raise AcceptanceFailure("podman-unavailable")
    for image in images:
        if subprocess.run(
            ["podman", "image", "exists", image],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode:
            raise AcceptanceFailure("pinned-image-unavailable")


def verify_gatus_chart(root: Path) -> None:
    release = load_yaml(root / "kubernetes/apps/monitoring/gatus/app/helmrelease.yaml")[0]
    version = release["spec"]["chart"]["spec"]["version"]
    if version != GATUS_CHART_VERSION:
        raise AcceptanceFailure("gatus-chart-version")
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "gatus",
            "gatus",
            "--repo",
            "https://twin.github.io/helm-charts",
            "--version",
            version,
            "--namespace",
            "gatus",
            "--values",
            str(root / "kubernetes/apps/monitoring/gatus/app/values.yaml"),
        ],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=60,
    ).stdout
    deployments = [
        item for item in yaml.safe_load_all(rendered) if item and item.get("kind") == "Deployment"
    ]
    images = [
        container["image"]
        for item in deployments
        for container in item["spec"]["template"]["spec"]["containers"]
    ]
    if images != ["twinproduction/gatus:v5.34.0"] or ":v5.34.0@" not in GATUS_IMAGE:
        raise AcceptanceFailure("gatus-production-image")


def write_gatus_config(root: Path, destination: Path) -> None:
    source = load_yaml(root / "kubernetes/apps/web-research/monitoring/gatus-endpoints.yaml")[0]
    endpoints = source["config"]["endpoints"]
    urls = {
        "searxng": "http://searxng:8080/healthz",
        "crawl4ai-readiness": "http://native:9001/readyz",
        "crawl4ai-e2e": "http://native:8080/crawl",
        "searxng-search-e2e": "http://searxng:8080/search?q=example%20domain&format=json",
    }
    if {endpoint["name"] for endpoint in endpoints} != set(urls):
        raise AcceptanceFailure("gatus-endpoint-set")
    for endpoint in endpoints:
        endpoint["url"] = urls[endpoint["name"]]
        endpoint["interval"] = "1h"
    destination.write_text(
        yaml.safe_dump(
            {
                "endpoints": endpoints,
                "metrics": True,
                "storage": {"type": "memory"},
                "web": {"port": 8080},
            }
        )
    )
    destination.chmod(0o444)


def assert_container(
    run: PodmanRun, name: str, memory: int, shared_with: str | None = None
) -> None:
    document = json.loads(run.command("inspect", name, capture=True).stdout)[0]
    if document["Config"]["Labels"].get(OWNER_LABEL) != run.owner:
        raise AcceptanceFailure("container-ownership")
    if document["HostConfig"]["Memory"] != memory:
        raise AcceptanceFailure("container-memory")
    if document["HostConfig"].get("PortBindings"):
        raise AcceptanceFailure("public-port-binding")
    if shared_with and document["HostConfig"]["NetworkMode"] != f"container:{shared_with}":
        # Podman can canonicalize the container name to its ID.
        target_id = run.command(
            "inspect", "--format", "{{.Id}}", shared_with, capture=True
        ).stdout.strip()
        if document["HostConfig"]["NetworkMode"] != f"container:{target_id}":
            raise AcceptanceFailure("envoy-network-sharing")


def execute(root: Path, directory: Path) -> None:
    native_image = deployment_image(
        root / "kubernetes/apps/web-research/crawl4ai/app/deployment.yaml", "crawl4ai"
    )
    proxy_image = envoy_image(root / "kubernetes/apps/web-research/crawl4ai/proxy/envoyproxy.yaml")
    searx_image = deployment_image(
        root / "kubernetes/apps/web-research/searxng/app/deployment.yaml", "searxng"
    )
    images = [native_image, proxy_image, searx_image, GATUS_IMAGE]
    verify_host(images)
    verify_gatus_chart(root)
    print("PASS pinned-runtime-preflight", flush=True)

    envoy_config = translate(root, directory)
    gatus_config = directory / "gatus.yaml"
    write_gatus_config(root, gatus_config)
    print("PASS production-fixture-translation", flush=True)

    run = PodmanRun(root, directory)
    native = f"{run.owner}-native"
    envoy = f"{run.owner}-envoy"
    searx = f"{run.owner}-searxng"
    gatus = f"{run.owner}-gatus"
    fixture = root / "scripts/test/web_research/native_fixture.py"
    runtime = root / "kubernetes/apps/web-research/crawl4ai/runtime"
    settings = root / "kubernetes/apps/web-research/searxng/app/settings.yml"
    failure: BaseException | None = None
    try:
        run.create_network()
        run.run_container(
            native,
            [
                "--network",
                run.network,
                "--network-alias",
                "native",
                "--user",
                "999:999",
                "--memory",
                "2g",
                "--shm-size",
                "256m",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--tmpfs",
                "/run/bootstrap:mode=1777",
                "--tmpfs",
                "/run/crawl4ai:mode=1777",
                "--mount",
                f"type=bind,src={runtime},dst=/opt/platform,ro=true",
                "--mount",
                f"type=bind,src={fixture},dst=/opt/test/native_fixture.py,ro=true",
                native_image,
                "python3",
                "/opt/test/native_fixture.py",
                "serve",
            ],
        )
        run.exec_fixture(native, "readiness", 210)
        run.exec_fixture(native, "metrics", 30)
        metrics = run.command(
            "exec",
            "-i",
            native,
            "cat",
            "/run/crawl4ai/agent-metrics.prom",
            capture=True,
            timeout=10,
            stdin="",
        ).stdout
        subprocess.run(
            ["promtool", "check", "metrics"],
            input=metrics,
            text=True,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        print("PASS credential-agent-metrics-schema", flush=True)

        run.run_container(
            envoy,
            [
                "--network",
                f"container:{native}",
                "--memory",
                "256m",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--mount",
                f"type=bind,src={envoy_config},dst=/etc/envoy/envoy.yaml,ro=true",
                proxy_image,
                "--config-path",
                "/etc/envoy/envoy.yaml",
                "--concurrency",
                "2",
                "--disable-hot-restart",
                "--log-level",
                "critical",
            ],
        )
        assert_container(run, native, 2 * 1024**3)
        assert_container(run, envoy, 256 * 1024**2, native)
        run.exec_fixture(native, "gateway", 240)
        run.exec_fixture(native, "rotation", 300)

        run.run_container(
            searx,
            [
                "--network",
                run.network,
                "--network-alias",
                "searxng",
                "--user",
                "977:977",
                "--memory",
                "512m",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--tmpfs",
                "/tmp:mode=1777",
                "--tmpfs",
                "/var/cache/searxng:mode=1777",
                "--mount",
                f"type=bind,src={settings},dst=/etc/searxng/settings.yml,ro=true",
                "--env",
                "GRANIAN_HOST=0.0.0.0",
                "--env",
                "GRANIAN_PORT=8080",
                "--env",
                "GRANIAN_WORKERS=1",
                "--env",
                "GRANIAN_LOG_LEVEL=error",
                "--entrypoint",
                "/bin/sh",
                searx_image,
                "-ec",
                (
                    "export SEARXNG_SECRET=$(python3 -c 'import secrets; "
                    "print(secrets.token_hex(32))'); "
                    "exec /usr/local/searxng/entrypoint.sh >/dev/null 2>&1"
                ),
            ],
        )
        assert_container(run, searx, 512 * 1024**2)
        run.exec_fixture(native, "searx", 180)

        run.run_container(
            gatus,
            [
                "--network",
                run.network,
                "--network-alias",
                "gatus",
                "--memory",
                "128m",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--mount",
                f"type=bind,src={gatus_config},dst=/config/config.yaml,ro=true",
                "--env",
                "GATUS_CONFIG_PATH=/config/config.yaml",
                GATUS_IMAGE,
            ],
        )
        assert_container(run, gatus, 128 * 1024**2)
        run.exec_fixture(native, "gatus", 240)
    except BaseException as error:  # noqa: BLE001 - cleanup must run on interruption.
        failure = error
    cleanup_failure: BaseException | None = None
    try:
        run.cleanup()
    except BaseException as error:  # noqa: BLE001 - preserve cleanup proof separately.
        cleanup_failure = error
    raise_workflow_failures(failure, cleanup_failure)
    print("PASS exact-owned-cleanup", flush=True)


def main() -> int:
    root = Path(
        subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    )
    if Path.cwd().resolve() != root.resolve():
        os.chdir(root)
    (root / ".tmp").mkdir(exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(
            prefix="web-research-local-", dir=root / ".tmp"
        ) as directory:
            execute(root, Path(directory))
    except WorkflowFailures as errors:
        for line in failure_lines(errors):
            print(line, file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - redact every boundary failure.
        print(
            f"FAIL primary {failure_phase(error, 'workflow')} ({type(error).__name__})",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
