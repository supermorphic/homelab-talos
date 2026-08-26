#!/usr/bin/env python3
"""Validate executable behavior of the Centralized Logs Grafana dashboard."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


class ValidationError(Exception):
    """Raised when a dashboard behavior invariant is not satisfied."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def normalized(expression: str) -> str:
    return re.sub(r"\s+", " ", expression).strip()


def panel_by_title(dashboard: dict[str, Any], title: str) -> dict[str, Any]:
    matches = [panel for panel in dashboard.get("panels", []) if panel.get("title") == title]
    require(len(matches) == 1, f"expected exactly one panel titled {title!r}")
    return matches[0]


def require_query_panel(
    dashboard: dict[str, Any], title: str, expected_expression: str
) -> dict[str, Any]:
    panel = panel_by_title(dashboard, title)
    require(
        panel.get("datasource") == {"type": "prometheus", "uid": "${prometheus}"},
        f"{title}: must use the Prometheus datasource variable",
    )
    targets = panel.get("targets", [])
    require(len(targets) == 1, f"{title}: must contain exactly one query")
    require(targets[0].get("refId") == "A", f"{title}: query refId must be A")
    require(
        normalized(targets[0].get("expr", "")) == normalized(expected_expression),
        f"{title}: query does not preserve the required operational calculation",
    )
    return panel


def validate_operational_panels(dashboard: dict[str, Any]) -> None:
    require_query_panel(
        dashboard,
        "Alloy delivery drops",
        'sum by (service, reason) (rate(loki_write_dropped_entries_total{namespace="monitoring",service=~"alloy-logs|alloy-events"}[$__rate_interval]))',
    )
    require_query_panel(
        dashboard,
        "Loki discarded entries",
        'sum by (reason) (rate(loki_discarded_samples_total{namespace="monitoring",job="monitoring/loki"}[$__rate_interval]))',
    )
    require_query_panel(
        dashboard,
        "Loki 5xx requests",
        'sum by (route, status_code) (rate(loki_request_duration_seconds_count{namespace="monitoring",job="monitoring/loki",status_code=~"5.."}[$__rate_interval]))',
    )
    compactor = require_query_panel(
        dashboard,
        "Seconds since successful compaction",
        'time() - loki_boltdb_shipper_compact_tables_operation_last_successful_run_timestamp_seconds{namespace="monitoring",job="monitoring/loki"}',
    )
    require(
        [
            step.get("value")
            for step in compactor.get("fieldConfig", {})
            .get("defaults", {})
            .get("thresholds", {})
            .get("steps", [])
        ]
        == [None, 10800],
        "Seconds since successful compaction: threshold must remain three hours",
    )

    utilization = require_query_panel(
        dashboard,
        "Loki PVC utilization",
        '100 * (1 - kubelet_volume_stats_available_bytes{namespace="monitoring",persistentvolumeclaim="storage-loki-0"} / kubelet_volume_stats_capacity_bytes{namespace="monitoring",persistentvolumeclaim="storage-loki-0"})',
    )
    utilization_defaults = utilization.get("fieldConfig", {}).get("defaults", {})
    require(
        utilization_defaults.get("unit") == "percent"
        and utilization_defaults.get("min") == 0
        and utilization_defaults.get("max") == 100,
        "Loki PVC utilization: display must be bounded from 0 to 100 percent",
    )
    require(
        [step.get("value") for step in utilization_defaults.get("thresholds", {}).get("steps", [])]
        == [None, 70, 85],
        "Loki PVC utilization: thresholds must be 70 percent warning and 85 percent critical",
    )

    growth = require_query_panel(
        dashboard,
        "Loki stored-data growth",
        'kubelet_volume_stats_capacity_bytes{namespace="monitoring",persistentvolumeclaim="storage-loki-0"} - kubelet_volume_stats_available_bytes{namespace="monitoring",persistentvolumeclaim="storage-loki-0"}',
    )
    require(
        growth.get("fieldConfig", {}).get("defaults", {}).get("unit") == "bytes",
        "Loki stored-data growth: display unit must be bytes",
    )


def validate_explore_links(dashboard: dict[str, Any]) -> None:
    expected_queries = {
        "Explore all logs": '{source=~".+"}',
        "Investigate Events in Explore": (
            '{source="kubernetes_event",event_type=~"Warning|Error"}'
        ),
        "Investigate Talos services in Explore": (
            '{source="talos",service!="kernel"} |~ "(?i)(error|fail|fatal|panic)"'
        ),
        "Investigate kernel errors in Explore": (
            '{source="talos",service="kernel"} |~ "(?i)(error|fail|fatal|panic)"'
        ),
    }
    links = list(dashboard.get("links", []))
    for panel in dashboard.get("panels", []):
        links.extend(panel.get("links", []))

    titles = [link.get("title") for link in links]
    require(
        len(titles) == len(set(titles)),
        "Explore link titles must be unique",
    )
    require(
        set(titles) == set(expected_queries),
        "dashboard must contain exactly the four required Explore links",
    )

    for link in links:
        title = link["title"]
        require(link.get("type") == "link", f"{title}: must be a Grafana link")
        parsed = urlsplit(link.get("url", ""))
        require(parsed.path == "/explore", f"{title}: path must be /explore")
        try:
            parameters = parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True)
        except ValueError as error:
            raise ValidationError(f"{title}: invalid Explore query string: {error}") from error
        require(
            set(parameters) == {"panes", "schemaVersion", "orgId"},
            f"{title}: unexpected or missing Explore URL parameters",
        )
        require(
            parameters["schemaVersion"] == ["1"],
            f"{title}: Explore schemaVersion must be 1",
        )
        require(parameters["orgId"] == ["1"], f"{title}: Grafana orgId must be 1")
        require(len(parameters["panes"]) == 1, f"{title}: must contain one panes payload")
        try:
            panes = json.loads(parameters["panes"][0])
        except json.JSONDecodeError as error:
            raise ValidationError(f"{title}: panes payload is not valid JSON: {error}") from error

        require(set(panes) == {"A"}, f"{title}: panes payload must contain pane A only")
        pane = panes["A"]
        require(
            set(pane) == {"datasource", "queries", "range"},
            f"{title}: pane A has an invalid shape",
        )
        require(
            pane["datasource"] == "${loki}",
            f"{title}: pane datasource must be the selected Loki variable",
        )
        require(
            pane["range"] == {"from": "${__from}", "to": "${__to}"},
            f"{title}: pane range must preserve the dashboard time range",
        )
        require(
            isinstance(pane["queries"], list) and len(pane["queries"]) == 1,
            f"{title}: pane must contain exactly one query",
        )
        query = pane["queries"][0]
        require(
            query
            == {
                "refId": "A",
                "datasource": {"uid": "${loki}", "type": "loki"},
                "expr": expected_queries[title],
            },
            f"{title}: pane query does not match its investigation view",
        )


def validate(path: Path) -> None:
    try:
        dashboard = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"cannot load dashboard JSON: {error}") from error
    require(isinstance(dashboard, dict), "dashboard root must be a JSON object")
    validate_operational_panels(dashboard)
    validate_explore_links(dashboard)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: grafana-dashboard.py <dashboard.json>", file=sys.stderr)
        return 2
    try:
        validate(Path(sys.argv[1]))
    except ValidationError as error:
        print(f"Centralized Logs dashboard validation failed: {error}", file=sys.stderr)
        return 1
    print("Centralized Logs dashboard operational panels and Explore links passed validation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
