import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import local_integration as integration


class PartialCreationRun(integration.PodmanRun):
    def __init__(self, failure_kind: str):
        self.owner = "web-research-local-test"
        self.network = f"{self.owner}-network"
        self.containers = []
        self.network_created = False
        self.failure_kind = failure_kind
        self.resources = {"container": set(), "network": set()}

    def exists(self, kind: str, name: str) -> bool:
        return name in self.resources[kind]

    def inspect_label(self, kind: str, name: str) -> str:
        return self.owner

    def command(self, *arguments: str, **_kwargs):
        if arguments[:2] == ("network", "create"):
            self.resources["network"].add(arguments[-1])
            if self.failure_kind == "network":
                raise subprocess.CalledProcessError(125, arguments)
        elif arguments[0] == "run":
            name = arguments[arguments.index("--name") + 1]
            self.resources["container"].add(name)
            if self.failure_kind == "container":
                raise subprocess.CalledProcessError(125, arguments)
        elif arguments[:2] == ("rm", "--force"):
            self.resources["container"].discard(arguments[-1])
        elif arguments[:2] == ("network", "rm"):
            self.resources["network"].discard(arguments[-1])
        return subprocess.CompletedProcess(arguments, 0, "", "")


class PodmanCleanupTests(unittest.TestCase):
    def test_cleanup_removes_resources_created_before_client_error(self):
        for kind in ("network", "container"):
            with self.subTest(kind=kind):
                run = PartialCreationRun(kind)
                with self.assertRaises(subprocess.CalledProcessError):
                    if kind == "network":
                        run.create_network()
                    else:
                        run.run_container(f"{run.owner}-native", ["image"])

                run.cleanup()

                self.assertEqual(set(), run.resources[kind])


class FailureReportingTests(unittest.TestCase):
    def test_primary_and_cleanup_failures_are_both_reported_without_error_text(self):
        sentinel = "credential-bearing-upstream-response"
        with self.assertRaises(integration.WorkflowFailures) as raised:
            integration.raise_workflow_failures(
                ValueError(sentinel), integration.AcceptanceFailure("exact-cleanup")
            )

        lines = integration.failure_lines(raised.exception)

        self.assertEqual(
            [
                "FAIL primary workflow (ValueError)",
                "FAIL cleanup exact-cleanup (AcceptanceFailure)",
            ],
            lines,
        )
        self.assertNotIn(sentinel, "\n".join(lines))


if __name__ == "__main__":
    unittest.main()
