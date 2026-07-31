"""Offline tests for GitHub protection desired-state and safety behavior."""

from __future__ import annotations

import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from typing import Any
from unittest import mock

MODULE_PATH = Path(__file__).parents[1] / "repository/github_protection.py"
SPEC = importlib.util.spec_from_file_location("github_protection", MODULE_PATH)
assert SPEC and SPEC.loader
github_protection = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(github_protection)

INTEGRATION_ID = 15368
HEAD_SHA = "a" * 40


def protected_state() -> dict[str, Any]:
    ruleset = {
        "id": 20116777,
        **github_protection.expected_ruleset(INTEGRATION_ID),
    }
    effective = [
        {
            **rule,
            "ruleset_id": ruleset["id"],
            "ruleset_source": github_protection.REPOSITORY,
            "ruleset_source_type": "Repository",
        }
        for rule in github_protection.expected_rules(INTEGRATION_ID)
    ]
    return {
        "integration_id": INTEGRATION_ID,
        "integration_sha": HEAD_SHA,
        "repository": github_protection.expected_merge_settings(),
        "matches": [
            {
                "id": ruleset["id"],
                "name": github_protection.RULESET_NAME,
                "source_type": "Repository",
            }
        ],
        "ruleset": ruleset,
        "effective": effective,
    }


class FakeAPI:
    def __init__(self, responses: dict[str, Any]):
        self.responses = responses
        self.calls: list[tuple[str, str]] = []

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> Any:
        del payload
        self.calls.append((method, path))
        return self.responses[path]


class RecordingAPI:
    def __init__(self):
        self.calls: list[tuple[str, str, dict[str, Any] | None]] = []

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        self.calls.append((method, path, payload))
        return {"id": 20200000}


class GitHubProtectionTests(unittest.TestCase):
    def test_expected_contract_matches_protected_state(self):
        state = protected_state()
        self.assertEqual(github_protection.drift(state), [])
        self.assertEqual(github_protection.plan_actions(state), ([], []))

    def test_missing_ruleset_is_planned_for_recreation(self):
        state = protected_state()
        state["matches"] = []
        state["ruleset"] = None
        state["effective"] = []
        self.assertEqual(
            github_protection.drift(state),
            ["repository ruleset 'Protect main' is missing"],
        )
        self.assertEqual(
            github_protection.plan_actions(state),
            (["create active repository ruleset 'Protect main'"], []),
        )

    def test_unmanaged_effective_rule_blocks_apply_plan(self):
        state = protected_state()
        state["effective"].append(
            {
                "type": "required_signatures",
                "ruleset_id": 99,
                "ruleset_source": github_protection.REPOSITORY,
                "ruleset_source_type": "Repository",
            }
        )
        actions, blockers = github_protection.plan_actions(state)
        self.assertIn("update repository ruleset 'Protect main' (ID 20116777)", actions)
        self.assertEqual(blockers, ["inspect unexpected rulesets already applying to main"])

    def test_merge_and_pull_request_drift_are_detected(self):
        state = protected_state()
        state["repository"]["allow_merge_commit"] = True
        pull_request = next(
            rule for rule in state["ruleset"]["rules"] if rule["type"] == "pull_request"
        )
        pull_request["parameters"]["required_approving_review_count"] = 1
        self.assertEqual(
            github_protection.drift(state),
            [
                "repository merge methods are not squash-only",
                "repository ruleset 'Protect main' differs from desired state",
            ],
        )

    def test_confirmation_is_exact_and_per_repository(self):
        with self.assertRaises(github_protection.ProtectionError):
            github_protection.require_confirmation({})
        with self.assertRaises(github_protection.ProtectionError):
            github_protection.require_confirmation(
                {"GITHUB_PROTECTION_CONFIRM": "apply:github-protection:somewhere/else"}
            )
        github_protection.require_confirmation(
            {"GITHUB_PROTECTION_CONFIRM": github_protection.CONFIRMATION}
        )

    def test_guarded_apply_recreates_a_missing_ruleset_and_reads_back(self):
        missing = protected_state()
        missing["matches"] = []
        missing["ruleset"] = None
        missing["effective"] = []
        verified = protected_state()
        api = RecordingAPI()
        environment = {"GITHUB_PROTECTION_CONFIRM": github_protection.CONFIRMATION}
        with (
            mock.patch.object(
                github_protection,
                "collect_state",
                side_effect=[missing, verified],
            ) as collect,
            redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(github_protection.run_apply(api, environment), 0)
        self.assertEqual(collect.call_count, 2)
        self.assertEqual(
            api.calls,
            [
                (
                    "POST",
                    f"repos/{github_protection.REPOSITORY}/rulesets",
                    github_protection.expected_ruleset(INTEGRATION_ID),
                )
            ],
        )

    def test_actions_integration_comes_from_recent_successful_ci_check(self):
        runs_path = (
            f"repos/{github_protection.REPOSITORY}/actions/workflows/"
            f"{github_protection.WORKFLOW}/runs?per_page=20"
        )
        checks_path = (
            f"repos/{github_protection.REPOSITORY}/commits/{HEAD_SHA}/check-runs"
            f"?check_name={github_protection.CHECK_NAME}&filter=latest&per_page=100"
        )
        api = FakeAPI(
            {
                runs_path: {
                    "workflow_runs": [
                        {"conclusion": "failure", "head_sha": "b" * 40},
                        {"conclusion": "success", "head_sha": HEAD_SHA},
                    ]
                },
                checks_path: {
                    "check_runs": [
                        {
                            "name": "ci",
                            "app": {"id": INTEGRATION_ID, "slug": "github-actions"},
                        }
                    ]
                },
            }
        )
        self.assertEqual(
            github_protection.resolve_actions_integration(api),
            (INTEGRATION_ID, HEAD_SHA),
        )
        self.assertEqual(api.calls, [("GET", runs_path), ("GET", checks_path)])


if __name__ == "__main__":
    unittest.main()
