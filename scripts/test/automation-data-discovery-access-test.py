#!/usr/bin/env python3
"""Protected metadata selection and bounded transport, with synthetic retained files."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
try:
    from automation_data_access import fetch_observations, inspect_profile, load_access_config
except ImportError:
    raise AssertionError("Protected access implementation missing") from None
from automation_data_client import PrivateFileError
from automation_data_inventory import DiscoveryRequest, InventoryError


class AccessTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.root.chmod(0o700)
        self.base = self.root / "homelab" / "automation-data"
        self.base.mkdir(parents=True, mode=0o700)
        self.app = self.root / "applications"
        self.app.mkdir(mode=0o700)
        self.migration = self.root / "migrators"
        self.migration.mkdir(mode=0o700)
        self.token = self.base / "inventory-auth"
        self.write(self.token, "SYNTHETIC_HEADER_SENTINEL")
        self.config = self.base / "access.json"
        self.data = {
            "schemaVersion": 1,
            "inventoryAuthFile": str(self.token),
            "applicationProfileRoot": str(self.app),
            "migratorProfileRoot": str(self.migration),
        }
        self.write(self.config, json.dumps(self.data))
        env = patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.root)}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        self.identity = {
            "family": "application",
            "domain": "sample",
            "application": "interview",
            "role": "app_fixture_integration",
            "schema": "consumer_schema",
            "credentialGeneration": 2,
        }

    def write(self, path, text):
        path.write_text(text)
        path.chmod(0o600)

    def install(self):
        directory = self.app / "sample" / "interview"
        directory.mkdir(parents=True, mode=0o700)
        directory.parent.chmod(0o700)
        self.write(
            directory / "binding.json",
            json.dumps({**self.identity, "database": "sample", "localPort": 15432}),
        )
        self.write(directory / "service.conf", "SYNTHETIC_PROFILE_DO_NOT_READ")
        generation = directory / "generation-2"
        generation.mkdir(mode=0o700)
        self.write(generation / "credential.pgpass", "SYNTHETIC_PASSWORD_DO_NOT_READ")
        return directory

    def test_fixed_config_and_metadata_does_not_open_secrets(self):
        config = load_access_config()
        directory = self.install()
        original = Path.read_text

        def guarded(path, *args, **kwargs):
            self.assertIn(path.name, {"binding.json", "access.json"})
            return original(path, *args, **kwargs)

        with patch.object(Path, "read_text", guarded):
            profile = inspect_profile(config, self.identity)
        self.assertEqual(profile.status, "ready")
        self.assertEqual(profile.service_file, directory / "service.conf")
        self.assertNotIn("SYNTHETIC", repr(profile))
        self.assertEqual(inspect_profile(config, self.identity), profile)

    def test_pending_and_stale_profiles(self):
        config = load_access_config()
        directory = self.install()
        self.identity["credentialGeneration"] = 3
        self.assertEqual(inspect_profile(config, self.identity).status, "stale")
        self.identity["credentialGeneration"] = 2
        pending = directory / "pending"
        pending.mkdir(mode=0o700)
        self.write(pending / "operation.json", "{}")
        self.assertEqual(inspect_profile(config, self.identity).status, "pending")

    def test_unsafe_paths_and_unknown_endpoints(self):
        self.config.chmod(0o644)
        with self.assertRaises(PrivateFileError):
            load_access_config()
        self.config.chmod(0o600)
        self.data["url"] = "https://example.com"
        self.write(self.config, json.dumps(self.data))
        with self.assertRaises(PrivateFileError):
            load_access_config()
        del self.data["url"]
        self.data["applicationProfileRoot"] = str(Path.cwd())
        self.write(self.config, json.dumps(self.data))
        with self.assertRaises(PrivateFileError):
            load_access_config()

    def test_symlinked_ancestor_is_rejected(self):
        link = self.root / "alias"
        link.symlink_to(self.app, target_is_directory=True)
        self.data["applicationProfileRoot"] = str(link)
        self.write(self.config, json.dumps(self.data))
        with self.assertRaises(PrivateFileError):
            load_access_config()

    def test_missing_profile_is_observation(self):
        self.assertEqual(inspect_profile(load_access_config(), self.identity).status, "missing")

    def test_migrator_marker_requires_exact_binding(self):
        directory = self.migration / "sample"
        directory.mkdir(mode=0o700)
        identity = {
            "family": "migration",
            "domain": "sample",
            "role": "sample_migrator",
            "credentialId": "fixture-migrator",
            "credentialUpdatedAt": "2026-09-30T10:00:00Z",
        }
        self.write(
            directory / "binding.json",
            json.dumps(
                {
                    **identity,
                    "database": "sample",
                    "service": "automation_data_sample_migrator",
                    "localPort": 15432,
                }
            ),
        )
        self.write(directory / "service.conf", "SYNTHETIC_PROFILE_DO_NOT_READ")
        self.write(directory / "credential.pgpass", "SYNTHETIC_PASSWORD_DO_NOT_READ")
        self.assertEqual(inspect_profile(load_access_config(), identity).status, "ready")
        identity["credentialId"] = "rotated-migrator"
        self.assertEqual(inspect_profile(load_access_config(), identity).status, "stale")

    def test_transport_has_only_fixed_header_and_no_redirect(self):
        class Sock:
            def settimeout(self, value):
                self.value = value

        class Response:
            status = 302

            def getheader(self, name):
                return None

        class Connection:
            def __init__(self, host, **kwargs):
                self.host = host
                self.kwargs = kwargs
                self.sock = Sock()
                self_outer.assertTrue(kwargs["context"].check_hostname)
                self_outer.assertEqual(kwargs["context"].verify_mode, 2)

            def request(inner, method, path, body, headers):
                self.assertEqual(inner.host, "n8n.lab.supermorphic.com")
                self.assertEqual(path, "/webhook/automation-data-credential-inventory")
                self.assertEqual(
                    headers["X-Automation-Data-Inventory"], "SYNTHETIC_HEADER_SENTINEL"
                )
                self.assertNotIn("SYNTHETIC", body.decode())

            def getresponse(self):
                return Response()

            def close(self):
                pass

        self_outer = self
        with (
            patch("automation_data_access.http.client.HTTPSConnection", Connection),
            self.assertRaisesRegex(InventoryError, "source_unavailable"),
        ):
            fetch_observations(load_access_config(), DiscoveryRequest())

    def transport(self, *, status=200, content=b"", length=None):
        class Response:
            def getheader(self, name):
                return length

            def read1(self, count):
                chunk, self.content = self.content[:count], self.content[count:]
                return chunk

        response = Response()
        response.status, response.content = status, content

        class Connection:
            sock = None

            def __init__(self, *args, **kwargs):
                pass

            def request(self, *args, **kwargs):
                pass

            def getresponse(self):
                return response

            def close(self):
                pass

        with patch("automation_data_access.http.client.HTTPSConnection", Connection):
            return fetch_observations(load_access_config(), DiscoveryRequest())

    def test_missing_and_revoked_header_have_bounded_reasons(self):
        self.token.unlink()
        with self.assertRaisesRegex(InventoryError, "authentication_required"):
            self.transport()
        self.write(self.token, "SYNTHETIC_HEADER_SENTINEL")
        with self.assertRaisesRegex(InventoryError, "authentication_failed"):
            self.transport(status=401)

    def test_incremental_receive_bound_does_not_require_content_length(self):
        with self.assertRaisesRegex(InventoryError, "limit_exceeded"):
            self.transport(content=b"x" * (4 * 1024 * 1024 + 1))

    def test_response_sources_are_independent(self):
        content = json.dumps(
            {
                "schemaVersion": 1,
                "sources": [
                    {
                        "source": source,
                        "status": "unavailable",
                        "complete": False,
                        "errorCode": "unsupported_schema",
                    }
                    for source in ("platform", "nocodb", "n8n")
                ],
            }
        ).encode()
        observations = self.transport(content=content)
        self.assertEqual(len(observations), 3)
        self.assertTrue(all(item.error_code == "unsupported_schema" for item in observations))

    def test_relative_xdg_root_is_rejected(self):
        with (
            patch.dict(os.environ, {"XDG_CONFIG_HOME": "relative"}),
            self.assertRaises(PrivateFileError),
        ):
            load_access_config()

    def test_deadline_includes_connection_and_receive(self):
        with (
            patch("automation_data_access.time.monotonic", side_effect=[0, 31]),
            self.assertRaisesRegex(InventoryError, "source_unavailable"),
        ):
            self.transport(content=b"{}")


if __name__ == "__main__":
    unittest.main()
