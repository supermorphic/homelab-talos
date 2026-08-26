#!/usr/bin/env python3
"""Validate binding invariants in the approved Alloy River configurations."""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Block:
    kind: str
    label: str | None
    body: str


def refuse(message: str) -> None:
    raise SystemExit(f"Refusing: {message}")


def skip_quoted(text: str, start: int, quote: str) -> int:
    index = start + 1
    while index < len(text):
        if quote == '"' and text[index] == "\\":
            index += 2
            continue
        if text[index] == quote:
            return index + 1
        index += 1
    refuse("Alloy River contains an unterminated string.")


def strip_comments(text: str) -> str:
    """Replace Alloy comments with whitespace without changing token positions."""
    output = list(text)
    index = 0
    while index < len(text):
        if text[index] in {'"', "`"}:
            index = skip_quoted(text, index, text[index])
            continue
        if text.startswith("//", index) or text[index] == "#":
            newline = text.find("\n", index + 1)
            end = len(text) if newline < 0 else newline
            for position in range(index, end):
                output[position] = " "
            index = end
            continue
        if text.startswith("/*", index):
            close = text.find("*/", index + 2)
            if close < 0:
                refuse("Alloy River contains an unterminated block comment.")
            end = close + 2
            for position in range(index, end):
                if text[position] != "\n":
                    output[position] = " "
            index = end
            continue
        index += 1
    return "".join(output)


def matching_brace(text: str, start: int) -> int:
    depth = 1
    index = start + 1
    while index < len(text):
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = len(text) if newline < 0 else newline + 1
            continue
        if text[index] in {'"', "`"}:
            index = skip_quoted(text, index, text[index])
            continue
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    refuse("Alloy River contains an unmatched block brace.")


def direct_blocks(text: str) -> list[Block]:
    blocks: list[Block] = []
    index = 0
    identifier = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*")
    while index < len(text):
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = len(text) if newline < 0 else newline + 1
            continue
        if text[index] in {'"', "`"}:
            index = skip_quoted(text, index, text[index])
            continue
        match = identifier.match(text, index)
        if match is None:
            index += 1
            continue

        kind = match.group(0)
        cursor = match.end()
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1

        label: str | None = None
        if cursor < len(text) and text[cursor] == '"':
            label_end = skip_quoted(text, cursor, '"')
            label = json.loads(text[cursor:label_end])
            cursor = label_end
            while cursor < len(text) and text[cursor].isspace():
                cursor += 1

        if cursor >= len(text) or text[cursor] != "{":
            index = match.end()
            continue

        close = matching_brace(text, cursor)
        blocks.append(Block(kind=kind, label=label, body=text[cursor + 1 : close]))
        index = close + 1
    return blocks


def one_component(components: list[Block], kind: str, label: str) -> Block:
    matches = [block for block in components if block.kind == kind and block.label == label]
    if len(matches) != 1:
        refuse(f'Alloy River must define exactly one {kind} "{label}" component.')
    return matches[0]


def direct_assignment_view(body: str) -> str:
    """Mask nested blocks while retaining current-depth assignments and newlines."""
    output = list(body)
    depth = 0
    index = 0
    while index < len(body):
        if body.startswith("//", index):
            newline = body.find("\n", index + 2)
            end = len(body) if newline < 0 else newline
            for position in range(index, end):
                output[position] = " "
            index = end
            continue
        if body[index] in {'"', "`"}:
            end = skip_quoted(body, index, body[index])
            if depth > 0:
                for position in range(index, end):
                    if body[position] != "\n":
                        output[position] = " "
            index = end
            continue
        if body[index] == "{":
            if body[index] != "\n":
                output[index] = " "
            depth += 1
        elif body[index] == "}":
            if body[index] != "\n":
                output[index] = " "
            depth -= 1
            if depth < 0:
                refuse("Alloy River contains an unmatched closing brace.")
        elif depth > 0 and body[index] != "\n":
            output[index] = " "
        index += 1
    if depth != 0:
        refuse("Alloy River contains an unmatched nested block brace.")
    return "".join(output)


def optional_assignment(body: str, name: str) -> str | None:
    matches = re.findall(
        rf"(?m)^[\t ]*{re.escape(name)}[\t ]*=[\t ]*(.*?)[\t ]*$",
        direct_assignment_view(body),
    )
    if not matches:
        return None
    if len(matches) != 1:
        refuse(f"Alloy block must assign {name} exactly once.")
    return matches[0]


def assignment(body: str, name: str) -> str:
    value = optional_assignment(body, name)
    if value is None:
        refuse(f"Alloy block must assign {name} exactly once.")
    return value


def direct_assignment_names(body: str) -> list[str]:
    return re.findall(r"(?m)^[\t ]*([A-Za-z_][A-Za-z0-9_]*)[\t ]*=", direct_assignment_view(body))


def string_list(value: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        refuse(f"Alloy label list is not a literal string list: {error}")
    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        refuse("Alloy label allowlist must contain only literal strings.")
    return parsed


def validate_protection_stages(
    process: Block,
    expected_kinds: list[str],
    expected_labels: list[str],
    source_name: str,
    protected_start: int,
) -> None:
    stages = direct_blocks(process.body)
    if any(stage.kind.startswith("stage.structured_metadata") for stage in stages):
        refuse("Alloy log processing must not create structured metadata.")
    if [stage.kind for stage in stages] != expected_kinds:
        refuse(f"Alloy {source_name} processing stages must end with the exact label allowlist.")

    protected = stages[protected_start : protected_start + 3]

    expected_expressions = [
        r"`(?i)authorization\s*[:=]\s*(?:bearer|basic)\s+([^\s,;]+)`",
        r"""`(?i)(?:password|passwd|token|api[_-]?key|secret)\s*[:=]\s*["']?([^\s"',;]+)`""",
    ]
    for stage, expression in zip(protected[:2], expected_expressions, strict=True):
        if Counter(direct_assignment_names(stage.body)) != Counter(["expression", "replace"]):
            refuse(f"Alloy {source_name} credential redaction stage assignments drifted.")
        if assignment(stage.body, "expression") != expression:
            refuse(f"Alloy {source_name} credential redaction expression drifted.")
        if assignment(stage.body, "replace") != '"[REDACTED]"':
            refuse(f"Alloy {source_name} credential redaction replacement drifted.")

    drop = protected[2]
    if Counter(direct_assignment_names(drop.body)) != Counter(
        ["expression", "drop_counter_reason"]
    ):
        refuse(f"Alloy {source_name} temporary-password stage assignments drifted.")
    if assignment(drop.body, "expression") != "`(?i)temporary password.*session`":
        refuse(f"Alloy {source_name} temporary-password filter drifted.")
    if assignment(drop.body, "drop_counter_reason") != '"temporary_password"':
        refuse(f"Alloy {source_name} temporary-password counter reason drifted.")

    label_keep = stages[-1]
    if string_list(assignment(label_keep.body, "values")) != expected_labels:
        refuse(f"Alloy {source_name} final label allowlist drifted.")
    if assignment(process.body, "forward_to") != "[loki.write.default.receiver]":
        refuse(f"Alloy {source_name} processing must route only to loki.write.default.")


def validate_node_logs(config_path: Path) -> None:
    text = strip_comments(config_path.read_text())
    components = direct_blocks(text)
    actual_components = Counter((block.kind, block.label) for block in components)
    expected_components = Counter(
        {
            ("discovery.kubernetes", "pods"): 1,
            ("discovery.relabel", "kubernetes_pods"): 1,
            ("loki.source.file", "kubernetes"): 1,
            ("loki.process", "kubernetes"): 1,
            ("local.file_match", "talos_services"): 1,
            ("discovery.relabel", "talos_services"): 1,
            ("local.file_match", "talos_kernel"): 1,
            ("loki.source.file", "talos_services"): 1,
            ("loki.source.file", "talos_kernel"): 1,
            ("loki.process", "talos"): 1,
            ("loki.write", "default"): 1,
        }
    )
    if actual_components != expected_components:
        refuse("Alloy River component set must contain only the approved node-log flow.")

    discovery = one_component(components, "discovery.kubernetes", "pods")
    if assignment(discovery.body, "role") != '"pod"':
        refuse("Alloy Kubernetes discovery must use the Pod role.")
    selectors = direct_blocks(discovery.body)
    if len(selectors) != 1 or selectors[0].kind != "selectors":
        refuse("Alloy Kubernetes discovery must use exactly one node-local selector.")
    if (
        assignment(selectors[0].body, "role") != '"pod"'
        or assignment(selectors[0].body, "field") != '"spec.nodeName=" + env("NODE_NAME")'
    ):
        refuse("Alloy Kubernetes discovery must select Pods on NODE_NAME only.")

    pod_relabel = one_component(components, "discovery.relabel", "kubernetes_pods")
    rules = [block for block in direct_blocks(pod_relabel.body) if block.kind == "rule"]
    annotation = [
        rule
        for rule in rules
        if optional_assignment(rule.body, "source_labels")
        == '["__meta_kubernetes_pod_annotation_observability_supermorphic_com_logs"]'
    ]
    if (
        len(annotation) != 1
        or assignment(annotation[0].body, "action") != '"drop"'
        or assignment(annotation[0].body, "regex") != "`^disabled$`"
    ):
        refuse("Alloy Kubernetes Pod opt-out rule must drop only disabled targets.")

    kubernetes_source = one_component(components, "loki.source.file", "kubernetes")
    if assignment(kubernetes_source.body, "targets") != "discovery.relabel.kubernetes_pods.output":
        refuse("Alloy Kubernetes source must use the approved Pod file targets.")
    if assignment(kubernetes_source.body, "forward_to") != "[loki.process.kubernetes.receiver]":
        refuse("Alloy Kubernetes source must route only through loki.process.kubernetes.")

    for label, expected_targets in {
        "talos_services": "discovery.relabel.talos_services.output",
        "talos_kernel": "local.file_match.talos_kernel.targets",
    }.items():
        source = one_component(components, "loki.source.file", label)
        if assignment(source.body, "targets") != expected_targets:
            refuse("every Alloy Talos source must use only its approved file targets.")
        if assignment(source.body, "forward_to") != "[loki.process.talos.receiver]":
            refuse("every Alloy Talos source must route only through loki.process.talos.")

    kubernetes_process = one_component(components, "loki.process", "kubernetes")
    kubernetes_stages = direct_blocks(kubernetes_process.body)
    if kubernetes_stages[0].body.strip():
        refuse("Alloy Kubernetes CRI parsing stage must remain empty and first.")
    if not re.fullmatch(
        r'\s*values\s*=\s*\{\s*stream\s*=\s*"stream",?\s*\}\s*',
        kubernetes_stages[1].body,
        flags=re.DOTALL,
    ):
        refuse("Alloy Kubernetes CRI stream mapping must create only the stream label.")
    validate_protection_stages(
        kubernetes_process,
        [
            "stage.cri",
            "stage.labels",
            "stage.replace",
            "stage.replace",
            "stage.drop",
            "stage.label_keep",
        ],
        ["cluster", "source", "namespace", "app", "container", "node", "stream"],
        "Kubernetes",
        2,
    )

    talos_process = one_component(components, "loki.process", "talos")
    validate_protection_stages(
        talos_process,
        ["stage.replace", "stage.replace", "stage.drop", "stage.label_keep"],
        ["cluster", "source", "node", "service"],
        "Talos",
        0,
    )

    validate_writer(components)


def validate_writer(components: list[Block]) -> None:
    writer = one_component(components, "loki.write", "default")
    if direct_assignment_names(writer.body):
        refuse("Alloy Loki delivery must not define direct assignments.")
    writer_blocks = direct_blocks(writer.body)
    if any(block.kind == "wal" for block in writer_blocks):
        refuse("Alloy Loki delivery must not enable a WAL.")
    if len(writer_blocks) != 1 or writer_blocks[0].kind != "endpoint":
        refuse("Alloy Loki delivery must define only the internal endpoint.")
    if assignment(writer_blocks[0].body, "url") != (
        '"http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"'
    ):
        refuse("Alloy Loki delivery endpoint drifted.")


def validate_events(config_path: Path) -> None:
    text = strip_comments(config_path.read_text())
    components = direct_blocks(text)
    actual_components = Counter((block.kind, block.label) for block in components)
    expected_components = Counter(
        {
            ("loki.source.kubernetes_events", "events"): 1,
            ("loki.process", "events"): 1,
            ("loki.write", "default"): 1,
        }
    )
    if actual_components != expected_components:
        refuse("Alloy River component set must contain only the approved Events flow.")

    source = one_component(components, "loki.source.kubernetes_events", "events")
    if direct_blocks(source.body):
        refuse("Alloy Events source must not override its in-cluster client or clustering.")
    if direct_assignment_names(source.body) != ["namespaces", "log_format", "forward_to"]:
        refuse(
            "Alloy Events source must define only all-namespace JSON collection and its protected route."
        )
    if assignment(source.body, "namespaces") != "[]":
        refuse("Alloy Events source must watch all namespaces.")
    if assignment(source.body, "log_format") != '"json"':
        refuse("Alloy Events source must emit JSON log lines.")
    if assignment(source.body, "forward_to") != "[loki.process.events.receiver]":
        refuse("Alloy Events source must route only through loki.process.events.")

    process = one_component(components, "loki.process", "events")
    stages = direct_blocks(process.body)
    validate_protection_stages(
        process,
        [
            "stage.json",
            "stage.labels",
            "stage.match",
            "stage.static_labels",
            "stage.replace",
            "stage.replace",
            "stage.drop",
            "stage.label_keep",
        ],
        ["cluster", "source", "namespace", "event_type"],
        "Events",
        4,
    )
    if not re.fullmatch(
        r'\s*expressions\s*=\s*\{\s*event_type\s*=\s*"type",?\s*\}\s*',
        stages[0].body,
        flags=re.DOTALL,
    ):
        refuse("Alloy Events JSON parsing must extract only Event type.")
    if not re.fullmatch(
        r'\s*values\s*=\s*\{\s*event_type\s*=\s*"event_type",?\s*\}\s*',
        stages[1].body,
        flags=re.DOTALL,
    ):
        refuse("Alloy Events dynamic labels must contain only event_type.")
    if not re.fullmatch(
        r'\s*selector\s*=\s*`\{event_type!~"\^\(Normal\|Warning\)\$"\}`\s*'
        r'action\s*=\s*"drop"\s*'
        r'drop_counter_reason\s*=\s*"unexpected_event_type"\s*',
        stages[2].body,
        flags=re.DOTALL,
    ):
        refuse(
            "Alloy Events must drop every event_type other than Normal or Warning before delivery."
        )
    if not re.fullmatch(
        r'\s*values\s*=\s*\{\s*cluster\s*=\s*"nuc-cluster",\s*source\s*=\s*"kubernetes_event",?\s*\}\s*',
        stages[3].body,
        flags=re.DOTALL,
    ):
        refuse("Alloy Events static labels must contain only cluster and source.")

    validate_writer(components)


def main() -> None:
    if len(sys.argv) == 2:
        validate_node_logs(Path(sys.argv[1]))
        print("Alloy node-log River structure passed validation.")
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--events":
        validate_events(Path(sys.argv[2]))
        print("Alloy Events River structure passed validation.")
        return
    raise SystemExit(f"usage: {Path(sys.argv[0]).name} [--events] CONFIG_ALLOY")


if __name__ == "__main__":
    main()
