#!/usr/bin/env python3
"""Offline contract tests for the read-only recovery verifier."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import tarfile
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts/verify/recovery.py"


def load_module():
    spec = importlib.util.spec_from_file_location("recovery_verifier", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load recovery verifier")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RecoveryContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.kubeconfig = base / "kubeconfig"
        self.talosconfig = base / "talosconfig"
        self.kubeconfig.write_text(
            "apiVersion: v1\nkind: Config\ncontexts:\n  - name: fixture\n    context: {cluster: fixture, user: fixture}\n",
            encoding="utf-8",
        )
        self.talosconfig.write_text(
            "context: ambient\ncontexts:\n  fixture: {endpoints: [192.0.2.10]}\n  ambient: {endpoints: [192.0.2.11]}\n",
            encoding="utf-8",
        )
        self.source = base / "source"
        (self.source / "talos").mkdir(parents=True)
        (self.source / "talos/talconfig.yaml").write_text(
            "endpoint: https://192.0.2.20:6443\n"
            "nodes:\n"
            "  - hostname: node-a\n    ipAddress: 192.0.2.10\n    controlPlane: true\n"
            "  - hostname: node-b\n    ipAddress: 192.0.2.11\n    controlPlane: true\n"
            "  - hostname: node-c\n    ipAddress: 192.0.2.12\n    controlPlane: true\n",
            encoding="utf-8",
        )
        chart_sources = {
            "kubernetes/apps/kube-system/cilium/app/ocirepository.yaml": "spec: {ref: {tag: 1.2.3}}\n",
            "kubernetes/apps/security/cert-manager/app/ocirepository.yaml": "spec: {ref: {tag: v1.2.3}}\n",
            "kubernetes/apps/networking/metallb/app/helmrelease.yaml": "spec: {chart: {spec: {version: 1.2.3}}}\n",
            "kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml": "spec: {ref: {tag: 1.2.3}}\n",
            "kubernetes/apps/networking/external-dns/app/helmrelease.yaml": "spec: {chart: {spec: {version: 1.2.3}}}\n",
        }
        for relative, content in chart_sources.items():
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=self.source, check=True)
        subprocess.run(["git", "add", "."], cwd=self.source, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            cwd=self.source,
            check=True,
        )
        self.request = {
            "schemaVersion": 1,
            "requestId": str(uuid.uuid4()),
            "mode": "prepare",
            "node": "node-a",
            "sourceRevision": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=self.source, text=True
            ).strip(),
            "apiServer": "https://192.0.2.20:6443",
            "nodes": {
                "node-a": "192.0.2.10",
                "node-b": "192.0.2.11",
                "node-c": "192.0.2.12",
            },
            "talosEndpoints": ["192.0.2.10", "192.0.2.11", "192.0.2.12"],
            "credentials": {
                "kubeconfig": str(self.kubeconfig),
                "kubeContext": "fixture",
                "talosconfig": str(self.talosconfig),
                "talosContext": "fixture",
            },
            "expectedContainment": None,
            "timeoutSeconds": 30,
        }

    def make_chart_cache(self, source: Path, revision: str) -> Path:
        module = load_module()
        cache = Path(self.temp.name) / f"cache-{revision[:8]}"
        cache.mkdir()
        charts = {}
        for logical, (chart_name, version) in module.expected_charts(source).items():
            archive = cache / f"{logical}.tgz"
            payload = f"name: {chart_name}\nversion: {version}\n".encode()
            with tarfile.open(archive, "w:gz") as bundle:
                info = tarfile.TarInfo(f"{chart_name}/Chart.yaml")
                info.size = len(payload)
                bundle.addfile(info, io.BytesIO(payload))
                if logical == "metallb":
                    dependency = b"name: frr-k8s\nversion: 0.0.1\n"
                    dependency_info = tarfile.TarInfo(f"{chart_name}/charts/frr-k8s/Chart.yaml")
                    dependency_info.size = len(dependency)
                    bundle.addfile(dependency_info, io.BytesIO(dependency))
            charts[logical] = {
                "file": archive.name,
                "chartName": chart_name,
                "version": version,
                "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
            }
        (cache / "manifest.json").write_text(
            json.dumps({"schemaVersion": 1, "sourceRevision": revision, "charts": charts}),
            encoding="utf-8",
        )
        return cache

    def test_accepts_literal_prepare_request(self) -> None:
        module = load_module()
        validated = module.validate_request(self.request, self.source)
        self.assertEqual(validated["mode"], "prepare")

    def test_rejects_unknown_and_duplicate_keys(self) -> None:
        module = load_module()
        bad = dict(self.request, callback="/tmp/run-me")
        with self.assertRaises(module.ContractError):
            module.validate_request(bad, self.source)
        encoded = json.dumps(self.request)[:-1] + ',"mode":"baseline"}'
        with self.assertRaises(module.ContractError):
            module.load_request_text(encoded)

    def test_rejects_missing_explicit_context_and_wrong_source_revision(self) -> None:
        module = load_module()
        bad_context = json.loads(json.dumps(self.request))
        bad_context["credentials"]["kubeContext"] = "missing"
        with self.assertRaises(module.ContractError):
            module.validate_request(bad_context, self.source)
        bad_revision = dict(self.request, sourceRevision="0" * 40)
        with self.assertRaises(module.ContractError):
            module.validate_request(bad_revision, self.source)

    def test_rejects_dirty_selected_source(self) -> None:
        module = load_module()
        with (self.source / "talos/talconfig.yaml").open("a", encoding="utf-8") as stream:
            stream.write("# unreviewed change\n")
        with self.assertRaises(module.ContractError):
            module.validate_request(self.request, self.source)

    def test_recovery_requires_exact_schema_one_record(self) -> None:
        module = load_module()
        request = dict(self.request)
        request["mode"] = "recovery"
        request["expectedContainment"] = {
            "node": "node-a",
            "record": '{"schemaVersion":1,"kind":"reboot"}',
        }
        validated = module.validate_request(request, self.source)
        self.assertEqual(validated["expectedContainment"]["node"], "node-a")
        request["expectedContainment"] = {
            "node": "node-a",
            "record": '{"schemaVersion":1,"kind":"reboot","extra":true}',
        }
        with self.assertRaises(module.ContractError):
            module.validate_request(request, self.source)

    def test_schema_version_boolean_and_wrong_maintenance_during_values_fail(self) -> None:
        module = load_module()
        request = dict(self.request)
        request["mode"] = "recovery"
        invalid_records = [
            '{"schemaVersion":true,"kind":"reboot"}',
            '{"schemaVersion":true,"kind":"maintenance","longhorn":{"allowScheduling":{"before":true,"during":false},"evictionRequested":{"before":false,"during":true}}}',
            '{"schemaVersion":1,"kind":"maintenance","longhorn":{"allowScheduling":{"before":true,"during":true},"evictionRequested":{"before":false,"during":true}}}',
            '{"schemaVersion":1,"kind":"maintenance","longhorn":{"allowScheduling":{"before":true,"during":false},"evictionRequested":{"before":false,"during":false}}}',
        ]
        for record in invalid_records:
            with self.subTest(record=record):
                request["expectedContainment"] = {"node": "node-a", "record": record}
                with self.assertRaises(module.ContractError):
                    module.validate_request(request, self.source)

    def test_timeout_terminates_and_waits_for_process_group(self) -> None:
        module = load_module()
        pid_file = Path(self.temp.name) / "child.pid"
        command = [
            "bash",
            "-c",
            f"sleep 30 & echo $! > {pid_file}; wait",
        ]
        with self.assertRaises(subprocess.TimeoutExpired):
            module.run_supervised(command, cwd=self.source, env=os.environ.copy(), timeout=1)
        child_pid = int(pid_file.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, signal.SIGCONT)

    def test_chart_cache_rejects_missing_archive_and_digest_drift(self) -> None:
        module = load_module()
        cache = self.make_chart_cache(self.source, self.request["sourceRevision"])
        module.validate_chart_cache(self.request, self.source, cache)
        (cache / "cilium.tgz").write_bytes(b"changed")
        with self.assertRaises(module.ContractError):
            module.validate_chart_cache(self.request, self.source, cache)
        (cache / "cilium.tgz").unlink()
        with self.assertRaises(module.ContractError):
            module.validate_chart_cache(self.request, self.source, cache)

    def test_chart_cache_rejects_unexpected_entries(self) -> None:
        module = load_module()
        cache = self.make_chart_cache(self.source, self.request["sourceRevision"])
        (cache / "unexpected").write_text("not part of the prepared cache\n", encoding="utf-8")
        with self.assertRaises(module.ContractError):
            module.validate_chart_cache(self.request, self.source, cache)

    def test_expired_deadline_starts_no_subprocess(self) -> None:
        module = load_module()
        cache = self.make_chart_cache(self.source, self.request["sourceRevision"])
        request = dict(self.request, mode="baseline")
        with (
            mock.patch.dict(os.environ, {"RECOVERY_HELM_CACHE": str(cache)}),
            mock.patch.object(module, "run_supervised") as run_supervised,
            self.assertRaises(module.ContractError),
        ):
            module._run_checks(request, self.source, module.time.monotonic() - 1)
        run_supervised.assert_not_called()

    def test_chart_identity_rejects_duplicate_root_and_traversal(self) -> None:
        module = load_module()
        for case, names in {
            "duplicate": ["chart/Chart.yaml", "chart/Chart.yaml"],
            "traversal": ["../Chart.yaml"],
        }.items():
            with self.subTest(case=case):
                archive = Path(self.temp.name) / f"{case}.tgz"
                payload = b"name: chart\nversion: 1.2.3\n"
                with tarfile.open(archive, "w:gz") as bundle:
                    for name in names:
                        info = tarfile.TarInfo(name)
                        info.size = len(payload)
                        bundle.addfile(info, io.BytesIO(payload))
                with self.assertRaises(module.ContractError):
                    module._archive_identity(archive)

    def test_node_state_modes_have_distinct_containment_rules(self) -> None:
        module = load_module()
        record = '{"schemaVersion":1,"kind":"reboot"}'
        healthy = [
            module.NodeState(name=name, ready=True, unschedulable=False, record="")
            for name in self.request["nodes"]
        ]
        module.validate_node_states(self.request, healthy)
        recovery = dict(self.request)
        recovery["mode"] = "recovery"
        recovery["expectedContainment"] = {"node": "node-a", "record": record}
        contained = list(healthy)
        contained[0] = module.NodeState(
            name="node-a", ready=True, unschedulable=True, record=record
        )
        module.validate_node_states(recovery, contained)
        with self.assertRaises(module.ContractError):
            module.validate_node_states(self.request, contained)
        contained[1] = module.NodeState(name="node-b", ready=True, unschedulable=True, record="")
        with self.assertRaises(module.ContractError):
            module.validate_node_states(recovery, contained)

    def test_prepare_response_has_only_source_passed(self) -> None:
        module = load_module()
        response = module._response(self.request, False)
        self.assertEqual(response["requestId"], self.request["requestId"])
        self.assertEqual(
            response["checks"],
            {"source": "passed", "cilium": "not-run", "foundation": "not-run"},
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
