"""Offline tests for the decision-record lifecycle model and CLI."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "repository/decisions.py"
SPEC = importlib.util.spec_from_file_location("decisions", MODULE_PATH)
assert SPEC and SPEC.loader
decisions = importlib.util.module_from_spec(SPEC)
# Register before executing so `@dataclass` can resolve the module's own namespace.
sys.modules[SPEC.name] = decisions
SPEC.loader.exec_module(decisions)

DECISIONS_DIR = "docs/decisions"

ACCEPTED_BODY = """# Example Decision

## Status

- **Status: Accepted.** Approved by the operator on 2026-08-02.
- Date: 2026-08-02

## Decision

The chosen approach is recorded here.
"""

DRAFT_BODY = ACCEPTED_BODY.replace(
    "- **Status: Accepted.** Approved by the operator on 2026-08-02.",
    "- **Status: Draft.**",
)

SUCCESSOR_BODY = """# Successor Decision

## Status

- **Status: Accepted.** Approved by the operator on 2026-08-03.
- Date: 2026-08-03

## Decision

This record replaces the earlier one.
"""

LEGACY_BODY = """# Legacy Decision

Status: Accepted (2026-08-02)

## Decision

Written before the lifecycle CLI existed.
"""


def record_path(name: str) -> str:
    """Build a decision path without introducing a bare documentation reference."""
    return f"{DECISIONS_DIR}/{name}"


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


class RepoFixture:
    """A temporary Git repository with a `main` baseline and a feature branch."""

    def __init__(self, stack: contextlib.ExitStack) -> None:
        self.root = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        git(self.root, "init", "--quiet", "--initial-branch", "main")
        git(self.root, "config", "user.email", "test@example.invalid")
        git(self.root, "config", "user.name", "Test")
        (self.root / DECISIONS_DIR).mkdir(parents=True)

    def write(self, name: str, body: str) -> None:
        (self.root / DECISIONS_DIR / name).write_text(body, encoding="utf-8")

    def delete(self, name: str) -> None:
        (self.root / DECISIONS_DIR / name).unlink()

    def commit(self, message: str) -> None:
        git(self.root, "add", "-A")
        git(self.root, "commit", "--quiet", "-m", message)

    def branch(self, name: str) -> None:
        git(self.root, "switch", "--quiet", "-c", name)

    def validate(self, base: str = "main") -> list[str]:
        return decisions.validate(self.root, base)


class DecisionLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.repo = RepoFixture(self.stack)
        self.repo.write("2026-08-02-example.md", ACCEPTED_BODY)
        self.repo.commit("baseline accepted record")
        self.repo.branch("feature")

    def test_new_draft_record_is_allowed(self) -> None:
        self.repo.write("2026-08-04-new-topic.md", DRAFT_BODY)
        self.repo.commit("add draft")
        self.assertEqual(self.repo.validate(), [])

    def test_new_accepted_record_in_landing_pr_is_allowed(self) -> None:
        self.repo.write("2026-08-04-new-topic.md", SUCCESSOR_BODY)
        self.repo.commit("add accepted record")
        self.assertEqual(self.repo.validate(), [])

    def test_accepted_body_edit_is_rejected(self) -> None:
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace("The chosen approach", "A different approach"),
        )
        self.repo.commit("revise accepted body")
        violations = self.repo.validate()
        self.assertEqual(len(violations), 1)
        self.assertIn("2026-08-02-example.md", violations[0])
        self.assertIn("revised", violations[0])

    def test_accepted_deletion_is_rejected(self) -> None:
        self.repo.delete("2026-08-02-example.md")
        self.repo.commit("delete accepted record")
        violations = self.repo.validate()
        self.assertEqual(len(violations), 1)
        self.assertIn("deleted", violations[0])

    def test_accepted_rename_is_rejected_as_delete_and_add(self) -> None:
        self.repo.delete("2026-08-02-example.md")
        self.repo.write("2026-08-02-renamed.md", ACCEPTED_BODY)
        self.repo.commit("rename accepted record")
        violations = self.repo.validate()
        self.assertTrue(any("deleted" in v and "2026-08-02-example.md" in v for v in violations))

    def test_status_only_supersession_to_existing_target_is_allowed(self) -> None:
        self.repo.write("2026-08-03-successor.md", SUCCESSOR_BODY)
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace(
                "- **Status: Accepted.** Approved by the operator on 2026-08-02.",
                "- **Status: Superseded by 2026-08-03-successor.md.**",
            ),
        )
        self.repo.commit("supersede")
        self.assertEqual(self.repo.validate(), [])

    def test_supersession_with_missing_target_is_rejected(self) -> None:
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace(
                "- **Status: Accepted.** Approved by the operator on 2026-08-02.",
                "- **Status: Superseded by 2026-08-03-absent.md.**",
            ),
        )
        self.repo.commit("supersede into nothing")
        violations = self.repo.validate()
        self.assertEqual(len(violations), 1)
        self.assertIn("2026-08-03-absent.md", violations[0])

    def test_supersession_plus_body_edit_is_rejected(self) -> None:
        self.repo.write("2026-08-03-successor.md", SUCCESSOR_BODY)
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace(
                "- **Status: Accepted.** Approved by the operator on 2026-08-02.",
                "- **Status: Superseded by 2026-08-03-successor.md.**",
            ).replace("The chosen approach", "A different approach"),
        )
        self.repo.commit("supersede and revise")
        violations = self.repo.validate()
        self.assertEqual(len(violations), 1)
        self.assertIn("revised", violations[0])

    def test_draft_body_edit_is_allowed(self) -> None:
        self.repo.write("2026-08-04-draft.md", DRAFT_BODY)
        self.repo.commit("add draft")
        self.repo.write(
            "2026-08-04-draft.md",
            DRAFT_BODY.replace("The chosen approach", "A revised approach"),
        )
        self.repo.commit("revise draft")
        self.assertEqual(self.repo.validate(), [])

    def test_merge_base_comparison_ignores_unrelated_main_history(self) -> None:
        self.repo.write("2026-08-04-draft.md", DRAFT_BODY)
        self.repo.commit("add draft on feature")
        git(self.repo.root, "switch", "--quiet", "main")
        self.repo.write("2026-08-05-unrelated.md", ACCEPTED_BODY)
        self.repo.commit("unrelated accepted record on main")
        git(self.repo.root, "switch", "--quiet", "feature")
        self.assertEqual(self.repo.validate(), [])

    def test_missing_base_ref_fails_explicitly(self) -> None:
        with self.assertRaises(decisions.BaseRefError):
            self.repo.validate(base="origin/absent")


class LegacyRecordTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.repo = RepoFixture(self.stack)
        self.legacy_name = "2026-08-01-tautulli.md"
        self.repo.write(self.legacy_name, LEGACY_BODY)
        self.repo.commit("baseline legacy record")
        self.repo.branch("feature")

    def test_pre_enforcement_records_are_imported_byte_exact(self) -> None:
        self.assertEqual(
            decisions.LEGACY_ACCEPTED_STATUS,
            {
                "docs/decisions/2026-08-01-tautulli.md": "Status: Accepted (2026-08-02)",
                "docs/decisions/2026-08-02-plex-relay-sonos-design.md": (
                    "Status: Accepted (2026-08-02); "
                    "**remote-path selection superseded (2026-08-03)**"
                ),
                "docs/decisions/2026-08-03-agent-rules-runtime-contract-amendment.md": (
                    "Status: Accepted (2026-08-03)"
                ),
                "docs/decisions/2026-08-03-plex-public-envoy-amendment.md": (
                    "Status: **Approved (2026-08-03)** — independently reviewed and "
                    "revised before approval."
                ),
            },
        )

    def test_unchanged_legacy_record_is_accepted(self) -> None:
        self.repo.write("2026-08-04-other.md", DRAFT_BODY)
        self.repo.commit("unrelated draft")
        self.assertEqual(self.repo.validate(), [])

    def test_legacy_status_only_supersession_is_allowed(self) -> None:
        self.repo.write("2026-08-04-successor.md", SUCCESSOR_BODY)
        self.repo.write(
            self.legacy_name,
            LEGACY_BODY.replace(
                "Status: Accepted (2026-08-02)",
                "- **Status: Superseded by 2026-08-04-successor.md.**",
            ),
        )
        self.repo.commit("supersede legacy record")
        self.assertEqual(self.repo.validate(), [])

    def test_legacy_body_edit_is_rejected(self) -> None:
        self.repo.write(
            self.legacy_name,
            LEGACY_BODY.replace("Written before", "Rewritten after"),
        )
        self.repo.commit("revise legacy body")
        violations = self.repo.validate()
        self.assertEqual(len(violations), 1)
        self.assertIn("revised", violations[0])

    def test_new_record_may_not_use_legacy_status_syntax(self) -> None:
        self.repo.write("2026-08-04-new-legacy.md", LEGACY_BODY)
        self.repo.commit("add legacy-format record")
        violations = self.repo.validate()
        self.assertEqual(len(violations), 1)
        self.assertIn("2026-08-04-new-legacy.md", violations[0])
        self.assertIn("status", violations[0].lower())


class CommandLineTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.repo = RepoFixture(self.stack)
        self.repo.write("2026-08-02-example.md", ACCEPTED_BODY)
        self.repo.commit("baseline accepted record")
        self.repo.branch("feature")

    def _run(self) -> tuple[int, str]:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stdout):
            code = decisions.main(["validate", "--base", "main", "--repo", str(self.repo.root)])
        return code, stdout.getvalue()

    def test_clean_branch_exits_zero(self) -> None:
        self.repo.write("2026-08-04-new-topic.md", DRAFT_BODY)
        self.repo.commit("add draft")
        code, _ = self._run()
        self.assertEqual(code, 0)

    def test_violation_exits_nonzero_and_names_the_record(self) -> None:
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace("The chosen approach", "A different approach"),
        )
        self.repo.commit("revise accepted body")
        code, output = self._run()
        self.assertEqual(code, 1)
        self.assertIn("2026-08-02-example.md", output)

    def test_all_violations_are_reported_in_one_run(self) -> None:
        self.repo.write("2026-08-05-second.md", ACCEPTED_BODY)
        self.repo.commit("add a second accepted record")
        git(self.repo.root, "switch", "--quiet", "main")
        git(self.repo.root, "merge", "--quiet", "feature")
        git(self.repo.root, "switch", "--quiet", "feature")
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace("The chosen approach", "Changed."),
        )
        self.repo.write(
            "2026-08-05-second.md",
            ACCEPTED_BODY.replace("The chosen approach", "Also changed."),
        )
        self.repo.commit("revise both accepted records")
        code, output = self._run()
        self.assertEqual(code, 1)
        self.assertIn("2026-08-02-example.md", output)
        self.assertIn("2026-08-05-second.md", output)


class ParseRecordTest(unittest.TestCase):
    def _parse(self, body: str, name: str = "2026-08-02-example.md") -> object:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / name
            path.write_text(body, encoding="utf-8")
            return decisions.parse_record(path, f"{DECISIONS_DIR}/{name}")

    def test_accepted_status_allows_trailing_prose(self) -> None:
        record = self._parse(ACCEPTED_BODY)
        self.assertEqual(record.status, "Accepted")

    def test_draft_status_is_parsed(self) -> None:
        self.assertEqual(self._parse(DRAFT_BODY).status, "Draft")

    def test_superseded_status_captures_target(self) -> None:
        body = ACCEPTED_BODY.replace(
            "- **Status: Accepted.** Approved by the operator on 2026-08-02.",
            "- **Status: Superseded by 2026-08-03-successor.md.**",
        )
        record = self._parse(body)
        self.assertEqual(record.status, "Superseded")
        self.assertEqual(record.superseded_by, "2026-08-03-successor.md")

    def test_missing_status_line_is_an_error(self) -> None:
        with self.assertRaises(decisions.RecordError):
            self._parse("# No Status\n\nBody only.\n")

    def test_two_status_lines_are_an_error(self) -> None:
        with self.assertRaises(decisions.RecordError):
            self._parse(ACCEPTED_BODY + "\n- **Status: Draft.**\n")


LEGACY_PLEX_PATH = "docs/decisions/2026-08-02-plex-relay-sonos-design.md"
LEGACY_PLEX_STATUS = (
    "Status: Accepted (2026-08-02); **remote-path selection superseded (2026-08-03)**"
)
LEGACY_PLEX_BODY = f"""# Plex Relay and Sonos integration — design

{LEGACY_PLEX_STATUS}

## Decision

Imported pre-enforcement record.
"""

LEGACY_ENVOY_PATH = "docs/decisions/2026-08-03-plex-public-envoy-amendment.md"
LEGACY_ENVOY_STATUS = (
    "Status: **Approved (2026-08-03)** — independently reviewed and revised before approval."
)
LEGACY_ENVOY_BODY = f"""# Plex public Envoy amendment

{LEGACY_ENVOY_STATUS}

## Decision

Imported pre-enforcement record.
"""


class LegacyByteExactTest(unittest.TestCase):
    def test_annotated_plex_header_is_accepted_at_its_own_path(self) -> None:
        record = decisions.parse_text(LEGACY_PLEX_BODY, LEGACY_PLEX_PATH)
        self.assertEqual(record.status, "Accepted")
        self.assertTrue(record.legacy)

    def test_annotated_plex_header_is_rejected_at_another_legacy_path(self) -> None:
        with self.assertRaises(decisions.RecordError):
            decisions.parse_text(LEGACY_PLEX_BODY, "docs/decisions/2026-08-01-tautulli.md")

    def test_plain_header_is_rejected_at_the_plex_path(self) -> None:
        body = LEGACY_PLEX_BODY.replace(LEGACY_PLEX_STATUS, "Status: Accepted (2026-08-02)")
        with self.assertRaises(decisions.RecordError):
            decisions.parse_text(body, LEGACY_PLEX_PATH)

    def test_envoy_approved_header_is_accepted_at_its_own_path(self) -> None:
        record = decisions.parse_text(LEGACY_ENVOY_BODY, LEGACY_ENVOY_PATH)
        self.assertEqual(record.status, "Accepted")
        self.assertTrue(record.legacy)

    def test_envoy_header_with_another_date_is_rejected(self) -> None:
        body = LEGACY_ENVOY_BODY.replace("(2026-08-03)", "(2026-08-04)")
        with self.assertRaises(decisions.RecordError):
            decisions.parse_text(body, LEGACY_ENVOY_PATH)


class ContentChangedTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.repo = RepoFixture(self.stack)
        self.repo.write("2026-08-02-example.md", ACCEPTED_BODY)
        self.repo.write("2026-08-01-tautulli.md", LEGACY_BODY)
        self.repo.commit("baseline records")
        self.repo.branch("feature")

    def selected(self, base: str = "main") -> list[str]:
        return decisions.content_changed_records(self.repo.root, base)

    def test_added_record_is_selected(self) -> None:
        self.repo.write("2026-08-04-new-topic.md", DRAFT_BODY)
        self.repo.commit("add draft")
        self.assertEqual(self.selected(), [record_path("2026-08-04-new-topic.md")])

    def test_draft_body_edit_is_selected(self) -> None:
        self.repo.write("2026-08-04-draft.md", DRAFT_BODY)
        self.repo.commit("add draft")
        self.repo.write(
            "2026-08-04-draft.md",
            DRAFT_BODY.replace("The chosen approach", "A revised approach"),
        )
        self.repo.commit("revise draft")
        self.assertEqual(self.selected(), [record_path("2026-08-04-draft.md")])

    def test_accepted_body_edit_is_selected(self) -> None:
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace("The chosen approach", "A different approach"),
        )
        self.repo.commit("revise accepted body")
        self.assertEqual(self.selected(), [record_path("2026-08-02-example.md")])

    def test_status_only_supersession_selects_only_the_successor(self) -> None:
        self.repo.write("2026-08-03-successor.md", SUCCESSOR_BODY)
        self.repo.write(
            "2026-08-02-example.md",
            ACCEPTED_BODY.replace(
                "- **Status: Accepted.** Approved by the operator on 2026-08-02.",
                "- **Status: Superseded by 2026-08-03-successor.md.**",
            ),
        )
        self.repo.commit("supersede")
        self.assertEqual(self.selected(), [record_path("2026-08-03-successor.md")])

    def test_unchanged_accepted_record_is_not_selected(self) -> None:
        (self.repo.root / "notes.txt").write_text("unrelated\n", encoding="utf-8")
        self.repo.commit("unrelated change")
        self.assertEqual(self.selected(), [])

    def test_deleted_record_is_not_selected(self) -> None:
        self.repo.delete("2026-08-02-example.md")
        self.repo.commit("delete accepted record")
        self.assertEqual(self.selected(), [])

    def test_unparseable_modification_is_selected(self) -> None:
        self.repo.write("2026-08-04-draft.md", DRAFT_BODY)
        self.repo.commit("add draft")
        self.repo.write("2026-08-04-draft.md", "# No Status\n\nBody only.\n")
        self.repo.commit("break draft")
        self.assertEqual(self.selected(), [record_path("2026-08-04-draft.md")])

    def test_legacy_status_only_supersession_selects_only_the_successor(self) -> None:
        self.repo.write("2026-08-03-successor.md", SUCCESSOR_BODY)
        self.repo.write(
            "2026-08-01-tautulli.md",
            LEGACY_BODY.replace(
                "Status: Accepted (2026-08-02)",
                "- **Status: Superseded by 2026-08-03-successor.md.**",
            ),
        )
        self.repo.commit("supersede legacy record")
        self.assertEqual(self.selected(), [record_path("2026-08-03-successor.md")])

    def test_legacy_body_edit_is_selected(self) -> None:
        self.repo.write(
            "2026-08-01-tautulli.md",
            LEGACY_BODY.replace("Written before", "Rewritten after"),
        )
        self.repo.commit("revise legacy body")
        self.assertEqual(self.selected(), ["docs/decisions/2026-08-01-tautulli.md"])


class ChangedContentCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.repo = RepoFixture(self.stack)
        self.repo.write("2026-08-02-example.md", ACCEPTED_BODY)
        self.repo.commit("baseline accepted record")
        self.repo.branch("feature")

    def _run(self, *args: str) -> tuple[int, str]:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stdout):
            code = decisions.main(list(args))
        return code, stdout.getvalue()

    def test_null_delimited_output(self) -> None:
        self.repo.write("2026-08-04-new-topic.md", DRAFT_BODY)
        self.repo.commit("add draft")
        code, output = self._run(
            "changed-content", "--base", "main", "--repo", str(self.repo.root), "--null"
        )
        self.assertEqual(code, 0)
        self.assertEqual(output, record_path("2026-08-04-new-topic.md") + "\0")

    def test_newline_output_by_default(self) -> None:
        self.repo.write("2026-08-04-new-topic.md", DRAFT_BODY)
        self.repo.commit("add draft")
        code, output = self._run(
            "changed-content", "--base", "main", "--repo", str(self.repo.root)
        )
        self.assertEqual(code, 0)
        self.assertEqual(output, record_path("2026-08-04-new-topic.md") + "\n")

    def test_missing_base_ref_exits_two(self) -> None:
        code, output = self._run(
            "changed-content", "--base", "origin/absent", "--repo", str(self.repo.root)
        )
        self.assertEqual(code, 2)
        self.assertIn("origin/absent", output)


class RenderIndexTest(unittest.TestCase):
    def test_exact_document(self) -> None:
        superseded = ACCEPTED_BODY.replace(
            "- **Status: Accepted.** Approved by the operator on 2026-08-02.",
            "- **Status: Superseded by 2026-08-03-example-later.md.**",
        )
        records = [
            decisions.parse_text(ACCEPTED_BODY, record_path("2026-08-02-example.md")),
            decisions.parse_text(DRAFT_BODY, record_path("2026-08-03-example-alpha.md")),
            decisions.parse_text(SUCCESSOR_BODY, record_path("2026-08-03-example-later.md")),
            decisions.parse_text(superseded, record_path("2026-08-01-old.md")),
            decisions.parse_text(LEGACY_PLEX_BODY, LEGACY_PLEX_PATH),
        ]
        self.assertEqual(
            decisions.render_index(records),
            """# Decision Records

Generated by `scripts/repository/decisions.py`; regenerate with `just repo decisions-index`. Do not edit by hand.

| Date | Topic | Status | Superseded by |
| --- | --- | --- | --- |
| 2026-08-03 | example alpha | Draft | — |
| 2026-08-03 | example later | Accepted | — |
| 2026-08-02 | example | Accepted | — |
| 2026-08-02 | plex relay sonos design | Accepted | — |
| 2026-08-01 | old | Superseded | 2026-08-03-example-later.md |
""",
        )


class IndexRecordsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.repo = RepoFixture(self.stack)

    def test_discovery_sorts_and_excludes_non_records(self) -> None:
        self.repo.write("2026-08-02-b-topic.md", ACCEPTED_BODY)
        self.repo.write("2026-08-03-a-topic.md", DRAFT_BODY)
        directory = self.repo.root / DECISIONS_DIR
        (directory / "README.md").write_text("# Index\n", encoding="utf-8")
        (directory / "reviews").mkdir()
        (directory / "reviews" / "2026-08-02-b-topic-review.md").write_text(
            "review\n", encoding="utf-8"
        )
        (directory / "images").mkdir()
        (directory / "images" / "note.txt").write_text("image\n", encoding="utf-8")
        paths = [record.path for record in decisions.index_records(self.repo.root)]
        self.assertEqual(
            paths,
            [record_path("2026-08-03-a-topic.md"), record_path("2026-08-02-b-topic.md")],
        )


class IndexCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.repo = RepoFixture(self.stack)
        self.repo.write("2026-08-02-example.md", ACCEPTED_BODY)
        self.repo.commit("baseline accepted record")

    def _run(self, *args: str) -> tuple[int, str]:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stdout):
            code = decisions.main(list(args))
        return code, stdout.getvalue()

    def _index_path(self) -> Path:
        return self.repo.root / DECISIONS_DIR / "README.md"

    def test_write_then_check_passes(self) -> None:
        code, _ = self._run("index", "--write", "--repo", str(self.repo.root))
        self.assertEqual(code, 0)
        code, _ = self._run("index", "--check", "--repo", str(self.repo.root))
        self.assertEqual(code, 0)

    def test_written_content_matches_render(self) -> None:
        self._run("index", "--write", "--repo", str(self.repo.root))
        self.assertEqual(
            self._index_path().read_text(encoding="utf-8"),
            decisions.render_index(decisions.index_records(self.repo.root)),
        )

    def test_check_fails_when_index_is_stale(self) -> None:
        self._run("index", "--write", "--repo", str(self.repo.root))
        self.repo.write("2026-08-04-new-topic.md", DRAFT_BODY)
        code, output = self._run("index", "--check", "--repo", str(self.repo.root))
        self.assertEqual(code, 1)
        self.assertIn("+| 2026-08-04 | new topic | Draft | — |", output)

    def test_check_fails_when_index_is_missing(self) -> None:
        code, output = self._run("index", "--check", "--repo", str(self.repo.root))
        self.assertEqual(code, 1)
        self.assertIn("README.md", output)


if __name__ == "__main__":
    unittest.main()
