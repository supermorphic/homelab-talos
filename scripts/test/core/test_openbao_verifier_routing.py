"""The observational OpenBao verifier retains its selected scoped connection."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class OpenBaoVerifierRoutingTests(unittest.TestCase):
    def test_native_entry_uses_selected_config_without_context_discovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selected = root / "selected-config"
            selected.touch()
            trace = root / "calls"
            for tool, source in (
                (
                    "kubectl",
                    """import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ['TRACE']).open('a') as stream: stream.write(json.dumps(args) + '\\n')
raise SystemExit(0 if args == ['--kubeconfig', os.environ['SELECTED'], 'get', 'namespace', 'openbao'] else 64)
""",
                ),
                (
                    "uv",
                    """import json, os, sys
assert sys.argv[1:] == ['run', '--locked', 'python', '-m', 'scripts.openbao.verify', os.environ['SELECTED']]
print(json.dumps({'status':'pass'}))
""",
                ),
            ):
                executable = root / tool
                executable.write_text("#!/usr/bin/env python3\n" + source)
                executable.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/verify/openbao.sh"), str(selected)],
                env={
                    **os.environ,
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "TRACE": str(trace),
                    "SELECTED": str(selected),
                    "OPENBAO_OPERATOR_KUBECONFIG": "/synthetic/unrelated-operator",
                },
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"status": "pass"})
            self.assertEqual(len(trace.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
