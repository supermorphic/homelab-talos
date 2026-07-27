"""Build a safe, atomic publication bundle for the in-cluster report archive."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import io
import json
import re
import shutil
import sys
import tarfile
from collections.abc import Iterable
from pathlib import Path, PurePosixPath
from typing import Any

from allure_report import RUN_ID_PATTERN, ReportError, load_object, parse_finished_at

SCHEMA_VERSION = 1
RESULTS = {"passed", "failed", "broken", "skipped"}
SEGMENT_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
GENERATION_PATTERN = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
CANONICAL_DOCUMENTS = ("junit.xml", "summary.json", "environment.json", "evidence.json")
MAX_PUBLISH_BYTES = 250 * 1024 * 1024
MAX_RUNS = 200
MAX_AGE_DAYS = 90
METRIC_LABELS = ("source", "tier", "target", "scenario", "cluster", "execution_origin")
ROLLUPS = (
    ("overall", "Latest Overall", {}),
    ("validation", "Validate", {"source": "validation"}),
    ("platform-smoke", "Platform Smoke", {"tier": "smoke", "target": "platform"}),
    ("media-smoke", "Media Smoke", {"tier": "smoke", "target": "media"}),
    ("resilience", "Resilience", {"tier": "resilience"}),
    ("conformance", "Conformance", {"tier": "conformance"}),
)


class PublishError(RuntimeError):
    """Publication input or existing archive state is invalid."""


def read_optional_object(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists() or path.stat().st_size == 0:
        return default
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PublishError(f"invalid remote JSON: {path.name}") from error
    if not isinstance(value, dict):
        raise PublishError(f"remote JSON root must be an object: {path.name}")
    return value


def require_string(value: Any, name: str, *, segment: bool = False) -> str:
    if not isinstance(value, str) or not value:
        raise PublishError(f"{name} must be a non-empty string")
    if segment and not SEGMENT_PATTERN.fullmatch(value):
        raise PublishError(f"{name} is not a safe path/metric segment: {value}")
    return value


def require_metric_label(value: Any, name: str) -> str:
    # A canonical null scenario is represented as "_" only in metric keys and
    # latest-path segments. Do not widen the general segment grammar or allow
    # other dimensions to use the reserved sentinel.
    if name == "scenario" and value == "_":
        return value
    return require_string(value, name, segment=True)


def parse_utc(value: Any, name: str) -> dt.datetime:
    try:
        parsed = parse_finished_at(value)
    except ReportError as error:
        raise PublishError(f"{name} must be RFC3339 UTC") from error
    return parsed


def validate_existing(catalog: dict[str, Any], state: dict[str, Any]) -> None:
    if catalog.get("schema_version") != SCHEMA_VERSION or not isinstance(
        catalog.get("runs"), list
    ):
        raise PublishError("remote catalog violates schema v1")
    if state.get("schema_version") != SCHEMA_VERSION:
        raise PublishError("remote publication state violates schema v1")
    for field in ("seen_runs", "runs_total", "cases_total"):
        if not isinstance(state.get(field), dict):
            raise PublishError(f"remote publication state {field} must be an object")
    if not isinstance(state.get("last_success", {}), dict):
        raise PublishError("remote publication state last_success must be an object")
    for run_id, digest in state["seen_runs"].items():
        if not RUN_ID_PATTERN.fullmatch(run_id) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise PublishError(f"remote publication state has an invalid seen run: {run_id}")
    for field in ("runs_total", "cases_total"):
        for key, value in state[field].items():
            labels, suffix = decode_counter_key(key)
            for name, label in labels.items():
                require_metric_label(label, name)
            if suffix not in RESULTS:
                raise PublishError(f"remote publication state {field} has an invalid status")
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise PublishError(f"remote publication state {field} has an invalid counter")
    for key, value in state.get("last_success", {}).items():
        labels, suffix = decode_counter_key(key)
        for name, label in labels.items():
            require_metric_label(label, name)
        if suffix != "passed":
            raise PublishError("remote publication state has an invalid last-success key")
        parse_utc(value, "stored last success")
    seen_ids: set[str] = set()
    for entry in catalog["runs"]:
        if not isinstance(entry, dict):
            raise PublishError("remote catalog run must be an object")
        run_id = require_string(entry.get("run_id"), "catalog run_id")
        if not RUN_ID_PATTERN.fullmatch(run_id) or run_id in seen_ids:
            raise PublishError(f"remote catalog has invalid or duplicate run: {run_id}")
        seen_ids.add(run_id)
        digest = require_string(entry.get("digest"), f"{run_id} digest")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise PublishError(f"remote catalog has an invalid digest: {run_id}")
        if state["seen_runs"].get(run_id) != digest:
            raise PublishError(f"remote catalog and seen-run state disagree: {run_id}")
        parse_utc(entry.get("end"), f"{run_id} end")
        for field in ("source", "suite", "tier", "target", "cluster", "execution_origin"):
            require_string(entry.get(field), f"{run_id} {field}", segment=True)
        scenario = entry.get("scenario")
        if scenario is not None:
            require_string(scenario, f"{run_id} scenario", segment=True)
        if entry.get("result") not in RESULTS or not isinstance(entry.get("authoritative"), bool):
            raise PublishError(f"remote catalog has invalid result/authority: {run_id}")
        duration = entry.get("duration_seconds")
        if not isinstance(duration, int) or isinstance(duration, bool) or duration < 0:
            raise PublishError(f"remote catalog has invalid duration: {run_id}")
        if not isinstance(entry.get("junit"), dict):
            raise PublishError(f"remote catalog has invalid JUnit counts: {run_id}")
        for field in ("tests", "passed", "failures", "errors", "skipped"):
            value = entry["junit"].get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise PublishError(f"remote catalog has invalid JUnit counts: {run_id}")


def safe_evidence_paths(run_dir: Path, evidence: dict[str, Any]) -> list[Path]:
    artifacts = evidence.get("artifacts")
    if not isinstance(artifacts, list):
        raise PublishError("evidence artifacts must be an array")
    paths: list[Path] = []
    seen: set[str] = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise PublishError("evidence artifact must be an object")
        value = artifact.get("path")
        if not isinstance(value, str):
            raise PublishError("evidence path must be a string")
        pure = PurePosixPath(value)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or len(pure.parts) < 2
            or pure.parts[0] not in {"logs", "diagnostics"}
        ):
            raise PublishError(f"unsafe evidence path: {value}")
        normalized = str(pure)
        if normalized in seen:
            raise PublishError(f"duplicate evidence path: {normalized}")
        seen.add(normalized)
        path = run_dir.joinpath(*pure.parts)
        if path.is_symlink() or not path.is_file():
            raise PublishError(f"evidence path is missing or unsafe: {normalized}")
        paths.append(path)
    return sorted(paths)


def canonical_files(run_dir: Path) -> list[Path]:
    if run_dir.is_symlink() or not run_dir.is_dir():
        raise PublishError("canonical run directory is missing or a symlink")
    files: list[Path] = []
    for name in CANONICAL_DOCUMENTS:
        path = run_dir / name
        if path.is_symlink() or not path.is_file():
            raise PublishError(f"canonical document is missing or unsafe: {name}")
        files.append(path)
    files.extend(safe_evidence_paths(run_dir, load_object(run_dir / "evidence.json")))
    return files


def tree_digest(run_dir: Path, files: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(files, key=lambda item: item.relative_to(run_dir).as_posix()):
        relative = path.relative_to(run_dir).as_posix()
        digest.update(relative.encode())
        digest.update(b"\0")
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
        digest.update(b"\0")
    return digest.hexdigest()


def directory_size_and_safety(root: Path) -> int:
    if root.is_symlink() or not root.is_dir():
        raise PublishError(f"report directory is missing or unsafe: {root}")
    total = 0
    for path in root.rglob("*"):
        if path.is_symlink():
            raise PublishError(f"report contains a symlink: {path.relative_to(root)}")
        if path.is_file():
            total += path.stat().st_size
            if total > MAX_PUBLISH_BYTES:
                raise PublishError("report exceeds the 250 MiB publication limit")
    return total


def write_canonical_archive(run_dir: Path, files: list[Path], output: Path) -> None:
    with tarfile.open(output, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for directory in ("logs", "diagnostics"):
            info = tarfile.TarInfo(directory)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.mtime = 0
            archive.addfile(info)
        for path in sorted(files, key=lambda item: item.relative_to(run_dir).as_posix()):
            relative = path.relative_to(run_dir).as_posix()
            info = tarfile.TarInfo(relative)
            data = path.read_bytes()
            info.size = len(data)
            info.mode = 0o644
            info.mtime = 0
            archive.addfile(info, io.BytesIO(data))


def labels_from(summary: dict[str, Any], environment: dict[str, Any]) -> dict[str, str]:
    scenario = summary.get("scenario")
    if scenario is None:
        scenario = "_"
    else:
        scenario = require_string(scenario, "scenario", segment=True)
    cluster = environment.get("cluster", {}).get("name") or "unavailable"
    labels = {
        "source": summary.get("source"),
        "tier": summary.get("tier"),
        "target": summary.get("target"),
        "scenario": scenario,
        "cluster": cluster,
        "execution_origin": summary.get("execution_origin"),
    }
    return {name: require_metric_label(labels[name], name) for name in METRIC_LABELS}


def make_entry(
    summary: dict[str, Any],
    environment: dict[str, Any],
    digest: str,
    origin_main_sha: str,
    flux_main_sha: str,
    published_at: str,
) -> dict[str, Any]:
    run_id = require_string(summary.get("run_id"), "run_id")
    if not RUN_ID_PATTERN.fullmatch(run_id):
        raise PublishError(f"invalid run ID: {run_id}")
    result = require_string(summary.get("result"), "result")
    if result not in RESULTS:
        raise PublishError(f"invalid result: {result}")
    git_sha = require_string(summary.get("git_sha"), "git_sha")
    if environment.get("git", {}).get("sha") != git_sha:
        raise PublishError("summary and environment Git SHAs differ")
    if not isinstance(environment.get("git", {}).get("dirty"), bool):
        raise PublishError("environment git.dirty must be boolean")
    labels = labels_from(summary, environment)
    end = require_string(summary.get("end"), "end")
    parse_utc(end, "end")
    start = require_string(summary.get("start"), "start")
    parse_utc(start, "start")
    junit = summary.get("junit")
    if not isinstance(junit, dict):
        raise PublishError("summary junit must be an object")
    counts: dict[str, int] = {}
    for field in ("tests", "passed", "failures", "errors", "skipped"):
        value = junit.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise PublishError(f"summary junit.{field} must be a non-negative integer")
        counts[field] = value
    duration = summary.get("duration_seconds")
    if not isinstance(duration, int) or isinstance(duration, bool) or duration < 0:
        raise PublishError("summary duration_seconds must be a non-negative integer")
    authoritative = (
        SHA_PATTERN.fullmatch(git_sha) is not None
        and git_sha == origin_main_sha
        and git_sha == flux_main_sha
        and environment["git"]["dirty"] is False
    )
    return {
        "run_id": run_id,
        "digest": digest,
        "source": labels["source"],
        "suite": require_string(summary.get("suite"), "suite", segment=True),
        "tier": labels["tier"],
        "target": labels["target"],
        "scenario": None if labels["scenario"] == "_" else labels["scenario"],
        "cluster": labels["cluster"],
        "execution_origin": labels["execution_origin"],
        "start": start,
        "end": end,
        "duration_seconds": duration,
        "result": result,
        "junit": counts,
        "git_sha": git_sha,
        "authoritative": authoritative,
        "published_at": published_at,
        "report_url": f"/reports/{run_id}/awesome/",
        "artifact_url": f"/artifacts/{run_id}.tar.gz",
    }


def logical_key(entry: dict[str, Any]) -> tuple[str, str, str, str]:
    return (
        str(entry["source"]),
        str(entry["tier"]),
        str(entry["target"]),
        str(entry.get("scenario") or "_"),
    )


def retain_runs(
    entries: list[dict[str, Any]], now: dt.datetime
) -> tuple[list[dict[str, Any]], list[str]]:
    ordered = sorted(
        entries,
        key=lambda entry: (parse_utc(entry["end"], "catalog end"), str(entry["run_id"])),
        reverse=True,
    )
    protected: set[str] = set()
    seen_keys: set[tuple[str, str, str, str]] = set()
    for entry in ordered:
        key = logical_key(entry)
        if key not in seen_keys:
            protected.add(str(entry["run_id"]))
            seen_keys.add(key)
    seen_authoritative_keys: set[tuple[str, str, str, str]] = set()
    for entry in ordered:
        if not entry.get("authoritative"):
            continue
        key = logical_key(entry)
        if key not in seen_authoritative_keys:
            protected.add(str(entry["run_id"]))
            seen_authoritative_keys.add(key)
    cutoff = now - dt.timedelta(days=MAX_AGE_DAYS)
    kept: list[dict[str, Any]] = []
    pruned: list[str] = []
    for index, entry in enumerate(ordered):
        run_id = str(entry["run_id"])
        recent = parse_utc(entry["end"], "catalog end") >= cutoff
        if run_id in protected or (index < MAX_RUNS and recent):
            kept.append(entry)
        else:
            pruned.append(run_id)
    return kept, sorted(pruned)


def counter_key(entry: dict[str, Any], suffix: str) -> str:
    values = [
        str(entry["source"]),
        str(entry["tier"]),
        str(entry["target"]),
        str(entry.get("scenario") or "_"),
        str(entry["cluster"]),
        str(entry["execution_origin"]),
        suffix,
    ]
    return json.dumps(values, separators=(",", ":"))


def update_counters(state: dict[str, Any], entry: dict[str, Any]) -> None:
    runs_total = state["runs_total"]
    key = counter_key(entry, str(entry["result"]))
    runs_total[key] = int(runs_total.get(key, 0)) + 1
    cases_total = state["cases_total"]
    for status, field in (
        ("passed", "passed"),
        ("failed", "failures"),
        ("broken", "errors"),
        ("skipped", "skipped"),
    ):
        case_key = counter_key(entry, status)
        cases_total[case_key] = int(cases_total.get(case_key, 0)) + int(entry["junit"][field])
    if entry.get("authoritative") and entry["result"] == "passed":
        last_success = state.setdefault("last_success", {})
        key = counter_key(entry, "passed")
        current = last_success.get(key)
        if current is None or parse_utc(entry["end"], "entry end") > parse_utc(
            current, "stored last success"
        ):
            last_success[key] = entry["end"]


def prom_escape(value: str) -> str:
    return value.replace("\\", r"\\").replace("\n", r"\n").replace('"', r"\"")


def prom_labels(entry: dict[str, Any], extra: tuple[str, str] | None = None) -> str:
    values = {
        "source": str(entry["source"]),
        "tier": str(entry["tier"]),
        "target": str(entry["target"]),
        "scenario": str(entry.get("scenario") or "_"),
        "cluster": str(entry["cluster"]),
        "execution_origin": str(entry["execution_origin"]),
    }
    if extra is not None:
        values[extra[0]] = extra[1]
    return ",".join(f'{key}="{prom_escape(value)}"' for key, value in values.items())


def decode_counter_key(key: str) -> tuple[dict[str, str], str]:
    try:
        values = json.loads(key)
    except json.JSONDecodeError as error:
        raise PublishError("publication counter has an invalid key") from error
    if (
        not isinstance(values, list)
        or len(values) != 7
        or not all(isinstance(item, str) for item in values)
    ):
        raise PublishError("publication counter has an invalid key")
    entry = dict(zip(METRIC_LABELS, values[:6], strict=True))
    return entry, values[6]


def latest_authoritative(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    latest: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    for entry in entries:
        if not entry.get("authoritative"):
            continue
        key = logical_key(entry)
        existing = latest.get(key)
        if existing is None or (entry["end"], entry["run_id"]) > (
            existing["end"],
            existing["run_id"],
        ):
            latest[key] = entry
    return sorted(latest.values(), key=logical_key)


def latest_rollups(
    entries: list[dict[str, Any]],
) -> list[tuple[str, str, dict[str, Any]]]:
    authoritative = sorted(
        (entry for entry in entries if entry.get("authoritative")),
        key=lambda entry: (entry["end"], entry["run_id"]),
        reverse=True,
    )
    rollups = []
    for slug, label, criteria in ROLLUPS:
        match = next(
            (
                entry
                for entry in authoritative
                if all(entry.get(field) == value for field, value in criteria.items())
            ),
            None,
        )
        if match is not None:
            rollups.append((slug, label, match))
    return rollups


def render_metrics(entries: list[dict[str, Any]], state: dict[str, Any]) -> str:
    lines = [
        "# HELP homelab_test_last_run_status Whether the latest authoritative run passed.",
        "# TYPE homelab_test_last_run_status gauge",
        "# HELP homelab_test_last_run_timestamp_seconds Latest authoritative completion time.",
        "# TYPE homelab_test_last_run_timestamp_seconds gauge",
        "# HELP homelab_test_last_success_timestamp_seconds Latest authoritative successful completion time.",
        "# TYPE homelab_test_last_success_timestamp_seconds gauge",
        "# HELP homelab_test_last_run_duration_seconds Latest authoritative run duration.",
        "# TYPE homelab_test_last_run_duration_seconds gauge",
        "# HELP homelab_test_last_run_cases Cases in the latest authoritative run.",
        "# TYPE homelab_test_last_run_cases gauge",
    ]
    for entry in latest_authoritative(entries):
        labels = prom_labels(entry)
        timestamp = int(parse_utc(entry["end"], "catalog end").timestamp())
        lines.append(
            f"homelab_test_last_run_status{{{labels}}} {1 if entry['result'] == 'passed' else 0}"
        )
        lines.append(f"homelab_test_last_run_timestamp_seconds{{{labels}}} {timestamp}")
        lines.append(
            f"homelab_test_last_run_duration_seconds{{{labels}}} {entry['duration_seconds']}"
        )
        success_key = counter_key(entry, "passed")
        success = state.get("last_success", {}).get(success_key)
        if success is not None:
            success_timestamp = int(parse_utc(success, "stored last success").timestamp())
            lines.append(
                f"homelab_test_last_success_timestamp_seconds{{{labels}}} {success_timestamp}"
            )
        for status, field in (
            ("passed", "passed"),
            ("failed", "failures"),
            ("broken", "errors"),
            ("skipped", "skipped"),
        ):
            lines.append(
                f"homelab_test_last_run_cases{{{prom_labels(entry, ('status', status))}}} "
                f"{entry['junit'][field]}"
            )
    lines.extend(
        [
            "# HELP homelab_test_runs_total Lifetime published runs.",
            "# TYPE homelab_test_runs_total counter",
        ]
    )
    for key, value in sorted(state["runs_total"].items()):
        labels, result = decode_counter_key(key)
        lines.append(
            f"homelab_test_runs_total{{{prom_labels(labels, ('result', result))}}} {int(value)}"
        )
    lines.extend(
        [
            "# HELP homelab_test_cases_total Lifetime published test cases.",
            "# TYPE homelab_test_cases_total counter",
        ]
    )
    for key, value in sorted(state["cases_total"].items()):
        labels, status = decode_counter_key(key)
        lines.append(
            f"homelab_test_cases_total{{{prom_labels(labels, ('status', status))}}} {int(value)}"
        )
    return "\n".join(lines) + "\n"


def render_homepage(entries: list[dict[str, Any]]) -> dict[str, Any]:
    markers = {"passed": "✓", "failed": "✗", "broken": "✗", "skipped": "!"}
    return {
        "items": [
            {
                "name": f"{markers[entry['result']]} {label}",
                "end": entry["end"],
                "result": entry["result"],
                "path": f"/latest/{slug}/",
            }
            for slug, label, entry in latest_rollups(entries)
        ]
    }


def render_index(entries: list[dict[str, Any]], generated_at: str) -> str:
    rows = []
    for entry in sorted(entries, key=lambda item: (item["end"], item["run_id"]), reverse=True):
        marker = "authoritative" if entry.get("authoritative") else "candidate"
        rows.append(
            "<tr>"
            f'<td><a href="{html.escape(entry["report_url"])}">'
            f"{html.escape(entry['run_id'])}</a></td>"
            f"<td>{html.escape(entry['tier'])}</td>"
            f"<td>{html.escape(entry['target'])}</td>"
            f"<td>{html.escape(entry.get('scenario') or '—')}</td>"
            f"<td>{html.escape(entry['result'])}</td>"
            f"<td>{marker}</td>"
            f"<td>{html.escape(entry['end'])}</td>"
            f'<td><a href="{html.escape(entry["artifact_url"])}">artifact</a></td>'
            "</tr>"
        )
    return (
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>Homelab Test Reports</title>"
        "<style>body{font:16px system-ui;margin:2rem;color:#18202a}"
        "table{border-collapse:collapse;width:100%}th,td{padding:.55rem;"
        "border-bottom:1px solid #d7dde5;text-align:left}th{background:#f3f5f8}"
        "code{background:#eef1f5;padding:.15rem .3rem}</style></head><body><main>"
        "<h1>Homelab Test Reports</h1>"
        f"<p>Generated <code>{html.escape(generated_at)}</code>. "
        "Authoritative rows match clean current-main test and Flux revisions; "
        "candidate rows remain inspectable but do not drive latest links or metrics.</p>"
        "<table><thead><tr><th>Run</th><th>Tier</th><th>Target</th><th>Scenario</th>"
        "<th>Result</th><th>Authority</th><th>Completed</th><th>Download</th>"
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table></main></body></html>\n"
    )


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_redirect(path: Path, target: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    escaped = html.escape(target, quote=True)
    path.write_text(
        '<!doctype html><html><head><meta charset="utf-8">'
        f'<meta http-equiv="refresh" content="0; url={escaped}">'
        f'<link rel="canonical" href="{escaped}"></head>'
        f'<body><a href="{escaped}">Open latest report</a></body></html>\n',
        encoding="utf-8",
    )


def checksum_manifest(bundle: Path) -> None:
    lines = []
    for path in sorted(item for item in bundle.rglob("*") if item.is_file()):
        if path.name == "manifest.sha256":
            continue
        relative = path.relative_to(bundle).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {relative}")
    (bundle / "manifest.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_bundle_archive(bundle: Path, archive: Path) -> None:
    bundle = bundle.resolve()
    archive = archive.resolve()
    if archive.is_relative_to(bundle):
        raise PublishError("publication archive must be outside the bundle directory")
    if archive.exists():
        raise PublishError("publication archive path must not already exist")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "w", format=tarfile.PAX_FORMAT) as output:
        for path in sorted(
            bundle.rglob("*"), key=lambda item: item.relative_to(bundle).as_posix()
        ):
            relative = path.relative_to(bundle).as_posix()
            if path.is_symlink():
                raise PublishError(f"publication bundle contains a symlink: {relative}")
            info = tarfile.TarInfo(relative)
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mtime = 0
            if path.is_dir():
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                output.addfile(info)
            elif path.is_file():
                info.type = tarfile.REGTYPE
                info.mode = 0o644
                info.size = path.stat().st_size
                with path.open("rb") as stream:
                    output.addfile(info, stream)
            else:
                raise PublishError(f"publication bundle has an unsafe entry: {relative}")


def prepare(args: argparse.Namespace) -> dict[str, Any]:
    run_dir = args.run_dir.resolve()
    run_id = run_dir.name
    if not RUN_ID_PATTERN.fullmatch(run_id):
        raise PublishError(f"invalid canonical run ID: {run_id}")
    report_dir = args.report_dir.resolve()
    if not (report_dir / "awesome" / "index.html").is_file():
        raise PublishError("Allure report is missing awesome/index.html")
    report_size = directory_size_and_safety(report_dir)
    files = canonical_files(run_dir)
    canonical_size = sum(path.stat().st_size for path in files)
    if canonical_size + report_size > MAX_PUBLISH_BYTES:
        raise PublishError("canonical run and report exceed the 250 MiB publication limit")
    digest = tree_digest(run_dir, files)
    catalog = read_optional_object(
        args.remote_catalog,
        {"schema_version": SCHEMA_VERSION, "generated_at": None, "runs": []},
    )
    state = read_optional_object(
        args.remote_state,
        {
            "schema_version": SCHEMA_VERSION,
            "generation": "bootstrap",
            "seen_runs": {},
            "runs_total": {},
            "cases_total": {},
            "last_success": {},
        },
    )
    validate_existing(catalog, state)
    state.setdefault("last_success", {})
    existing_digest = state["seen_runs"].get(run_id)
    if existing_digest is not None:
        if existing_digest != digest:
            raise PublishError("run ID was already published with different content")
        return {"status": "idempotent", "run_id": run_id, "digest": digest}

    if args.output_dir.exists() and any(args.output_dir.iterdir()):
        raise PublishError("publication output directory must be empty")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    now = parse_utc(args.now, "publication time")
    generated_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    generation = f"{now.strftime('%Y%m%dT%H%M%SZ')}-{digest[:8]}"
    if not GENERATION_PATTERN.fullmatch(generation):
        raise PublishError("could not construct a safe generation ID")
    summary = load_object(run_dir / "summary.json")
    environment = load_object(run_dir / "environment.json")
    entry = make_entry(
        summary,
        environment,
        digest,
        args.origin_main_sha,
        args.flux_main_sha,
        generated_at,
    )
    entries = [item for item in catalog["runs"] if item.get("run_id") != run_id]
    entries.append(entry)
    retained, pruned = retain_runs(entries, now)
    state["seen_runs"][run_id] = digest
    update_counters(state, entry)
    state["generation"] = generation
    state["last_published_at"] = generated_at

    bundle = args.output_dir
    report_target = bundle / "report" / run_id
    shutil.copytree(report_dir, report_target, symlinks=False)
    artifact_target = bundle / "artifact" / f"{run_id}.tar.gz"
    artifact_target.parent.mkdir(parents=True)
    write_canonical_archive(run_dir, files, artifact_target)
    generation_root = bundle / "generation" / generation
    catalog_output = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": generated_at,
        "runs": retained,
    }
    write_json(generation_root / "catalog.json", catalog_output)
    write_json(generation_root / "state.json", state)
    write_json(generation_root / "api" / "homepage.json", render_homepage(retained))
    (generation_root / "api" / "metrics.prom").write_text(
        render_metrics(retained, state), encoding="utf-8"
    )
    (generation_root / "index.html").write_text(
        render_index(retained, generated_at), encoding="utf-8"
    )
    if args.history.exists():
        shutil.copy2(args.history, generation_root / "history.jsonl")
    else:
        (generation_root / "history.jsonl").write_text("", encoding="utf-8")
    for latest in latest_authoritative(retained):
        scenario = latest.get("scenario") or "_"
        write_redirect(
            generation_root
            / "latest"
            / latest["tier"]
            / latest["target"]
            / scenario
            / "index.html",
            latest["report_url"],
        )
    for slug, _label, latest in latest_rollups(retained):
        write_redirect(
            generation_root / "latest" / slug / "index.html",
            latest["report_url"],
        )
    (bundle / "prune.txt").write_text("".join(f"{run}\n" for run in pruned), encoding="utf-8")
    checksum_manifest(bundle)
    write_bundle_archive(bundle, args.archive)
    return {
        "status": "prepared",
        "run_id": run_id,
        "digest": digest,
        "generation": generation,
        "authoritative": entry["authoritative"],
        "pruned": pruned,
    }


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--run-dir", type=Path, required=True)
    value.add_argument("--report-dir", type=Path, required=True)
    value.add_argument("--remote-catalog", type=Path, required=True)
    value.add_argument("--remote-state", type=Path, required=True)
    value.add_argument("--history", type=Path, required=True)
    value.add_argument("--origin-main-sha", required=True)
    value.add_argument("--flux-main-sha", required=True)
    value.add_argument("--output-dir", type=Path, required=True)
    value.add_argument("--archive", type=Path, required=True)
    value.add_argument("--now", required=True)
    return value


def main() -> int:
    args = parser().parse_args()
    for name in ("origin_main_sha", "flux_main_sha"):
        value = getattr(args, name)
        if not SHA_PATTERN.fullmatch(value):
            print(f"{name.replace('_', '-')} must be a full lowercase Git SHA", file=sys.stderr)
            return 2
    try:
        result = prepare(args)
    except (PublishError, ReportError, OSError, tarfile.TarError) as error:
        print(f"Publication preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
