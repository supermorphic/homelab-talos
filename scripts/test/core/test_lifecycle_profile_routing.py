"""Lifecycle callers retain a separate config per profile and Lease authority."""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from scripts.openbao import operator
from scripts.test.scenarios import agent_credentials as scenario


class LifecycleRoutingTests(unittest.TestCase):
    def test_real_kubectl_arguments_use_actor_profile_config_without_context_switch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selected = root / "selected-debugger"
            actor = {
                "directory": root / "actor",
                "audit_configs": {str(root): {"debugger": selected}},
            }
            result = Mock(returncode=0, stdout=b"yes")
            with patch.object(scenario.subprocess, "run", return_value=result) as run:
                self.assertEqual(
                    scenario.kubectl(root, actor, "debugger", "auth", "can-i", "get", "pods"),
                    b"yes",
                )
            command = run.call_args.args[0]
            self.assertEqual(command[command.index("--kubeconfig") + 1], str(selected))
            self.assertNotIn("--context", command)
            self.assertNotIn("--as", command)
            self.assertEqual(
                run.call_args.kwargs["env"]["AGENT_ACCEPTANCE_DIRECTORY"], str(root / "actor")
            )

    def test_lease_writes_use_coordinator_and_live_preconditions_use_selected_reader(self):
        process = Mock()
        process.stdout.readline.return_value = b"locked\n"
        process.wait.return_value = 0
        with (
            patch.object(operator.subprocess, "Popen", return_value=process) as spawn,
            patch.object(operator.select, "select", return_value=([process.stdout], [], [])),
            operator.lease(
                Path("/synthetic/lifecycle"), coordination_config=Path("/synthetic/coordinator")
            ),
        ):
            pass
        args = spawn.call_args.args[0]
        self.assertEqual(args[3], "/synthetic/coordinator")
        self.assertEqual(args[-1], "/synthetic/lifecycle")
        process.stdin.close.assert_called_once()

    def test_native_lock_uses_separate_precondition_and_lease_configs(self):
        import os
        import subprocess

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts/lib").mkdir(parents=True)
            (
                root / "scripts/lib/lease.sh"
            ).write_text("""acquire_test_lease() { [[ "$1" == /synthetic/coordinator ]]; echo acquire >> "$TRACE"; }
release_test_lease() { [[ "$1" == /synthetic/coordinator ]]; echo release >> "$TRACE"; }
start_test_lease_renewal() { [[ "$1" == /synthetic/coordinator ]]; echo renew >> "$TRACE"; }
""")
            (
                root / "scripts/lib/disruption-admission.sh"
            ).write_text("""assert_established_disruption_admissible() { [[ "$1" == /synthetic/lifecycle ]]; echo nodes >> "$TRACE"; }
""")
            trace = root / "calls"
            result = subprocess.run(
                [
                    "bash",
                    str(scenario.ROOT / "scripts/openbao/lock.sh"),
                    "hold",
                    "/synthetic/coordinator",
                    "synthetic-holder",
                    str(root / "failed"),
                    "/synthetic/lifecycle",
                ],
                cwd=root,
                env={**os.environ, "TRACE": str(trace)},
                input="",
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                trace.read_text().splitlines(), ["nodes", "acquire", "renew", "release"]
            )
            self.assertEqual(result.stdout, "locked\n")

    def test_measured_launcher_forwards_invocation_and_private_config_arguments(self):
        import json
        import os
        import subprocess

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts/openbao").mkdir(parents=True)
            (root / "bin").mkdir()
            launcher = root / "scripts/openbao/exec.sh"
            launcher.write_text(scenario.fixture_launcher())
            launcher.chmod(0o755)
            fake = root / "bin/mise"
            fake.write_text(
                "#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n"
            )
            fake.chmod(0o755)
            selected = root / "private config"
            result = subprocess.run(
                [str(launcher), "invocation", str(selected)],
                env={**os.environ, "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"]},
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = json.loads(result.stdout)
            self.assertEqual(arguments[-3:], ["-", "invocation", str(selected)])


class ActorProfilePreparationTests(unittest.TestCase):
    def setUp(self):
        from scripts.test.core.test_openbao_invocations import InvocationTests

        InvocationTests.setUp(self)

    def test_fixture_actor_uses_its_own_private_enrollment_for_every_bound_profile(self):
        from scripts.openbao import workstation
        from scripts.test import access

        actor = {"directory": self.auth}
        with patch.object(workstation, "DIRECTORY", self.repo / "unrelated-enrollment"):
            scenario.prepare_actor_profiles(self.repo, actor, "synthetic-audit")
            configs = actor["audit_configs"][str(self.repo)]
            self.assertEqual(
                set(configs),
                {
                    "observer",
                    "debugger",
                    "test-runner",
                    "report-publisher",
                    "campaign-coordinator",
                },
            )
            for profile, config in configs.items():
                binding = access.validate_invocation(self.repo, config, directory=self.auth)
                self.assertEqual(binding["profile"], profile)
                self.assertEqual(binding["profile_check"], profile)
