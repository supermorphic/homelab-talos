"""Check, plan, and explicitly reconcile this repository's GitHub protection."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any

REPOSITORY = "supermorphic/homelab-talos"
RULESET_NAME = "Protect main"
TARGET_REF = "refs/heads/main"
WORKFLOW = "ci.yml"
CHECK_NAME = "ci"
API_VERSION = "2026-03-10"
CONFIRMATION = f"apply:github-protection:{REPOSITORY}"


class ProtectionError(RuntimeError):
    """A safe, actionable GitHub protection failure."""


class GitHubAPI:
    """Minimal JSON interface over the mise-pinned GitHub CLI."""

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> Any:
        command = [
            "gh",
            "api",
            "--hostname",
            "github.com",
            "--header",
            "Accept: application/vnd.github+json",
            "--header",
            f"X-GitHub-Api-Version: {API_VERSION}",
        ]
        if method != "GET":
            command.extend(["--method", method])
        command.append(path)
        request_input = None
        if payload is not None:
            command.extend(["--input", "-"])
            request_input = json.dumps(payload)
        try:
            completed = subprocess.run(
                command,
                check=True,
                capture_output=True,
                input=request_input,
                text=True,
            )
        except FileNotFoundError as error:
            raise ProtectionError(
                "The pinned GitHub CLI is unavailable; run through `mise exec -- just`."
            ) from error
        except subprocess.CalledProcessError as error:
            detail = error.stderr.strip() or error.stdout.strip() or "GitHub API request failed"
            raise ProtectionError(detail) from error
        if not completed.stdout.strip():
            return None
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise ProtectionError(f"GitHub returned invalid JSON for {path}") from error


def expected_rules(integration_id: int) -> list[dict[str, Any]]:
    return [
        {"type": "deletion"},
        {"type": "required_linear_history"},
        {
            "type": "pull_request",
            "parameters": {
                "allowed_merge_methods": ["squash"],
                "dismiss_stale_reviews_on_push": False,
                "require_code_owner_review": False,
                "require_last_push_approval": False,
                "required_approving_review_count": 0,
                "required_review_thread_resolution": False,
                "required_reviewers": [],
            },
        },
        {
            "type": "required_status_checks",
            "parameters": {
                "do_not_enforce_on_create": False,
                "required_status_checks": [
                    {"context": CHECK_NAME, "integration_id": integration_id}
                ],
                "strict_required_status_checks_policy": True,
            },
        },
        {"type": "non_fast_forward"},
    ]


def expected_ruleset(integration_id: int) -> dict[str, Any]:
    return {
        "name": RULESET_NAME,
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {"ref_name": {"include": [TARGET_REF], "exclude": []}},
        "rules": expected_rules(integration_id),
    }


def merge_projection(repository: dict[str, Any]) -> dict[str, bool]:
    return {
        "allow_squash_merge": repository.get("allow_squash_merge"),
        "allow_merge_commit": repository.get("allow_merge_commit"),
        "allow_rebase_merge": repository.get("allow_rebase_merge"),
    }


def expected_merge_settings() -> dict[str, bool]:
    return {
        "allow_squash_merge": True,
        "allow_merge_commit": False,
        "allow_rebase_merge": False,
    }


def normalize_rule(rule: dict[str, Any]) -> dict[str, Any]:
    rule_type = rule.get("type")
    normalized: dict[str, Any] = {"type": rule_type}
    parameters = rule.get("parameters", {})
    if rule_type == "pull_request":
        dismissal = parameters.get("dismissal_restriction") or {}
        normalized["parameters"] = {
            "allowed_merge_methods": parameters.get("allowed_merge_methods"),
            "dismiss_stale_reviews_on_push": parameters.get("dismiss_stale_reviews_on_push"),
            "dismissal_restriction_enabled": dismissal.get("enabled", False),
            "require_code_owner_review": parameters.get("require_code_owner_review"),
            "require_last_push_approval": parameters.get("require_last_push_approval"),
            "required_approving_review_count": parameters.get("required_approving_review_count"),
            "required_review_thread_resolution": parameters.get(
                "required_review_thread_resolution"
            ),
            "required_reviewers": parameters.get("required_reviewers", []),
        }
    elif rule_type == "required_status_checks":
        normalized["parameters"] = {
            "do_not_enforce_on_create": parameters.get("do_not_enforce_on_create", False),
            "required_status_checks": parameters.get("required_status_checks"),
            "strict_required_status_checks_policy": parameters.get(
                "strict_required_status_checks_policy"
            ),
        }
    elif parameters:
        normalized["parameters"] = parameters
    return normalized


def normalize_rules(rules: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted((normalize_rule(rule) for rule in rules), key=lambda rule: rule["type"])


def ruleset_projection(ruleset: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": ruleset.get("name"),
        "target": ruleset.get("target"),
        "enforcement": ruleset.get("enforcement"),
        "bypass_actors": ruleset.get("bypass_actors"),
        "conditions": ruleset.get("conditions"),
        "rules": normalize_rules(ruleset.get("rules", [])),
    }


def normalized_expected_rules(integration_id: int) -> list[dict[str, Any]]:
    expected = normalize_rules(expected_rules(integration_id))
    for rule in expected:
        if rule["type"] == "pull_request":
            rule["parameters"]["dismissal_restriction_enabled"] = False
    return expected


def resolve_actions_integration(api: GitHubAPI) -> tuple[int, str]:
    runs = api.request("GET", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs?per_page=20")
    for run in runs.get("workflow_runs", []):
        if run.get("conclusion") != "success" or not run.get("head_sha"):
            continue
        head_sha = run["head_sha"]
        checks = api.request(
            "GET",
            f"repos/{REPOSITORY}/commits/{head_sha}/check-runs"
            f"?check_name={CHECK_NAME}&filter=latest&per_page=100",
        )
        for check in checks.get("check_runs", []):
            app = check.get("app") or {}
            if check.get("name") == CHECK_NAME and app.get("slug") == "github-actions":
                integration_id = app.get("id")
                if isinstance(integration_id, int):
                    return integration_id, head_sha
    raise ProtectionError(
        "Could not resolve the GitHub Actions integration ID from a recent successful "
        f"{CHECK_NAME} check. Run the workflow successfully before retrying."
    )


def collect_state(api: GitHubAPI) -> dict[str, Any]:
    integration_id, integration_sha = resolve_actions_integration(api)
    repository = api.request("GET", f"repos/{REPOSITORY}")
    summaries = api.request(
        "GET", f"repos/{REPOSITORY}/rulesets?includes_parents=false&per_page=100"
    )
    matches = [
        summary
        for summary in summaries
        if summary.get("name") == RULESET_NAME and summary.get("source_type") == "Repository"
    ]
    ruleset = None
    if len(matches) == 1:
        ruleset = api.request("GET", f"repos/{REPOSITORY}/rulesets/{matches[0]['id']}")
        if "bypass_actors" not in ruleset:
            raise ProtectionError(
                "GitHub did not return the ruleset bypass list. Authenticate with "
                "repository Administration access so the complete ruleset can be verified."
            )
    effective = api.request("GET", f"repos/{REPOSITORY}/rules/branches/main")
    return {
        "integration_id": integration_id,
        "integration_sha": integration_sha,
        "repository": repository,
        "matches": matches,
        "ruleset": ruleset,
        "effective": effective,
    }


def effective_rules_match(state: dict[str, Any]) -> bool:
    ruleset = state["ruleset"]
    if ruleset is None:
        return False
    ruleset_id = ruleset.get("id")
    effective = state["effective"]
    if any(
        rule.get("ruleset_id") != ruleset_id
        or rule.get("ruleset_source") != REPOSITORY
        or rule.get("ruleset_source_type") != "Repository"
        for rule in effective
    ):
        return False
    return normalize_rules(effective) == normalized_expected_rules(state["integration_id"])


def drift(state: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    if merge_projection(state["repository"]) != expected_merge_settings():
        findings.append("repository merge methods are not squash-only")
    if len(state["matches"]) == 0:
        findings.append(f"repository ruleset {RULESET_NAME!r} is missing")
        return findings
    if len(state["matches"]) > 1:
        findings.append(f"multiple repository rulesets are named {RULESET_NAME!r}")
        return findings
    expected = expected_ruleset(state["integration_id"])
    expected["rules"] = normalized_expected_rules(state["integration_id"])
    if ruleset_projection(state["ruleset"]) != expected:
        findings.append(f"repository ruleset {RULESET_NAME!r} differs from desired state")
    if not effective_rules_match(state):
        findings.append("effective rules for main differ or come from an unexpected ruleset")
    return findings


def unmanaged_effective_rules(state: dict[str, Any]) -> bool:
    if not state["effective"]:
        return False
    ruleset = state["ruleset"]
    if ruleset is None:
        return True
    ruleset_id = ruleset.get("id")
    return any(rule.get("ruleset_id") != ruleset_id for rule in state["effective"])


def plan_actions(state: dict[str, Any]) -> tuple[list[str], list[str]]:
    actions: list[str] = []
    blockers: list[str] = []
    if len(state["matches"]) > 1:
        blockers.append(f"resolve duplicate {RULESET_NAME!r} rulesets manually")
    if unmanaged_effective_rules(state):
        blockers.append("inspect unexpected rulesets already applying to main")
    if merge_projection(state["repository"]) != expected_merge_settings():
        actions.append("set repository pull-request merge methods to squash only")
    if len(state["matches"]) == 0:
        actions.append(f"create active repository ruleset {RULESET_NAME!r}")
    elif len(state["matches"]) == 1:
        expected = expected_ruleset(state["integration_id"])
        expected["rules"] = normalized_expected_rules(state["integration_id"])
        if ruleset_projection(state["ruleset"]) != expected or not effective_rules_match(state):
            actions.append(
                f"update repository ruleset {RULESET_NAME!r} (ID {state['ruleset']['id']})"
            )
    return actions, blockers


def print_context(state: dict[str, Any]) -> None:
    print(f"Repository: {REPOSITORY}")
    print(
        "GitHub Actions source: "
        f"integration {state['integration_id']} from successful commit "
        f"{state['integration_sha'][:12]}"
    )
    if state["ruleset"] is not None:
        print(f"Ruleset: {RULESET_NAME} (ID {state['ruleset']['id']})")


def run_check(api: GitHubAPI) -> int:
    state = collect_state(api)
    print_context(state)
    findings = drift(state)
    if findings:
        print("GitHub protection check: DRIFT")
        for finding in findings:
            print(f"- {finding}")
        return 1
    print("GitHub protection check: PASS")
    print("main accepts squash-merged pull requests only after strict GitHub Actions ci.")
    return 0


def run_plan(api: GitHubAPI) -> int:
    state = collect_state(api)
    print_context(state)
    actions, blockers = plan_actions(state)
    if blockers:
        print("Plan is blocked:")
        for blocker in blockers:
            print(f"- {blocker}")
        return 2
    if not actions:
        print("Plan: no changes; GitHub protection matches desired state.")
        return 0
    print("Plan:")
    for action in actions:
        print(f"- {action}")
    print(f"Apply guard: GITHUB_PROTECTION_CONFIRM={CONFIRMATION!r}")
    return 0


def require_confirmation(environment: dict[str, str]) -> None:
    if environment.get("GITHUB_PROTECTION_CONFIRM") != CONFIRMATION:
        raise ProtectionError(
            "Refusing to change GitHub protection. After reviewing the plan and granting "
            "explicit authorization for this invocation, set "
            f"GITHUB_PROTECTION_CONFIRM={CONFIRMATION!r}."
        )


def run_apply(api: GitHubAPI, environment: dict[str, str]) -> int:
    require_confirmation(environment)
    state = collect_state(api)
    print_context(state)
    actions, blockers = plan_actions(state)
    if blockers:
        raise ProtectionError("Refusing reconciliation: " + "; ".join(blockers))
    if not actions:
        print("Apply: no changes; GitHub protection already matches desired state.")
        return 0

    ruleset_payload = expected_ruleset(state["integration_id"])
    if len(state["matches"]) == 0:
        api.request("POST", f"repos/{REPOSITORY}/rulesets", ruleset_payload)
        print(f"Created repository ruleset {RULESET_NAME!r}.")
    elif any("update repository ruleset" in action for action in actions):
        ruleset_id = state["ruleset"]["id"]
        api.request("PUT", f"repos/{REPOSITORY}/rulesets/{ruleset_id}", ruleset_payload)
        print(f"Updated repository ruleset {RULESET_NAME!r} (ID {ruleset_id}).")

    if merge_projection(state["repository"]) != expected_merge_settings():
        api.request("PATCH", f"repos/{REPOSITORY}", expected_merge_settings())
        print("Updated repository pull-request merge methods to squash only.")

    verified = collect_state(api)
    findings = drift(verified)
    if findings:
        raise ProtectionError("Post-apply verification found drift: " + "; ".join(findings))
    print_context(verified)
    print("Apply: PASS; complete API read-back matches desired state.")
    return 0


def parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "plan", "apply"))
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = parse_args(arguments if arguments is not None else sys.argv[1:])
    api = GitHubAPI()
    try:
        if args.command == "check":
            return run_check(api)
        if args.command == "plan":
            return run_plan(api)
        return run_apply(api, os.environ)
    except ProtectionError as error:
        print(f"GitHub protection error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
