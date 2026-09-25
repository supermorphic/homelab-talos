"""Snapshot behavior against synthetic OpenBao archives; no live credentials."""

import errno
import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch
import yaml


SOURCE = Path("kubernetes/apps/security/openbao/backup/scripts/snapshot.py")
SPEC = importlib.util.spec_from_file_location("openbao_snapshot", SOURCE)
snapshot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(snapshot)
NOW = datetime(2026, 9, 25, 1, 0, tzinfo=timezone.utc)
MARKER = "synthetic-request-token-do-not-retain"


def archive(index=42, state=b"synthetic raft state", corrupt=False, recorded_size=None,
            sealed=True):
    meta = json.dumps({"Index": index, "Size": len(state) if recorded_size is None else recorded_size}).encode()
    sums = b"".join(hashlib.sha256(data).hexdigest().encode() + b"  " + name.encode() + b"\n"
                    for name, data in (("meta.json", meta), ("state.bin", state)))
    if corrupt:
        sums = sums.replace(sums[:1], b"0" if sums[:1] != b"0" else b"1", 1)
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as tar:
        files = [("meta.json", meta), ("state.bin", state), ("SHA256SUMS", sums)]
        if sealed:
            files.append(("SHA256SUMS.sealed", b"synthetic-seal"))
        for name, data in files:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return output.getvalue()


class Client:
    def __init__(self, payload=None):
        self.payload = payload or archive()
        self.leaders = ["openbao-0"] * 4
        self.version_value = "2.7.0"

    def leader(self):
        return self.leaders.pop(0)

    def version(self, peer):
        return self.version_value

    def download(self, peer, output, limit):
        if len(self.payload) > limit:
            raise snapshot.SnapshotError("download-failed")
        output.write(self.payload)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_snapshot(self, client=None, clock=lambda: NOW):
        return snapshot.run(client or Client(), self.root, clock)

    def test_installs_valid_pair_with_sanitized_metadata(self):
        result = self.run_snapshot()
        self.assertEqual(set(result), {"created_at", "openbao_version", "raft_index",
                                       "seal_key_id", "recovery_generation", "sha256"})
        self.assertEqual(result["raft_index"], 42)
        pair = self.root / ("snapshot-" + result["created_at"].replace(":", ""))
        self.assertEqual(hashlib.sha256((pair / "raft.snap").read_bytes()).hexdigest(), result["sha256"])
        self.assertEqual(json.loads((pair / "metadata.json").read_text()), result)
        self.assertEqual((self.root / "latest").read_text().strip(), pair.name)

    def test_accepts_upstream_archive_without_optional_sealed_hash(self):
        self.assertEqual(self.run_snapshot(Client(archive(sealed=False)))["raft_index"], 42)

    def test_leader_switch_retries_only_once_with_new_leader(self):
        client = Client()
        client.leaders = ["openbao-0", "openbao-1", "openbao-1", "openbao-1"]
        self.assertEqual(self.run_snapshot(client)["raft_index"], 42)

    def test_failed_download_rechecks_leader_then_retries_new_member(self):
        client = Client()
        client.leaders = ["openbao-0", "openbao-1", "openbao-1", "openbao-1"]
        calls = []
        original = client.download

        def switch(peer, output, limit):
            calls.append(peer)
            if len(calls) == 1:
                raise snapshot.SnapshotError("download-failed")
            original(peer, output, limit)

        client.download = switch
        self.run_snapshot(client)
        self.assertEqual(calls, ["openbao-0", "openbao-1"])

    def test_rejects_corruption_and_truncation(self):
        for payload in (archive(corrupt=True), archive()[:-20]):
            with self.subTest(payload_size=len(payload)), self.assertRaises(snapshot.SnapshotError):
                self.run_snapshot(Client(payload))
            self.assertFalse((self.root / "latest").exists())

    def test_rejects_metadata_mismatch(self):
        payload = archive(index=42, state=b"short", recorded_size=6)
        with self.assertRaises(snapshot.SnapshotError):
            self.run_snapshot(Client(payload))

    def test_failed_install_or_latest_update_preserves_previous_pair(self):
        first = self.run_snapshot()
        old = (self.root / "latest").read_text()
        for target in ("install", "latest"):
            with self.subTest(target=target):
                original = snapshot.os.replace

                def fail_selected(src, dst):
                    if (target == "install" and Path(dst).name.startswith("snapshot-")) or \
                       (target == "latest" and Path(dst).name == "latest"):
                        raise OSError(errno.EIO, "synthetic")
                    return original(src, dst)

                with patch.object(snapshot.os, "replace", side_effect=fail_selected):
                    with self.assertRaises(snapshot.SnapshotError):
                        self.run_snapshot(clock=lambda: NOW + timedelta(days=1))
                self.assertEqual((self.root / "latest").read_text(), old)
                self.assertTrue((self.root / old.strip() / "raft.snap").exists())
                self.assertEqual(len(list(self.root.glob("snapshot-*"))), 1)
        self.assertEqual(first["raft_index"], 42)

    def test_disk_full_preserves_latest_and_does_not_prune(self):
        self.run_snapshot()
        old = (self.root / "latest").read_text()
        client = Client()
        def full(peer, output, limit):
            raise OSError(errno.ENOSPC, "synthetic")
        client.download = full
        with self.assertRaises(snapshot.SnapshotError):
            self.run_snapshot(client, lambda: NOW + timedelta(days=1))
        self.assertEqual((self.root / "latest").read_text(), old)

    def test_retains_seven_successful_pairs_and_last_usable_on_failure(self):
        for day in range(8):
            self.run_snapshot(clock=lambda day=day: NOW + timedelta(days=day))
        self.assertEqual(len(list(self.root.glob("snapshot-*"))), 7)
        latest = (self.root / "latest").read_text().strip()
        with self.assertRaises(snapshot.SnapshotError):
            self.run_snapshot(Client(archive(corrupt=True)), lambda: NOW + timedelta(days=9))
        self.assertEqual((self.root / "latest").read_text().strip(), latest)
        self.assertEqual(len(list(self.root.glob("snapshot-*"))), 7)

    def test_credentials_never_reach_output_or_backup(self):
        client = Client()
        client.login_response = {"auth": {"client_token": MARKER}}
        client.jwt = MARKER
        with patch("sys.stdout", new_callable=io.StringIO) as out, \
             patch("sys.stderr", new_callable=io.StringIO) as err:
            self.run_snapshot(client)
        self.assertNotIn(MARKER, out.getvalue() + err.getvalue())
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(MARKER.encode(), path.read_bytes())

    def test_http_client_never_serializes_login_response_or_jwt(self):
        jwt_path = self.root / "jwt"
        jwt_path.write_text(MARKER)
        client = snapshot.BaoClient(jwt_path)
        output = io.BytesIO()

        class Response:
            status = 200
            def __init__(self):
                self.stream = io.BytesIO(archive())
            def getheader(self, name):
                return None
            def read(self, size):
                return self.stream.read(size)

        class Connection:
            def close(self):
                pass

        with patch.object(client, "_json", return_value={"auth": {"client_token": MARKER}}), \
             patch.object(client, "_request", return_value=(Connection(), Response())), \
             patch("sys.stdout", new_callable=io.StringIO) as stdout, \
             patch("sys.stderr", new_callable=io.StringIO) as stderr:
            client.download(snapshot.PEERS[0], output, snapshot.MAX_SNAPSHOT_BYTES)
        self.assertNotIn(MARKER.encode(), output.getvalue())
        self.assertNotIn(MARKER, stdout.getvalue() + stderr.getvalue())


class SourceTests(unittest.TestCase):
    base = Path("kubernetes/apps/security/openbao")

    def doc(self, relative):
        return yaml.safe_load((self.base / relative).read_text())

    def test_backup_has_no_api_grants_and_runs_before_longhorn(self):
        account = self.doc("backup/serviceaccount.yaml")
        job = self.doc("backup/cronjob.yaml")
        self.assertEqual(account["automountServiceAccountToken"], False)
        self.assertEqual(job["spec"]["schedule"], "0 1 * * *")
        pod = job["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        self.assertEqual(pod["serviceAccountName"], "openbao-backup")
        self.assertFalse(pod["automountServiceAccountToken"])
        env = {item["name"]: item["value"] for item in pod["containers"][0]["env"]}
        self.assertEqual(env["OPENBAO_SEAL_KEY_ID"], "openbao-static-seal-v1")
        self.assertEqual(env["OPENBAO_RECOVERY_GENERATION"], "1")
        token = next(v for v in pod["volumes"] if v["name"] == "openbao-token")
        self.assertEqual(token["projected"]["sources"], [{"serviceAccountToken": {
            "path": "token", "audience": "openbao-kubernetes-broker", "expirationSeconds": 600}}])
        resources = self.doc("backup/kustomization.yaml")["resources"]
        self.assertFalse(any("rbac" in name for name in resources))
        self.assertNotIn("openbao-seal", str(job))

    def test_monitoring_contract_and_separate_freshness_rules(self):
        service = self.doc("access/service.yaml")
        monitor = self.doc("monitoring/servicemonitor.yaml")
        rules = self.doc("monitoring/prometheusrule.yaml")
        self.assertEqual(service["metadata"]["name"], "openbao-monitoring")
        self.assertTrue(service["spec"]["publishNotReadyAddresses"])
        self.assertEqual(monitor["spec"]["selector"]["matchLabels"],
                         {"app.kubernetes.io/name": "openbao-monitoring"})
        endpoint = monitor["spec"]["endpoints"][0]
        self.assertEqual({key: endpoint[key] for key in ("port", "path", "params", "scheme", "tlsConfig")},
                         {"port": "monitoring", "path": "/v1/sys/metrics",
                          "params": {"format": ["prometheus"]}, "scheme": "https",
                          "tlsConfig": {"serverName": "openbao.lab.supermorphic.com"}})
        expressions = {rule["alert"]: rule["expr"] for group in rules["spec"]["groups"]
                       for rule in group["rules"]}
        self.assertIn("kube_cronjob_status_last_successful_time", expressions["OpenBaoLocalSnapshotStale"])
        self.assertIn("longhorn_volume_last_backup_at", expressions["OpenBaoOffsiteTransferStale"])
        self.assertNotIn("longhorn_volume_last_backup_at", expressions["OpenBaoLocalSnapshotStale"])
        self.assertNotIn("kube_cronjob_status_last_successful_time", expressions["OpenBaoOffsiteTransferStale"])

    def test_activation_and_audit_are_safe_to_stage(self):
        from scripts.openbao.apply import AUDIT
        gatus = yaml.safe_load(Path(
            "kubernetes/apps/monitoring/gatus/app/openbao-activation.values.yaml").read_text())
        active = yaml.safe_load(Path("kubernetes/apps/monitoring/gatus/app/values.yaml").read_text())
        endpoint = gatus["config"]["endpoints"][0]
        self.assertIn("standbyok=true", endpoint["url"])
        self.assertIn("[BODY].initialized == true", endpoint["conditions"])
        self.assertIn("[BODY].sealed == false", endpoint["conditions"])
        self.assertFalse(any(item["name"] == "openbao" for item in active["config"]["endpoints"]))
        self.assertEqual(AUDIT["options"]["log_raw"], "false")
        self.assertEqual(AUDIT["options"]["hmac_accessor"], "true")
        ks = list(yaml.safe_load_all((self.base / "ks.yaml").read_text()))
        self.assertTrue(all(item["spec"]["suspend"] for item in ks))
        backup = next(item for item in ks if item["metadata"]["name"] == "openbao-backup")
        self.assertTrue(backup["spec"]["prune"])
        self.assertEqual(self.doc("backup/pvc.yaml")["metadata"]["annotations"],
                         {"kustomize.toolkit.fluxcd.io/prune": "disabled"})


if __name__ == "__main__":
    unittest.main()
