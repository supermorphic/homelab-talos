"""Holistic, single-parse validator for the repository test catalog."""

from __future__ import annotations

import re
import shlex
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, NoReturn

import yaml

REPO_ROOT = Path(__file__).parents[2]
EXPECTED_CAMPAIGNS = [
    "conformance-certified",
    "conformance-quick",
    "e2e",
    "full",
    "integration",
    "probes",
    "resilience",
    "scoped-verification",
    "smoke",
    "standard",
    "validation",
    "verification",
    "weekly",
]
EXPECTED_SMOKE = [
    "chainsaw.smoke.cluster.default",
    "chainsaw.smoke.media.qbittorrent",
    "chainsaw.smoke.media.qbit-manage",
    "chainsaw.smoke.platform.all",
]
EXPECTED_RESILIENCE = [
    "test.flux-restart",
    "test.portainer-persistence",
    "chainsaw.resilience.qbittorrent-vpn-disconnect",
    "chainsaw.resilience.qbittorrent-pod-recreation",
    "chainsaw.resilience.plex-cross-node-reschedule",
    "chainsaw.resilience.test-reports-persistence",
    "chainsaw.resilience.tailscale-subnet-router-replica-recovery",
    "test.resilience.plex-node-reboot",
]
METADATA_FIELDS = (
    "source",
    "framework",
    "suite",
    "tier",
    "target",
    "scope",
    "intent",
    "execution_owner",
)
SAFE_RUNNER = re.compile(
    r"^(?:[A-Z][A-Z0-9_]*=[a-zA-Z0-9._:/<>-]+\s+)*"
    r"mise\s+exec\s+--\s+just\s+[a-zA-Z0-9_.-]+"
    r"(?:\s+[a-zA-Z0-9._:/<>-]+)*$"
)
VERIFICATION_ACCESS_TIERS = {"observer", "diagnostic", "operator"}


def scoped_read_rules(catalog: dict[str, Any]) -> dict[str, set[str]]:
    raw = (
        catalog.get("campaigns", {})
        .get("scoped-verification", {})
        .get("access", {})
        .get("required_read_rules")
    )
    if (
        not isinstance(raw, dict)
        or not raw
        or any(
            not isinstance(api_group, str)
            or not api_group
            or not isinstance(resources, list)
            or not resources
            or any(
                not isinstance(resource, str) or not resource or resource == "*"
                for resource in resources
            )
            for api_group, resources in (raw or {}).items()
        )
    ):
        fail("Campaign scoped-verification must declare bounded required_read_rules.\n")
    return {api_group: set(resources) for api_group, resources in raw.items()}


def _shell_tokens(source: str) -> list[list[str]]:
    logical = source.replace("\\\n", " ")
    statements: list[list[str]] = []
    lexer = shlex.shlex(logical, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace_split = True
    lexer.whitespace = " \t\r"
    lexer.commenters = "#"
    current: list[str] = []
    try:
        for token in lexer:
            if token and all(character in ";&|()<>\n" for character in token):
                if current:
                    statements.append(current)
                    current = []
            else:
                current.append(token)
    except ValueError:
        statements = []
        for line in logical.splitlines():
            try:
                tokens = shlex.split(line, comments=True, posix=True)
            except ValueError:
                tokens = line.split()
            if tokens:
                statements.append(tokens)
        current = []
    if current:
        statements.append(current)
    return statements


def _command_aliases(
    source: str,
) -> tuple[dict[str, list[str]], dict[str, list[str]], set[str]]:
    aliases: dict[str, list[str]] = {"kubectl": []}
    for match in re.finditer(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)=\(\s*kubectl\b([^)]*)\)", source):
        aliases[match.group(1)] = shlex.split(match.group(2), comments=True, posix=True)
    for match in re.finditer(
        r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)=(?:['\"])?kubectl(?:['\"])?\s*$", source
    ):
        aliases[match.group(1)] = []
    for match in re.finditer(
        r"(?m)^\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)="
        r"(?:['\"])?\$\{[A-Za-z_][A-Za-z0-9_]*:-kubectl\}(?:['\"])?\s*$",
        source,
    ):
        aliases[match.group(1)] = []

    wrappers: dict[str, list[str]] = {}
    unresolved_wrappers: set[str] = set()
    for match in re.finditer(
        r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{([^\n}]*)",
        source,
    ):
        name = match.group(1)
        body_start = match.start(2)
        same_line_close = source.find("}", body_start, source.find("\n", body_start) + 1)
        if same_line_close >= 0:
            body = source[body_start:same_line_close]
        else:
            close = re.search(r"(?m)^\s*}\s*$", source[body_start:])
            body = source[body_start : body_start + close.start()] if close else match.group(2)
        for tokens in _shell_tokens(body):
            invocation = _kubectl_invocation(tokens, aliases, {})
            if invocation is not None:
                consumed_args = sum(
                    int(shift.group(1) or "1")
                    for shift in re.finditer(r"(?m)^\s*shift(?:\s+([0-9]+))?\s*$", body)
                )
                wrappers[name] = [
                    f"__consume_args__={consumed_args}",
                    *(token for token in invocation if token not in {"$@", "${@}"}),
                ]
                break
        if name not in wrappers and re.search(r"(?:^|[;&|])\s*[\"']?\$(?!@)[{A-Za-z_]", body):
            unresolved_wrappers.add(name)
    return aliases, wrappers, unresolved_wrappers


def _alias_name(token: str) -> str:
    token = token.strip("\"'")
    if re.fullmatch(r"\$\{[A-Za-z_][A-Za-z0-9_]*:-kubectl\}", token):
        return "kubectl"
    match = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)(?:\[@\])?\}?", token)
    return match.group(1) if match else token


def _kubectl_invocation(
    tokens: list[str], aliases: dict[str, list[str]], wrappers: dict[str, list[str]]
) -> list[str] | None:
    for index, token in enumerate(tokens):
        name = _alias_name(token)
        if name in aliases:
            return [*aliases[name], *tokens[index + 1 :]]
        if name in wrappers:
            prefix = wrappers[name]
            consume = int(prefix[0].partition("=")[2])
            return [*prefix[1:], *tokens[index + 1 + consume :]]
    return None


def forbidden_kubernetes_operations(source: str, *, allow_interactive: bool = False) -> list[str]:
    """Reject every scoped kubectl operation outside a conservative tier allowlist."""
    aliases, wrappers, unresolved_wrappers = _command_aliases(source)
    violations: set[str] = set()
    safe_commands = {
        "api-resources",
        "api-versions",
        "describe",
        "get",
        "logs",
        "top",
        "version",
        "wait",
    }
    global_value_options = {
        "--as",
        "--as-group",
        "--cache-dir",
        "--certificate-authority",
        "--client-certificate",
        "--client-key",
        "--cluster",
        "--context",
        "--kubeconfig",
        "--namespace",
        "--password",
        "--profile",
        "--profile-output",
        "--request-timeout",
        "--server",
        "--tls-server-name",
        "--token",
        "--user",
        "--username",
        "-n",
    }

    def subcommand(invocation: list[str]) -> tuple[str, int] | None:
        index = 0
        while index < len(invocation):
            token = invocation[index]
            if token == "--":
                index += 1
                continue
            if token in {"$@", "${@}"}:
                index += 1
                continue
            option = token.split("=", 1)[0]
            if option in global_value_options:
                index += 1 if "=" in token else 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            if re.fullmatch(r"\$\{[A-Za-z_][A-Za-z0-9_]*_args\[@\]\}", token):
                index += 1
                continue
            return token, index
        return None

    def next_non_option(tokens: list[str], start: int) -> str:
        index = start
        while index < len(tokens):
            token = tokens[index]
            if token == "--":
                index += 1
                continue
            if token.startswith("-"):
                index += 1
                continue
            return token
        return ""

    def reads_secret(tokens: list[str]) -> bool:
        return any(
            token.lower().split("/", 1)[0].split(".", 1)[0] in {"secret", "secrets"}
            for token in tokens
            if token and not token.startswith("-")
        )

    for tokens in _shell_tokens(source):
        if "helm" in tokens:
            helm_index = tokens.index("helm")
            if any(
                token in {"get", "history", "list", "status"} for token in tokens[helm_index + 1 :]
            ):
                violations.add("Helm release storage read")

        unresolved = next(
            (_alias_name(token) for token in tokens if _alias_name(token) in unresolved_wrappers),
            "",
        )
        if unresolved:
            violations.add(f"unresolved dynamic wrapper ({unresolved})")

        if len(tokens) == 1 and _alias_name(tokens[0]) in wrappers:
            continue
        invocation = _kubectl_invocation(tokens, aliases, wrappers)
        if invocation is None:
            continue
        resolved = subcommand(invocation)
        if resolved is None:
            if invocation in aliases.values() or any(
                token in {"$@", "${@}"} for token in invocation
            ):
                continue
            violations.add("kubectl invocation without a subcommand")
            continue
        command, command_index = resolved
        remaining = invocation[command_index + 1 :]
        if command in {"get", "describe"} and reads_secret(remaining):
            violations.add("Secret API read")
            continue
        if command in safe_commands:
            continue
        if command == "auth" and next_non_option(remaining, 0) == "can-i":
            continue
        if command == "config" and next_non_option(remaining, 0) in {
            "current-context",
            "get-contexts",
            "view",
        }:
            continue
        if command == "rollout" and next_non_option(remaining, 0) == "status":
            continue
        if allow_interactive and command in {"exec", "port-forward"}:
            continue
        violations.add(f"kubectl subcommand ({command})")
    return sorted(violations)


def _just_recipes(root: Path) -> dict[str, str]:
    path = root / "kubernetes/mod.just"
    if not path.is_file():
        return {}
    recipes: dict[str, list[str]] = {}
    current = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        header = re.match(r"^([a-zA-Z0-9_-]+)(?:\s+[^:]*)?:", line)
        if header:
            current = header.group(1)
            recipes[current] = [line]
        elif current and (line.startswith("    ") or not line.strip()):
            recipes[current].append(line)
        elif line and not line.startswith((" ", "#")):
            current = ""
    return {name: "\n".join(lines) for name, lines in recipes.items()}


def reachable_verifier_source(root: Path, implementation: str) -> str:
    """Resolve verifier files, sourced helpers, and literal nested kube Just recipes."""
    root = root.resolve()

    def checked_relative_path(relative: str, label: str) -> Path:
        candidate = Path(relative)
        if candidate.is_absolute():
            fail(f"Scoped verifier {label} resolves outside repository root: {relative}.\n")
        resolved = (root / candidate).resolve()
        if not resolved.is_relative_to(root):
            fail(f"Scoped verifier {label} resolves outside repository root: {relative}.\n")
        if not resolved.is_file():
            fail(f"Scoped verifier {label} does not resolve to a file: {relative}.\n")
        return resolved

    recipes = _just_recipes(root)
    pending_files = [implementation]
    pending_recipes: list[str] = []
    seen_files: set[str] = set()
    seen_recipes: set[str] = set()
    chunks: list[str] = []
    while pending_files or pending_recipes:
        if pending_files:
            relative = pending_files.pop()
            if relative in seen_files:
                continue
            seen_files.add(relative)
            path = checked_relative_path(relative, "source")
            source = path.read_text(encoding="utf-8")
        else:
            recipe = pending_recipes.pop()
            if recipe in seen_recipes:
                continue
            seen_recipes.add(recipe)
            source = recipes.get(recipe, "")
            if not source:
                fail(f"Scoped verifier references unknown Just recipe: {recipe}.\n")
            header = source.splitlines()[0] if source else ""
            for dependency in header.partition(":")[2].split():
                if any(character in dependency for character in "${}{ }"):
                    fail(f"Scoped verifier has dynamic Just recipe target: {dependency}.\n")
                if dependency in recipes:
                    pending_recipes.append(dependency)
        chunks.append(source)
        for line in source.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", "echo ", "printf ")):
                continue
            source_call = re.match(r"^(?:source|\.)\s+(.+)$", stripped)
            if source_call:
                try:
                    source_tokens = shlex.split(source_call.group(1), comments=True, posix=True)
                except ValueError:
                    source_tokens = []
                if not source_tokens or any(character in source_tokens[0] for character in "$`"):
                    fail(f"Scoped verifier has dynamic source target: {source_call.group(1)}.\n")
                source_path = checked_relative_path(source_tokens[0], "source")
                pending_files.append(str(source_path.relative_to(root)))

            try:
                command_tokens = shlex.split(stripped, comments=True, posix=True)
            except ValueError:
                command_tokens = []
            for command_token in command_tokens:
                if not re.fullmatch(r"[a-zA-Z0-9_./-]+\.sh", command_token):
                    continue
                command_path = checked_relative_path(command_token, "helper")
                pending_files.append(str(command_path.relative_to(root)))

            just_call = re.search(r"(?:^|\s)just\s+kube\s+(\S+)", stripped)
            if just_call:
                recipe_target = just_call.group(1).strip("\"'")
                if not re.fullmatch(r"[a-zA-Z0-9_-]+", recipe_target):
                    fail(f"Scoped verifier has dynamic Just recipe target: {recipe_target}.\n")
                pending_recipes.append(recipe_target)
    return "\n".join(chunks)


def verification_access_violations(catalog: dict[str, Any]) -> list[str]:
    """Collect missing tiers and privileged operations in scoped verifiers."""
    violations: list[str] = []
    for entry in catalog["suites"]:
        metadata = entry.get("metadata", {})
        suite_id = shell_text(metadata.get("id"))
        if not suite_id.startswith("verification."):
            continue
        access_tier = shell_text(entry.get("access", {}).get("tier"))
        if access_tier not in VERIFICATION_ACCESS_TIERS:
            violations.append(f"{suite_id}: access tier is absent or invalid")

        implementation = shell_text(entry.get("runner", {}).get("implementation"))
        path = REPO_ROOT / implementation
        if not path.is_file():
            continue
        source = reachable_verifier_source(REPO_ROOT, implementation)
        forbidden = forbidden_kubernetes_operations(
            source, allow_interactive=access_tier == "diagnostic"
        )
        if access_tier in {"observer", "diagnostic"} and forbidden:
            violations.append(f"{suite_id}: {' and '.join(forbidden)}")
        elif not access_tier and forbidden:
            violations.append(f"{suite_id}: {' and '.join(forbidden)} but tier is absent")
    return violations


@dataclass(frozen=True)
class ValidationFailure(Exception):
    message: str
    status: int = 1


def fail(message: str, status: int = 1) -> NoReturn:
    raise ValidationFailure(message, status)


def shell_text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


def duplicates(values: list[str]) -> list[str]:
    counts = Counter(values)
    return sorted(value for value, count in counts.items() if count > 1)


def exact_diff(description: str, expected: list[str], actual: list[str]) -> str:
    stamp = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S.%f %z")
    with tempfile.TemporaryDirectory(prefix="homelab-catalog-diff-") as temporary:
        root = Path(temporary)
        expected_path = root / "expected"
        actual_path = root / "actual"
        expected_path.write_text("\n".join(expected) + "\n", encoding="utf-8")
        actual_path.write_text("\n".join(actual) + "\n", encoding="utf-8")
        completed = subprocess.run(
            ["diff", "-u", str(expected_path), str(actual_path)],
            capture_output=True,
            check=False,
            text=True,
        )
    lines = completed.stdout.splitlines(keepends=True)
    if len(lines) >= 2:
        lines[0] = f"--- /dev/fd/63\t{stamp}\n"
        lines[1] = f"+++ /dev/fd/62\t{stamp}\n"
    return f"{description} differs from the explicit catalog contract.\n{''.join(lines)}"


def load_yaml(path: Path) -> Any:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


class CatalogValidator:
    def __init__(self, catalog_path: Path, catalog: dict[str, Any]) -> None:
        self.catalog_path = catalog_path
        self.catalog = catalog
        self.suites: list[dict[str, Any]] = catalog["suites"]
        self.campaigns: dict[str, dict[str, Any]] = catalog["campaigns"]
        self.suites_by_id: dict[str, list[dict[str, Any]]] = {}
        for entry in self.suites:
            suite_id = shell_text(entry.get("metadata", {}).get("id"), "null")
            self.suites_by_id.setdefault(suite_id, []).append(entry)
        self.chainsaw_document_paths = sorted(
            REPO_ROOT.glob("tests/chainsaw/**/chainsaw-test.yaml")
        )
        self.chainsaw_documents: dict[Path, Any] = {}

    def chainsaw_document(self, path: Path) -> Any:
        if path not in self.chainsaw_documents:
            self.chainsaw_documents[path] = load_yaml(path)
        return self.chainsaw_documents[path]

    def entry_by_id(self, suite_id: str) -> dict[str, Any]:
        matches = self.suites_by_id.get(suite_id, [])
        if len(matches) != 1:
            fail(f"Unknown or ambiguous catalog suite ID: {suite_id}.\n", status=2)
        return matches[0]

    def campaign_entry(self, campaign: str) -> dict[str, Any]:
        entry = self.campaigns.get(campaign)
        if entry is None:
            fail(f"Unknown test campaign: {campaign}.\n", status=2)
        return entry

    def campaign_ids(self, campaign: str, ancestry: tuple[str, ...] = ()) -> list[str]:
        if campaign in ancestry:
            chain = " -> ".join((*ancestry, campaign))
            fail(f"Test campaign include cycle: {chain}.\n", status=2)
        entry = self.campaign_entry(campaign)
        resolved: list[str] = []
        for include in entry.get("includes") or []:
            if include:
                resolved.extend(self.campaign_ids(include, (*ancestry, campaign)))
        for member in entry.get("members") or []:
            if member:
                resolved.append(member)
        return resolved

    def validate(self) -> None:
        self.validate_duplicates()
        for index, entry in enumerate(self.suites):
            self.validate_entry(index, entry)
        self.validate_verification_access()
        self.validate_campaigns()
        self.validate_campaign_contracts()
        self.validate_ci_execution()
        self.validate_chainsaw_completeness()

    def validate_verification_access(self) -> None:
        violations = verification_access_violations(self.catalog)
        if violations:
            fail("Verifier access contract violations:\n" + "\n".join(violations) + "\n")
        self.validate_diagnostic_contexts()
        self.validate_agent_access_matrix()
        self.validate_portainer_rbac_oracle()
        self.validate_scoped_rbac_source()

    def validate_diagnostic_contexts(self) -> None:
        for entry in self.suites:
            suite_id = shell_text(entry.get("metadata", {}).get("id"))
            if (
                not suite_id.startswith("verification.")
                or entry.get("access", {}).get("tier") != "diagnostic"
                or suite_id == "verification.agent-access"
            ):
                continue
            implementation = shell_text(entry.get("runner", {}).get("implementation"))
            content = (REPO_ROOT / implementation).read_text(encoding="utf-8")
            if not all(
                marker in content
                for marker in (
                    "config get-contexts homelab-diagnostic",
                    "--context homelab-diagnostic",
                )
            ):
                fail(
                    f"Diagnostic verifier {suite_id} must select homelab-diagnostic "
                    "conditionally.\n"
                )

    def validate_agent_access_matrix(self) -> None:
        entry = self.entry_by_id("verification.agent-access")
        implementation = shell_text(entry.get("runner", {}).get("implementation"))
        content = (REPO_ROOT / implementation).read_text(encoding="utf-8")
        required = {
            "homelab-observer",
            "homelab-diagnostic",
            "named-contexts",
            "admin-impersonation",
            "system:authenticated",
            "system:serviceaccounts",
            "system:serviceaccounts:kube-system",
            "for verb in get list watch",
            "get secrets",
            "create pods/exec",
            "create pods/portforward",
            "patch kustomizations.kustomize.toolkit.fluxcd.io",
            "bind clusterroles.rbac.authorization.k8s.io",
            "escalate clusterroles.rbac.authorization.k8s.io",
            "impersonate users",
            "talosctl version",
            "talosctl services",
        }
        required.update(
            f"{resource}.{api_group}"
            for api_group, resources in scoped_read_rules(self.catalog).items()
            for resource in resources
        )
        if not all(marker in content for marker in required):
            fail("verification.agent-access does not cover the required authorization matrix.\n")

    def validate_scoped_rbac_source(self) -> None:
        path = REPO_ROOT / "kubernetes/apps/kube-system/agent-access/app/rbac.yaml"
        documents = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
        roles = [
            document
            for document in documents
            if document.get("kind") == "ClusterRole"
            and document.get("metadata", {}).get("name") == "homelab-observer-extra"
        ]
        if len(roles) != 1:
            fail("Scoped verifier RBAC must define exactly one homelab-observer-extra role.\n")
        actual = {
            (api_group, resource, verb)
            for rule in roles[0].get("rules", [])
            for api_group in rule.get("apiGroups", [])
            for resource in rule.get("resources", [])
            for verb in rule.get("verbs", [])
        }
        expected = {("", "pods/log", "get")}
        expected.update(
            (api_group, resource, verb)
            for api_group, resources in scoped_read_rules(self.catalog).items()
            for resource in resources
            for verb in ("get", "list", "watch")
        )
        if actual != expected or any("*" in item for item in actual):
            fail("Scoped verifier campaign requirements and observer RBAC grants differ.\n")

    def validate_portainer_rbac_oracle(self) -> None:
        entry = self.entry_by_id("verification.portainer")
        implementation = shell_text(entry.get("runner", {}).get("implementation"))
        content = reachable_verifier_source(REPO_ROOT, implementation)
        required = {
            "get clusterrole portainer-readonly",
            "get clusterrolebinding portainer-readonly",
            "get clusterrolebindings --output json",
            "get rolebindings --all-namespaces --output json",
            "system:serviceaccount:portainer:portainer-readonly",
            "system:authenticated",
            "system:serviceaccounts:portainer",
            "Live portainer-readonly ClusterRole rules differ",
            "Unexpected direct ClusterRoleBinding grants Portainer access",
            "Unexpected direct RoleBinding grants Portainer access",
            "Unsafe system:authenticated ClusterRole rules",
        }
        if "--as" in content or not all(marker in content for marker in required):
            fail("verification.portainer must prove exact live RBAC without impersonation.\n")

    def validate_duplicates(self) -> None:
        duplicate_ids = duplicates(
            [shell_text(entry.get("metadata", {}).get("id"), "null") for entry in self.suites]
        )
        if duplicate_ids:
            fail(f"Duplicate test catalog IDs: {'\n'.join(duplicate_ids)}\n")

        dispatches = []
        for entry in self.suites:
            if "dispatch" not in entry:
                continue
            metadata = entry.get("metadata", {})
            dispatches.append(
                "|".join(
                    (
                        shell_text(metadata.get("tier"), "null"),
                        shell_text(metadata.get("target"), "null"),
                        shell_text(metadata.get("scenario"), "<none>"),
                    )
                )
            )
        duplicate_dispatches = duplicates(dispatches)
        if duplicate_dispatches:
            fail(f"Duplicate test dispatch tuples: {'\n'.join(duplicate_dispatches)}\n")

    def validate_entry(self, index: int, entry: dict[str, Any]) -> None:
        metadata = entry.get("metadata", {})
        suite_id = shell_text(metadata.get("id"), "null")
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", suite_id):
            fail(f"Catalog entry {index} has invalid id '{suite_id}'.\n")

        for field in METADATA_FIELDS:
            if not shell_text(metadata.get(field)):
                fail(f"Catalog entry {suite_id} is missing non-empty {field}.\n")

        source = shell_text(metadata.get("source"))
        framework = shell_text(metadata.get("framework"))
        tier = shell_text(metadata.get("tier"))
        scope = shell_text(metadata.get("scope"))
        intent = shell_text(metadata.get("intent"))
        target = shell_text(metadata.get("target"))
        owner = shell_text(metadata.get("execution_owner"))
        strategy = shell_text(entry.get("native_results", {}).get("strategy"))
        confirmation = entry.get("confirmation", {})
        confirmation_type = shell_text(confirmation.get("type"))
        mutates = shell_text(metadata.get("mutates_cluster"), "null")
        runner = entry.get("runner", {})
        implementation = shell_text(runner.get("implementation"))
        command = shell_text(runner.get("command"))

        allowed_values = (
            (
                source,
                "source",
                {
                    "validation",
                    "verification",
                    "test",
                    "chainsaw",
                    "diagnostics",
                    "probe",
                    "sonobuoy",
                },
            ),
            (
                framework,
                "framework",
                {
                    "just",
                    "bash",
                    "python",
                    "chainsaw",
                    "sonobuoy",
                    "conftest",
                    "kubeconform",
                    "mixed",
                },
            ),
            (
                tier,
                "tier",
                {
                    "offline",
                    "verification",
                    "smoke",
                    "integration",
                    "e2e",
                    "resilience",
                    "diagnostics",
                    "measurement",
                    "conformance",
                },
            ),
            (
                scope,
                "scope",
                {"repository", "cluster", "system", "network", "storage", "application"},
            ),
            (
                intent,
                "intent",
                {
                    "regression",
                    "acceptance",
                    "feature",
                    "resilience",
                    "diagnostic",
                    "measurement",
                    "conformance",
                },
            ),
        )
        for value, field, allowed in allowed_values:
            if value not in allowed:
                fail(f"Catalog entry {suite_id} has invalid {field} '{value}'.\n")
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", target):
            fail(f"Catalog entry {suite_id} has invalid target '{target}'.\n")
        if owner not in {"shared", "human"}:
            fail(f"Catalog entry {suite_id} has invalid execution_owner '{owner}'.\n")
        if strategy not in {
            "aggregate",
            "wrapper-junit",
            "native-junit",
            "chainsaw-junit-step",
            "sonobuoy-junit",
        }:
            fail(f"Catalog entry {suite_id} has invalid native result strategy '{strategy}'.\n")
        if mutates not in {"true", "false"}:
            fail(f"Catalog entry {suite_id} must set mutates_cluster to a boolean.\n")
        if confirmation_type not in {"none", "command", "exact"}:
            fail(
                f"Catalog entry {suite_id} has invalid confirmation type '{confirmation_type}'.\n"
            )
        if mutates == "true" and confirmation_type == "none":
            fail(
                f"Mutating catalog entry {suite_id} must declare command or exact confirmation.\n"
            )
        if confirmation_type == "exact":
            variable = shell_text(confirmation.get("variable"))
            expected = shell_text(confirmation.get("expected"))
            if not re.fullmatch(r"[A-Z][A-Z0-9_]+", variable) or not expected:
                fail(
                    f"Exact-confirmation entry {suite_id} needs a variable name and "
                    "expected shape.\n"
                )
            if f"{variable}={expected}" not in command:
                fail(
                    f"Exact-confirmation entry {suite_id} command does not expose its "
                    "declared guard.\n"
                )
        elif confirmation.get("variable") is not None or confirmation.get("expected") is not None:
            fail(
                "Error: no matches found\n"
                f"Non-exact entry {suite_id} must not declare confirmation variable/value "
                "metadata.\n"
            )
        if "mise exec -- just " not in command:
            fail(f"Catalog entry {suite_id} must expose a pinned mise + just command.\n")
        if not SAFE_RUNNER.fullmatch(command):
            fail(
                f"Catalog entry {suite_id} runner command is not a safe literal mise + just "
                "invocation.\n"
            )
        if not (REPO_ROOT / implementation).exists():
            fail(
                f"Catalog entry {suite_id} points to missing implementation '{implementation}'.\n"
            )

        scenario_value = metadata.get("scenario")
        if scenario_value is not None and not isinstance(scenario_value, str):
            fail(f"Catalog entry {suite_id} scenario must be a string or null.\n")
        scenario = shell_text(scenario_value)
        if scenario and not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", scenario):
            fail(f"Catalog entry {suite_id} has invalid scenario '{scenario}'.\n")
        if "dispatch" in entry:
            self.validate_dispatch(suite_id, framework, entry["dispatch"])

    def validate_dispatch(self, suite_id: str, framework: str, dispatch: dict[str, Any]) -> None:
        mode = shell_text(dispatch.get("mode"))
        path_text = shell_text(dispatch.get("path"))
        if mode not in {"chainsaw", "diagnostics", "direct"}:
            fail(f"Catalog entry {suite_id} has invalid dispatch mode '{mode}'.\n")
        path = Path(path_text)
        if (
            not path_text
            or path.is_absolute()
            or ".." in path_text
            or not (REPO_ROOT / path).exists()
        ):
            fail(f"Catalog entry {suite_id} has unsafe or missing dispatch path '{path_text}'.\n")
        if mode == "chainsaw":
            selector = shell_text(dispatch.get("selector"))
            if not path_text.startswith("tests/chainsaw/") or not re.fullmatch(
                r"homelab-talos/suite=[a-z0-9-]+", selector
            ):
                fail(f"Chainsaw entry {suite_id} has an invalid path or selector.\n")
            selector_value = selector.partition("=")[2]
            matching = 0
            dispatch_root = REPO_ROOT / path
            for document_path in self.chainsaw_document_paths:
                if not document_path.is_relative_to(dispatch_root):
                    continue
                document = self.chainsaw_document(document_path)
                labels = (document or {}).get("metadata", {}).get("labels", {})
                if labels.get("homelab-talos/suite") == selector_value:
                    matching += 1
            if matching == 0:
                fail(f"Chainsaw entry {suite_id} selects no test documents.\n")
        elif mode == "direct":
            runtime = shell_text(dispatch.get("runtime"))
            if runtime not in {"bash", "uv-python"}:
                fail(f"Direct entry {suite_id} has unsupported runtime '{runtime}'.\n")
            resolved_path = REPO_ROOT / path
            if runtime == "bash" and (
                framework != "bash" or not resolved_path.stat().st_mode & 0o111
            ):
                fail(
                    f"Direct Bash entry {suite_id} must name an executable Bash implementation.\n"
                )
            if runtime == "uv-python" and (framework != "python" or path.suffix != ".py"):
                fail(f"Direct Python entry {suite_id} must name a Python implementation.\n")
            if not path_text.startswith(("scripts/test/scenarios/", "tests/probes/")):
                fail(f"Direct entry {suite_id} must use an allowlisted scenario/probe path.\n")
            args = dispatch.get("args")
            if (
                not isinstance(args, list)
                or any(not isinstance(argument, str) for argument in args)
                or dispatch.get("selector") is not None
            ):
                fail(
                    "Error: no matches found\n"
                    f"Direct entry {suite_id} must use a string argument vector and no "
                    "selector.\n"
                )

    def validate_campaigns(self) -> None:
        actual_names = sorted(self.campaigns)
        if actual_names != EXPECTED_CAMPAIGNS:
            fail(
                "Test catalog campaign names differ from the supported public interface.\n"
                + exact_diff("", EXPECTED_CAMPAIGNS, actual_names).removeprefix(
                    " differs from the explicit catalog contract.\n"
                )
            )

        for campaign in self.campaigns:
            entry = self.campaigns[campaign]
            members = entry.get("members") if entry.get("members") is not None else []
            includes = entry.get("includes") if entry.get("includes") is not None else []
            coverage = entry.get("coverage") if entry.get("coverage") is not None else []
            valid = (
                isinstance(entry.get("description"), str)
                and isinstance(entry.get("mutates_cluster"), bool)
                and isinstance(entry.get("disruptive"), bool)
                and isinstance(members, list)
                and isinstance(includes, list)
                and len(members) + len(includes) > 0
                and all(isinstance(member, str) for member in members)
                and all(isinstance(include, str) for include in includes)
                and isinstance(coverage, list)
                and all(isinstance(item, str) for item in coverage)
            )
            if not valid:
                fail(
                    "Error: no matches found\n"
                    f"Campaign {campaign} has invalid metadata or member/include arrays.\n"
                )
            for member in (*members, *coverage):
                if len(self.suites_by_id.get(member, [])) != 1:
                    fail(
                        f"Unknown or ambiguous catalog suite ID: {member}.\n"
                        f"Campaign {campaign} references an unknown suite: {member}\n"
                    )
            for include in includes:
                if include not in self.campaigns:
                    fail(
                        f"Unknown test campaign: {include}.\n"
                        f"Campaign {campaign} includes an unknown campaign: {include}\n"
                    )
            resolved = self.campaign_ids(campaign)
            duplicate_members = duplicates(resolved)
            if duplicate_members:
                fail(
                    f"Campaign {campaign} resolves duplicate suite IDs: "
                    f"{'\n'.join(duplicate_members)}\n"
                )
            derived_mutates = any(
                shell_text(self.entry_by_id(member)["metadata"].get("mutates_cluster")) == "true"
                for member in resolved
            )
            derived_disruptive = any(
                self.entry_by_id(member)["metadata"].get("tier") == "resilience"
                for member in resolved
            )
            if entry["mutates_cluster"] != derived_mutates:
                fail(f"Campaign {campaign} mutates_cluster does not match its resolved members.\n")
            if entry["disruptive"] != derived_disruptive:
                fail(f"Campaign {campaign} disruptive does not match its resolved members.\n")

    def assert_campaign_covers_tier(
        self, campaign: str, tier: str, field: str = "members"
    ) -> None:
        expected = sorted(
            entry["metadata"]["id"]
            for entry in self.suites
            if entry["metadata"]["tier"] == tier
            and not (
                campaign == "smoke"
                and entry["metadata"]["id"] == "chainsaw.smoke.cluster.diagnostics-self-test"
            )
        )
        actual = sorted(self.campaigns[campaign][field])
        if actual != expected:
            fail(exact_diff(f"Campaign {campaign} {field}", expected, actual))

    def validate_campaign_contracts(self) -> None:
        for campaign, tier, field in (
            ("verification", "verification", "members"),
            ("integration", "integration", "members"),
            ("e2e", "e2e", "members"),
            ("resilience", "resilience", "members"),
            ("probes", "measurement", "members"),
            ("smoke", "smoke", "coverage"),
        ):
            self.assert_campaign_covers_tier(campaign, tier, field)

        expected_scoped = sorted(
            entry["metadata"]["id"]
            for entry in self.suites
            if entry["metadata"]["tier"] == "verification"
            and entry["access"]["tier"] in {"observer", "diagnostic"}
        )
        actual_scoped = sorted(self.campaigns["scoped-verification"]["members"])
        if actual_scoped != expected_scoped:
            fail(
                exact_diff("Campaign scoped-verification members", expected_scoped, actual_scoped)
            )
        if self.campaigns["scoped-verification"].get("execution_mode") != "scoped-local":
            fail("Campaign scoped-verification must use scoped-local execution.\n")
        if self.campaigns["verification"].get("execution_mode") != "operator-published":
            fail("Campaign verification must use operator-published execution.\n")

        expected_conformance = sorted(
            entry["metadata"]["id"]
            for entry in self.suites
            if entry["metadata"]["tier"] == "conformance"
        )
        actual_conformance = sorted(
            self.campaign_ids("conformance-quick") + self.campaign_ids("conformance-certified")
        )
        if actual_conformance != expected_conformance:
            fail(exact_diff("Conformance campaigns", expected_conformance, actual_conformance))

        if self.campaigns["validation"]["members"] != ["validation.ci"]:
            fail("Campaign validation must execute only the aggregate validation.ci suite.\n")
        if self.campaigns["standard"]["includes"] != [
            "validation",
            "smoke",
            "e2e",
            "conformance-quick",
        ]:
            fail("Campaign standard must be validation, smoke, e2e, then conformance-quick.\n")
        if self.campaigns["weekly"]["includes"] != [
            "standard",
            "verification",
            "integration",
            "probes",
            "resilience",
        ]:
            fail("Campaign weekly has an unexpected composition.\n")
        if self.campaigns["full"]["includes"] != ["weekly", "conformance-certified"]:
            fail("Campaign full must extend weekly with certified conformance.\n")
        actual_smoke = self.campaigns["smoke"]["members"]
        if actual_smoke != EXPECTED_SMOKE:
            fail(exact_diff("Campaign smoke aggregate ordering", EXPECTED_SMOKE, actual_smoke))
        actual_resilience = self.campaigns["resilience"]["members"]
        if actual_resilience != EXPECTED_RESILIENCE:
            fail(
                exact_diff("Campaign resilience ordering", EXPECTED_RESILIENCE, actual_resilience)
            )

    def validate_ci_execution(self) -> None:
        ci_ids = self.catalog["executions"]["ci"]
        if any(suite_id.startswith("verification.") for suite_id in ci_ids):
            fail("executions.ci must remain cluster-independent and exclude live verification.\n")
        duplicate_ci_ids = duplicates(ci_ids)
        if duplicate_ci_ids:
            fail(f"Duplicate executions.ci suite IDs: {'\n'.join(duplicate_ci_ids)}\n")
        for ci_id in ci_ids:
            matches = [
                entry
                for entry in self.suites
                if entry["metadata"]["id"] == ci_id
                and entry["metadata"]["source"] == "validation"
                and entry["runner"]["command"] != "mise exec -- just ci"
            ]
            if len(matches) != 1:
                fail(f"CI execution ID must resolve to one child validation suite: {ci_id}\n")
        catalog_ci_count = sum(
            entry["metadata"]["source"] == "validation"
            and entry["runner"]["command"] != "mise exec -- just ci"
            for entry in self.suites
        )
        if catalog_ci_count != len(ci_ids):
            fail(
                "Validation catalog/executions.ci count differs: "
                f"catalog={catalog_ci_count} ci={len(ci_ids)}.\n"
            )

    def validate_chainsaw_completeness(self) -> None:
        dispatch_paths = {
            shell_text(entry.get("dispatch", {}).get("path"))
            for entry in self.suites
            if entry.get("metadata", {}).get("framework") == "chainsaw"
        }
        for document_path in self.chainsaw_document_paths:
            relative_parent = document_path.parent.relative_to(REPO_ROOT).as_posix()
            if relative_parent not in dispatch_paths:
                relative_path = document_path.relative_to(REPO_ROOT).as_posix()
                fail(
                    "Error: no matches found\n"
                    f"Chainsaw document {relative_path} has no exact catalog dispatch entry.\n"
                )


def validate_catalog(catalog_argument: str) -> int:
    catalog_path = Path(catalog_argument)
    resolved_path = catalog_path if catalog_path.is_absolute() else REPO_ROOT / catalog_path
    if not resolved_path.is_file():
        print(f"Missing test catalog: {catalog_argument}", file=sys.stderr)
        return 1
    catalog = load_yaml(resolved_path)
    valid_shape = (
        isinstance(catalog, dict)
        and catalog.get("schema_version") == 2
        and isinstance(catalog.get("suites"), list)
        and len(catalog["suites"]) > 0
        and isinstance(catalog.get("executions"), dict)
        and isinstance(catalog["executions"].get("ci"), list)
        and len(catalog["executions"]["ci"]) > 0
        and isinstance(catalog.get("campaigns"), dict)
        and len(catalog["campaigns"]) > 0
    )
    if not valid_shape:
        print("Error: no matches found", file=sys.stderr)
        print(
            "Test catalog must have schema_version=2 plus suites, executions.ci, and campaigns.",
            file=sys.stderr,
        )
        return 1
    try:
        CatalogValidator(resolved_path, catalog).validate()
    except ValidationFailure as error:
        print(error.message, file=sys.stderr, end="")
        return error.status
    print(f"Test catalog passed validation: suites={len(catalog['suites'])}.")
    return 0


def main() -> int:
    return validate_catalog(sys.argv[1] if len(sys.argv) > 1 else "tests/catalog.yaml")


if __name__ == "__main__":
    raise SystemExit(main())
