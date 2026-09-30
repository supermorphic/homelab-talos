"""Backup selection and export boundaries, using synthetic private PVC contents."""

import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import backup_retrieve as export
from scripts.test.scenarios.test_openbao_restore import archive


class RetrievalTests(unittest.TestCase):
    def test_reader_has_only_readonly_backup_and_no_identity(self):
        pod = export.pod_document("synthetic-export", "synthetic-node")
        spec = pod["spec"]
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertEqual(spec["serviceAccountName"], "default")
        self.assertNotIn("fsGroup", spec["securityContext"])
        self.assertEqual(spec["volumes"], [{"name": "backup", "persistentVolumeClaim": {
            "claimName": "openbao-backup", "readOnly": True}}])
        self.assertEqual(spec["containers"][0]["volumeMounts"], [
            {"name": "backup", "mountPath": "/backup", "readOnly": True}])
        self.assertFalse(export.matches_reader(pod, {**copy.deepcopy(pod), "spec": {
            **spec, "volumes": spec["volumes"] + [{"name": "unexpected", "secret": {"secretName": "forbidden"}}]}}))

    def test_reader_accepts_api_defaults_but_rejects_other_node(self):
        pod = export.pod_document("synthetic-export", "synthetic-node")
        actual = copy.deepcopy(pod)
        actual["spec"]["dnsPolicy"] = "ClusterFirst"
        self.assertTrue(export.matches_reader(pod, actual))
        actual["spec"]["nodeName"] = "other-node"
        self.assertFalse(export.matches_reader(pod, actual))

    def test_copy_selects_job_window_not_latest_and_rejects_ambiguity(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            for time in ("2026-09-30T14:53:01Z", "2026-09-30T15:00:00Z"):
                pair = root / ("snapshot-" + time.replace(":", ""))
                pair.mkdir()
                (pair / "metadata.json").write_text(json.dumps({"created_at": time}))
                (pair / "raft.snap").write_bytes(b"synthetic-encrypted-state")
            (root / "latest").write_text("snapshot-2026-09-30T150000Z\n")
            result = self.remote(root)
            self.assertEqual(result.returncode, 0)
            self.assertIn(b"14:53:01Z", result.stdout)
            duplicate = root / "snapshot-2026-09-30T145302Z"
            duplicate.mkdir()
            (duplicate / "metadata.json").write_text('{"created_at":"2026-09-30T14:53:02Z"}')
            (duplicate / "raft.snap").write_bytes(b"other")
            self.assertNotEqual(self.remote(root).returncode, 0)

    def test_copy_rejects_symlinked_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            pair = root / "snapshot-2026-09-30T145301Z"
            pair.mkdir()
            (pair / "metadata.json").write_text('{"created_at":"2026-09-30T14:53:01Z"}')
            (root / "outside").write_bytes(b"not-a-snapshot")
            (pair / "raft.snap").symlink_to(root / "outside")
            self.assertNotEqual(self.remote(root).returncode, 0)

    def remote(self, root):
        return subprocess.run([sys.executable, "-c", export.COPY, str(root),
            "2026-09-30T14:53:00Z", "2026-09-30T14:53:13Z"], capture_output=True, timeout=5, check=False)

    def test_destination_never_overwrites_and_rejects_symlink_parent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            destination = root / "private" / "new"
            export.prepare_destination(destination)
            self.assertEqual(os.stat(destination).st_mode & 0o777, 0o700)
            with self.assertRaises(FileExistsError):
                export.prepare_destination(destination)
            (root / "alias").symlink_to(root / "private", target_is_directory=True)
            with self.assertRaises(export.SafeError):
                export.prepare_destination(root / "alias" / "other")

    def test_export_validates_archive_and_always_cleans_up(self):
        for corrupt, cleanup_failure in ((False, False), (True, False), (False, True)):
            with self.subTest(corrupt=corrupt, cleanup_failure=cleanup_failure), tempfile.TemporaryDirectory() as temp:
                data = archive()
                metadata = {"created_at": "2026-09-30T14:53:01Z", "openbao_version": "2.7.0",
                    "raft_index": 42, "seal_key_id": "openbao-static-seal-v1", "recovery_generation": "1",
                    "sha256": hashlib.sha256(data).hexdigest()}
                encoded = json.dumps(metadata).encode()
                reader = FakeReader(cleanup_failure)
                def transfer(argv, encoded=encoded, corrupt=corrupt, data=data, **kwargs):
                    self.assertNotIn("openbao-0", argv)
                    kwargs["stdout"].write(len(encoded).to_bytes(4, "big") + encoded +
                                          (b"wrong" if corrupt else data))
                    return subprocess.CompletedProcess(argv, 0)
                destination = Path(temp).resolve() / "copy"
                with patch.object(export, "target", return_value=SELECTED), patch.object(export.subprocess, "run", side_effect=transfer):
                    result = export.retrieve(reader, "openbao-backup-synthetic", destination, SELECTED)
                self.assertEqual(result["status"], "incomplete" if corrupt or cleanup_failure else "pass")
                self.assertTrue(reader.cleaned)
                self.assertEqual(reader.created[0]["kind"], "NetworkPolicy")
                self.assertEqual(reader.created[0]["spec"]["policyTypes"], ["Ingress", "Egress"])
                self.assertNotIn("ingress", reader.created[0]["spec"])
                self.assertNotIn("egress", reader.created[0]["spec"])
                self.assertEqual(os.stat(destination / "raft.snap").st_mode & 0o777, 0o600)

    def test_target_change_stops_before_reader_creation(self):
        reader = FakeReader()
        with patch.object(export, "target", return_value={**SELECTED, "pvc_uid": "replacement"}):
            result = export.retrieve(reader, "openbao-backup-synthetic", Path("/unused"), SELECTED)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(reader.created, [])
        self.assertTrue(reader.cleaned)

    def test_operator_entrypoint_prompts_once_and_requires_main(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp).resolve() / "config"
            config.write_text("synthetic-operator-config")
            job = "openbao-backup-synthetic"
            confirmation = "retrieve:openbao:" + job + ":" + export.guards.digest(SELECTED)
            with patch.dict(os.environ, {"OPENBAO_OPERATOR_KUBECONFIG": str(config), "OPENBAO_BACKUP_JOB": job}), patch.object(export.guards, "source_revision", return_value="a" * 40), patch.object(export.guards, "require_deployed_revision") as deployed, patch.object(export, "target", return_value=SELECTED), patch("builtins.input", return_value=confirmation) as prompt, patch("builtins.print"), patch.object(export, "retrieve", return_value={"status": "pass", "cleanup": "passed"}) as retrieve:
                self.assertEqual(export.main(), 0)
            deployed.assert_called_once_with(config, "a" * 40)
            prompt.assert_called_once()
            retrieve.assert_called_once()

    def test_cleanup_uses_uid_and_version_and_refuses_replacement(self):
        reader = export.Reader(Path("/synthetic/operator-config"))
        pod = export.pod_document("synthetic-reader", "synthetic-node")
        pod["metadata"].update(uid="owned-uid", resourceVersion="12")
        reader.objects.append(copy.deepcopy(pod))
        with patch.object(reader, "get", side_effect=[pod, None]), patch.object(reader, "command") as command:
            reader.cleanup()
        options = json.loads(command.call_args.kwargs["input_bytes"])
        self.assertEqual(options["preconditions"], {"uid": "owned-uid", "resourceVersion": "12"})
        replacement = copy.deepcopy(pod)
        replacement["metadata"]["uid"] = "other-owner"
        with patch.object(reader, "get", return_value=replacement), patch.object(reader, "command") as command, self.assertRaises(export.SafeError):
            reader.cleanup()
        command.assert_not_called()


SELECTED = {"job_uid": "synthetic-job", "pvc_uid": "synthetic-pvc", "node": "synthetic-node",
            "start": "2026-09-30T14:53:00Z", "end": "2026-09-30T14:53:13Z"}


class FakeReader:
    kubeconfig = Path("/synthetic/operator-config")

    def __init__(self, cleanup_failure=False):
        self.created, self.cleaned, self.cleanup_failure = [], False, cleanup_failure

    def create(self, doc):
        self.created.append(copy.deepcopy(doc))

    def owned(self, doc):
        return {**copy.deepcopy(doc), "status": {"conditions": [{"type": "Ready", "status": "True"}]}}

    def cleanup(self):
        self.cleaned = True
        if self.cleanup_failure:
            raise ValueError()


if __name__ == "__main__":
    unittest.main()
