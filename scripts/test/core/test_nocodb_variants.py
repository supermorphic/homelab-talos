"""An environment flag cannot upgrade the catalog-selected NocoDB variant."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class NocodbVariantTests(unittest.TestCase):
    def test_extension_confirmation_requires_the_matching_bound_suite(self):
        for name, suite, confirmation, extension in (
            (
                "nocodb-access",
                "test.nocodb-access",
                "test:nocodb:access",
                "test:nocodb:access:source-pairs-v3",
            ),
            (
                "nocodb-restore-drill",
                "test.nocodb-restore-drill",
                "restore:nocodb:metadata",
                "restore:nocodb:source-pairs-v3",
            ),
        ):
            with self.subTest(backend=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "bin").mkdir()
                (root / "run/diagnostics").mkdir(parents=True)
                (root / "config").touch()
                uv = root / "bin/uv"
                uv.write_text("""#!/bin/sh
printf '%s\\n' "$*" >>"$VARIANT_TEST_UV_CALLS"
if [ "$4 $5 $6" = "-m scripts.test.access validate" ]; then
  printf '{"suite_id":"%s"}\\n' "$VARIANT_TEST_SUITE"
else exit 70; fi
""")
                uv.chmod(0o755)
                git = root / "bin/git"
                git.write_text("""#!/bin/sh
case "$1" in
  status|cat-file|diff) exit 0 ;;
  ls-remote) printf '0123456789012345678901234567890123456789\\trefs/heads/main\\n' ;;
  *) exit 72 ;;
esac
""")
                git.chmod(0o755)
                kube = root / "bin/kubectl"
                kube.write_text('#!/bin/sh\ntouch "$VARIANT_TEST_KUBE_CALL"\nexit 71\n')
                kube.chmod(0o755)
                prefix = "NOCODB_ACCESS" if name == "nocodb-access" else "NOCODB_RESTORE"
                result = subprocess.run(
                    [f"scripts/test/scenarios/{name}.sh", str(root / "config")],
                    cwd=ROOT,
                    env={
                        **os.environ,
                        "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                        "HOMELAB_TEST_RUN_DIR": str(root / "run"),
                        "VARIANT_TEST_SUITE": suite,
                        "VARIANT_TEST_KUBE_CALL": str(root / "kube-called"),
                        "VARIANT_TEST_UV_CALLS": str(root / "uv-calls"),
                        "AUTOMATION_DATA_PROVISIONING_URL": "https://n8n.lab.supermorphic.com/webhook/automation-data-provision",
                        "NOCODB_SOURCE_PROVISIONING_URL": "https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source",
                        "NOCODB_ACCEPTANCE_URL": "https://n8n.lab.supermorphic.com/webhook/nocodb-acceptance-domain",
                        "AUTOMATION_DATA_PROVISIONING_TOKEN": "synthetic_application_token_fixture_0123456789",
                        "NOCODB_SOURCE_PROVISIONING_TOKEN": "synthetic_source_token_fixture_0123456789",
                        "NOCODB_ACCEPTANCE_TOKEN": "synthetic_acceptance_token_fixture_0123456789",
                        (
                            prefix + ("_TEST_CONFIRM" if name == "nocodb-access" else "_CONFIRM")
                        ): confirmation,
                        prefix + "_EXTENSION_CONFIRM": extension,
                    },
                    text=True,
                    capture_output=True,
                    timeout=15,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "kube-called").exists())
                calls = (root / "uv-calls").read_text()
                self.assertNotIn("automation-data-application-acceptance.py", calls)
                self.assertIn("canonical suite", result.stderr)


if __name__ == "__main__":
    unittest.main()
