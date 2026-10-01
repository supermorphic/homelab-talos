"""One attended acceptance: real profiles/callers, isolated workstation auth."""

import base64
import copy
import hashlib
import json
import os
import select
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.openbao import apply, credentials, guards, issuance, workstation
from scripts.openbao.client import AmbiguousWrite, BaoClient, NotFound
from scripts.openbao.configuration import ObjectSpec, SafeError, load_document
from scripts.openbao.drift import compare
from scripts.openbao.operator import (
    OperatorClient,
    lease,
    operator_password_session,
    private_prompt,
)
from scripts.test.scenarios.resilience_support import atomic_write_json, install_interrupt_handlers


def run_inputs():
    selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
    run = os.environ.get("HOMELAB_TEST_RUN_DIR", "")
    config, directory = Path(selected), Path(run)
    if (
        not selected
        or not config.is_absolute()
        or not config.is_file()
        or os.environ.get("TEST_KUBECONFIG") != selected
        or not run
        or not directory.is_dir()
        or os.environ.get("TEST_CAMPAIGN_LEASE_HOLDER")
    ):
        raise SafeError("invalid-source")
    return config, directory


class BrokerScope:
    def __init__(self, kubeconfig, run_id, directory, client, approved, *, clock=time):
        self.kubeconfig, self.run_id, self.directory = kubeconfig, run_id, directory
        self.client, self.approved = client, approved
        self.actors = []
        self.clock = clock

    def actor(self, suffix):
        if suffix not in {"a", "b"}:
            raise SafeError("invalid-source")
        role = (
            "agent-acceptance-"
            + hashlib.sha256(self.run_id.encode()).hexdigest()[:16]
            + "-"
            + suffix
        )
        actor = {
            "role": role,
            "path": "auth/homelab-approle/role/" + role,
            "directory": self.directory / suffix,
        }
        self.actors.append(actor)
        return actor

    def guard(self):
        guards.assert_mutation_allowed(self.kubeconfig)
        if workstation.target(self.kubeconfig) != self.approved:
            raise SafeError("source-mismatch")

    def post(self, path, payload):
        self.guard()
        return self.client.post(path, payload, token=self.client.token)

    def read(self, path, *, list_request=False):
        return self.client.read(path, token=self.client.token, list_request=list_request)

    def ids(self, actor):
        try:
            data = self.read(actor["path"] + "/secret-id", list_request=True)["data"]
        except NotFound:
            return []
        if (
            not isinstance(data, dict)
            or set(data) != {"keys"}
            or not isinstance(data["keys"], list)
            or any(not isinstance(k, str) or not k for k in data["keys"])
            or len(data["keys"]) != len(set(data["keys"]))
        ):
            raise SafeError("incomplete-list")
        return data["keys"]

    def owned_entity(self, actor, *, allow_unbound=False):
        entity = self.read("identity/entity/name/" + actor["role"])["data"]
        if (
            entity.get("metadata", {}).get("test_run") != self.run_id
            or entity.get("name") != actor["role"]
            or not entity.get("id")
            or (actor.get("entity_id") and entity["id"] != actor["entity_id"])
            or any(
                entity.get(k) not in (None, [])
                for k in ("policies", "group_ids", "direct_group_ids", "inherited_group_ids")
            )
        ):
            raise SafeError("source-mismatch")
        aliases = entity.get("aliases", [])
        if (
            actor.get("role_id")
            and not (allow_unbound and aliases == [])
            and (
                len(aliases) != 1
                or aliases[0].get("name") != actor["role_id"]
                or aliases[0].get("mount_accessor") != actor["mount_accessor"]
                or aliases[0].get("canonical_id") != entity["id"]
            )
        ):
            raise SafeError("source-mismatch")
        return entity

    def create(self, actor, metadata):
        # Record intent privately before writes; an ambiguous response is not retried.
        self.persist()
        for path in (actor["path"], "identity/entity/name/" + actor["role"]):
            try:
                self.read(path)
            except NotFound:
                continue
            raise SafeError("source-mismatch")
        spec = next(o for o in load_document(apply.DESIRED)["objects"] if o.kind == "approle-role")
        actor["fields"] = copy.deepcopy(spec.fields)
        self.persist()
        self.post(actor["path"], actor["fields"])
        actor["role_id"] = self.read(actor["path"] + "/role-id")["data"]["role_id"]
        actor["mount_accessor"] = self.read("sys/auth")["data"]["homelab-approle/"]["accessor"]
        # The unique run-owned role must have no prior alias mapping.
        try:
            found = self.client.post(
                "identity/lookup/entity",
                {"alias_name": actor["role_id"], "alias_mount_accessor": actor["mount_accessor"]},
                token=self.client.token,
            )
        except AmbiguousWrite as error:
            if error.http_status != 404:
                raise
            found = {}
        if found.get("data"):
            raise SafeError("source-mismatch")
        created = self.post(
            "identity/entity",
            {"name": actor["role"], "policies": [], "metadata": {"test_run": self.run_id}},
        )
        actor["entity_id"] = created["data"]["id"]
        self.persist()
        self.post(
            "identity/entity-alias",
            {
                "name": actor["role_id"],
                "mount_accessor": actor["mount_accessor"],
                "canonical_id": actor["entity_id"],
            },
        )
        self.owned_entity(actor)
        workstation.ensure_private_directory(actor["directory"])
        workstation.write_private(actor["directory"] / "cluster.json", metadata)
        self.rotate(actor, metadata, initial=True)

    def persist(self):
        workstation.write_private(
            self.directory / "operator.json",
            {
                "schema_version": 1,
                "run_id": self.run_id,
                "target": self.approved,
                "actors": [
                    {k: v for k, v in actor.items() if k != "directory"} for actor in self.actors
                ],
            },
        )

    def rotate(self, actor, metadata, *, initial=False):
        self.owned_entity(actor)
        old = [] if initial else self.ids(actor)
        secret = self.post(actor["path"] + "/secret-id", {})["data"]
        if (
            secret.get("secret_id_ttl") != 7776000
            or secret.get("secret_id_num_uses") != 0
            or not secret.get("secret_id")
            or not secret.get("secret_id_accessor")
        ):
            raise SafeError("invalid-response")
        local = {
            "schema_version": 1,
            "role_id": actor["role_id"],
            "entity_id": actor["entity_id"],
            "secret_id": secret["secret_id"],
            "expires_at": time.time() + 7776000,
            "cluster_digest": guards.digest(metadata),
        }
        credentials.issue_exec_credential(
            "observer",
            {**local, "cluster": metadata},
            client=BaoClient(workstation.ENDPOINT),
            now=time.time(),
        )
        workstation.write_private(actor["directory"] / "workstation.json", local)
        for accessor in old:
            self.post(
                actor["path"] + "/secret-id-accessor/destroy", {"secret_id_accessor": accessor}
            )
        if set(self.ids(actor)) != {secret["secret_id_accessor"]}:
            raise SafeError("incomplete-list")

    def disable(self, actor, *, allow_unbound=False):
        entity = self.owned_entity(actor, allow_unbound=allow_unbound)
        self.post("identity/entity/id/" + entity["id"], {"disabled": True})
        if self.owned_entity(actor, allow_unbound=allow_unbound).get("disabled") is not True:
            raise SafeError("source-mismatch")
        actor["disabled_at"] = self.clock.monotonic()
        self.persist()

    def destroy_ids(self, actor):
        for accessor in self.ids(actor):
            self.post(
                actor["path"] + "/secret-id-accessor/destroy", {"secret_id_accessor": accessor}
            )
        if self.ids(actor):
            raise SafeError("incomplete-list")

    def cleanup(self):
        for actor in self.actors:
            # Resolve a lost creation response by readback, never by another POST.
            try:
                live = self.read(actor["path"])["data"]
            except NotFound:
                live = None
            if live is not None:
                spec = ObjectSpec(
                    "approle-role", actor["role"], actor["path"], actor.get("fields", {})
                )
                if not spec.fields or compare(spec, live):
                    raise SafeError("source-mismatch")
                role_id = self.read(actor["path"] + "/role-id")["data"]["role_id"]
                if actor.get("role_id") and actor["role_id"] != role_id:
                    raise SafeError("source-mismatch")
                actor["role_id"] = role_id
                actor["mount_accessor"] = self.read("sys/auth")["data"]["homelab-approle/"][
                    "accessor"
                ]
            try:
                entity = self.owned_entity(actor, allow_unbound=True)
            except NotFound:
                entity = None
            if entity:
                self.disable(actor, allow_unbound=True)
            self.destroy_ids(actor)
        # Deleting a disabled entity must not allow an outstanding session to
        # lose its barrier. Keep entities until the hard token bound has elapsed.
        wait_until = max((a.get("disabled_at", 0) + 90 for a in self.actors), default=0)
        while self.clock.monotonic() < wait_until:
            self.clock.sleep(min(5, wait_until - self.clock.monotonic()))
            self.guard()
        for actor in self.actors:
            entity = None
            try:
                entity = self.owned_entity(actor, allow_unbound=True)
            except NotFound:
                pass
            if entity:
                if entity.get("disabled") is not True:
                    raise SafeError("source-mismatch")
                for alias in entity.get("aliases", []):
                    self.guard()
                    self.client.delete(
                        "identity/entity-alias/id/" + alias["id"], token=self.client.token
                    )
                self.guard()
                self.client.delete("identity/entity/id/" + entity["id"], token=self.client.token)
                try:
                    self.read("identity/entity/name/" + actor["role"])
                except NotFound:
                    pass
                else:
                    raise SafeError("incomplete-list")
            try:
                live = self.read(actor["path"])["data"]
            except NotFound:
                continue
            spec = ObjectSpec("approle-role", actor["role"], actor["path"], actor["fields"])
            if compare(spec, live) or self.read(actor["path"] + "/role-id")["data"][
                "role_id"
            ] != actor.get("role_id"):
                raise SafeError("source-mismatch")
            self.guard()
            self.client.delete(actor["path"], token=self.client.token)
            try:
                self.read(actor["path"])
            except NotFound:
                continue
            raise SafeError("incomplete-list")


def fixture_launcher():
    return """#!/usr/bin/env bash
set -euo pipefail
set +x
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
exec mise exec -- uv run --locked --no-dev python - "$1" <<'PYTHON'
import base64, json, os, sys, time
from pathlib import Path
from scripts.openbao import credentials, workstation
from scripts.openbao.client import BaoClient
from scripts.openbao.configuration import ObjectSpec, SafeError, load_document
workstation.DIRECTORY = Path(os.environ['AGENT_ACCEPTANCE_DIRECTORY'])
class MeasuredClient(BaoClient):
    def post(self, path, payload, **kwargs):
        if (workstation.DIRECTORY / 'outage').exists():
            raise SafeError('timeout')
        started = time.monotonic()
        response = super().post(path, payload, **kwargs)
        if path.startswith('kubernetes/creds/'):
            part = response['data']['service_account_token'].split('.')[1]
            expires = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))['exp']
            record = {'profile': path.split('/')[-1], 'elapsed_ms': (time.monotonic() - started) * 1000, 'expires_at': expires, 'issued_at': time.time()}
            fd = os.open(workstation.DIRECTORY / 'events.jsonl', os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, 'a') as out: out.write(json.dumps(record) + '\\n')
        return response
credentials.BaoClient = MeasuredClient
raise SystemExit(credentials.main(['exec', sys.argv[1]]))
PYTHON
"""


def check_fixture_root(root):
    if (
        not root.is_absolute()
        or root.resolve() != root
        or root == guards.ROOT
        or guards.ROOT in root.parents
    ):
        raise SafeError("invalid-source")


def fixtures(directory, actor):
    standalone = directory / "standalone"
    linked = directory / "linked"
    check_fixture_root(standalone)
    subprocess.run(
        [
            "git",
            "clone",
            "--local",
            "--no-hardlinks",
            "--quiet",
            str(guards.ROOT),
            str(standalone),
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )
    subprocess.run(
        ["git", "-C", str(standalone), "worktree", "add", "--quiet", "--detach", str(linked)],
        check=True,
        capture_output=True,
        timeout=30,
    )
    for root in (standalone, linked):
        launcher = root / credentials.LAUNCHER
        launcher.write_text(fixture_launcher())
        launcher.chmod(0o755)
        credentials.install_kubeconfig(root, actor["directory"])
    return standalone, linked


def environment(root, actor):
    return {
        **os.environ,
        "AGENT_ACCEPTANCE_DIRECTORY": str(actor["directory"]),
        "MISE_TRUSTED_CONFIG_PATHS": str(root),
    }


def kubectl(root, actor, profile, *args, allowed=True):
    result = subprocess.run(
        [
            "mise",
            "exec",
            "--",
            "kubectl",
            "--kubeconfig",
            str(root / ".kube/config"),
            "--context",
            credentials.PROFILES[profile],
            "--request-timeout=20s",
            *args,
        ],
        env=environment(root, actor),
        cwd=root,
        capture_output=True,
        timeout=30,
        check=False,
    )
    if (result.returncode == 0) != allowed:
        raise SafeError("invalid-response")
    return result.stdout


def permissions(root, actor):
    matrix = {
        "observer": [("list", "nodes", None, True), ("create", "pods", "openbao", False)],
        "diagnostic": [
            ("create", "pods/automation-data-postgresql-0", "automation-data", True),
            ("create", "pods/openbao-0", "openbao", False),
        ],
        "publisher": [
            ("get", "deployments.apps/test-reports", "test-reports", True),
            ("update", "roles.rbac.authorization.k8s.io", "test-reports", False),
        ],
        "campaign-coordinator": [
            ("update", "leases.coordination.k8s.io/homelab-test-run-lock", "flux-system", True),
            ("list", "leases.coordination.k8s.io", "flux-system", False),
        ],
    }
    for profile, cases in matrix.items():
        identity = json.loads(kubectl(root, actor, profile, "auth", "whoami", "-o", "json"))
        if (
            identity["status"]["userInfo"]["username"]
            != "system:serviceaccount:kube-system:" + credentials.PROFILES[profile]
        ):
            raise SafeError("authentication-failed")
        for verb, resource, namespace, expected in cases:
            args = ["auth", "can-i", verb, resource]
            if namespace:
                args += ["-n", namespace]
            if profile == "diagnostic":
                args += [
                    "--subresource",
                    "portforward" if namespace == "automation-data" else "exec",
                ]
            output = kubectl(root, actor, profile, *args, allowed=expected).strip()
            if output != (b"yes" if expected else b"no"):
                raise SafeError("invalid-response")
        denied = kubectl(
            root,
            actor,
            profile,
            "auth",
            "can-i",
            "list",
            "secrets",
            "-n",
            "openbao",
            allowed=False,
        )
        if denied.strip() != b"no":
            raise SafeError("invalid-response")


@contextmanager
def process(args, root, actor, *, stdout=subprocess.DEVNULL):
    child = subprocess.Popen(
        ["mise", "exec", "--", *args],
        cwd=root,
        env=environment(root, actor),
        stdout=stdout,
        stderr=subprocess.DEVNULL,
    )
    try:
        yield child
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        if child.stdout is not None:
            child.stdout.close()


def read_url(url, *, context=None, token=None):
    request = urllib.request.Request(
        url, headers={"Authorization": "Bearer " + token} if token else {}
    )
    try:
        with urllib.request.urlopen(request, context=context, timeout=10) as response:
            response.read(1048577)
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except OSError:
        return 0


@contextmanager
def watch_connection(root, actor):
    # A raw watch emits actual server ADDED events, proving the streaming request.
    with process(
        [
            "kubectl",
            "--kubeconfig",
            str(root / ".kube/config"),
            "--context",
            "homelab-observer",
            "get",
            "--raw=/api/v1/nodes?watch=true&resourceVersion=0&timeoutSeconds=900",
            "--request-timeout=15m",
        ],
        root,
        actor,
        stdout=subprocess.PIPE,
    ) as child:
        data = b""
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and child.poll() is None:
            if not select.select([child.stdout], [], [], 1)[0]:
                continue
            part = os.read(child.stdout.fileno(), 4096)
            if not part or len(data) + len(part) > 1048576:
                break
            data += part
            try:
                event, _ = json.JSONDecoder().raw_decode(data.decode().lstrip())
            except (ValueError, UnicodeError):
                continue
            if event.get("type") != "ADDED" or event.get("object", {}).get("kind") != "Node":
                break
            yield child
            return
        raise SafeError("invalid-response")


@contextmanager
def diagnostic_connection(root, actor):
    with process(
        [
            "kubectl",
            "--kubeconfig",
            str(root / ".kube/config"),
            "--context",
            "homelab-diagnostic",
            "-n",
            "automation-data",
            "port-forward",
            "--address=127.0.0.1",
            "pod/automation-data-postgresql-0",
            ":5432",
        ],
        root,
        actor,
        stdout=subprocess.PIPE,
    ) as child:
        if (
            not select.select([child.stdout], [], [], 20)[0]
            or not child.stdout.readline().startswith(b"Forwarding from 127.0.0.1:")
            or child.poll() is not None
        ):
            raise SafeError("invalid-response")
        yield child


def publisher_operations(root, actor):
    kubectl(
        root,
        actor,
        "publisher",
        "-n",
        "test-reports",
        "rollout",
        "status",
        "deployment/test-reports",
        "--timeout=15s",
    )
    kubectl(
        root,
        actor,
        "publisher",
        "-n",
        "test-reports",
        "exec",
        "deployment/test-reports",
        "-c",
        "caddy",
        "--",
        "test",
        "-d",
        "/srv",
    )


def assert_caller_refresh(actor, profiles):
    events = [
        json.loads(line) for line in (actor["directory"] / "events.jsonl").read_text().splitlines()
    ]
    for profile in profiles:
        calls = [event for event in events if event["profile"] == profile]
        if not calls or not any(
            event["issued_at"] > min(c["expires_at"] for c in calls) for event in calls
        ):
            raise SafeError("invalid-response")


def lifetime_outage(
    root, actor, *, coordinator_root=None, coordinator_actor=None, diagnostics=None
):
    if diagnostics is None:
        diagnostics = {}
    diagnostics["caller_stage"] = "start-callers"
    config = str(root / ".kube/config")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    local = credentials.load_workstation(actor["directory"])
    raw = credentials.issue_exec_credential(
        "observer", local, client=BaoClient(workstation.ENDPOINT), now=time.time()
    )
    expiry = datetime.fromisoformat(raw["status"]["expirationTimestamp"]).timestamp()
    ca = base64.b64decode(local["cluster"]["certificate_authority_data"]).decode()
    context = ssl.create_default_context(cadata=ca)
    upstream = local["cluster"]["server"] + "/api/v1/nodes?limit=1"
    proxy = f"http://127.0.0.1:{port}/api/v1/nodes?limit=1"
    with (
        process(
            [
                "kubectl",
                "--kubeconfig",
                config,
                "--context",
                "homelab-observer",
                "proxy",
                "--address=127.0.0.1",
                f"--port={port}",
            ],
            root,
            actor,
        ) as cached,
        watch_connection(root, actor) as watch,
        diagnostic_connection(root, actor) as diagnostic,
        coordinator_window(coordinator_root or root, coordinator_actor or actor) as coordination,
    ):
        deadline = time.monotonic() + 30
        while read_url(proxy) != 200:
            if cached.poll() is not None or time.monotonic() >= deadline:
                raise SafeError("invalid-response")
            time.sleep(1)
        diagnostics["caller_stage"] = "publisher-before-expiry"
        publisher_operations(root, actor)
        # Include actual initial caller expiries; setup time must not shorten their window.
        for source in (actor, coordinator_actor or actor):
            events = source["directory"] / "events.jsonl"
            if events.exists():
                expiry = max(
                    expiry,
                    *[json.loads(line)["expires_at"] for line in events.read_text().splitlines()],
                )
        time.sleep(2)
        outage = actor["directory"] / "outage"
        outage.touch(mode=0o600)
        try:
            diagnostics["caller_stage"] = "outage-before-expiry"
            if read_url(proxy) != 200:
                raise SafeError("invalid-response")
            kubectl(root, actor, "observer", "get", "nodes", allowed=False)
            diagnostics["caller_stage"] = "wait-through-expiry"
            while time.time() <= expiry + issuance.API_EXPIRY_LEEWAY + issuance.SKEW + 5:
                exited = [
                    name for name, child in (
                        ("proxy", cached), ("watch", watch),
                        ("diagnostic", diagnostic), ("coordinator", coordination),
                    ) if child.poll() is not None
                ]
                if exited:
                    diagnostics["exited_callers"] = exited
                    raise SafeError("invalid-response")
                time.sleep(
                    min(
                        5,
                        max(
                            0.1,
                            expiry + issuance.API_EXPIRY_LEEWAY + issuance.SKEW + 6 - time.time(),
                        ),
                    )
                )
            # Fresh request forces the cached process to refresh; an open stream
            # alone cannot prove credential refresh or server-side expiry.
            diagnostics["caller_stage"] = "expired-token-denial"
            if (
                read_url(proxy) == 200
                or read_url(upstream, context=context, token=raw["status"]["token"]) != 401
            ):
                raise SafeError("invalid-response")
        finally:
            outage.unlink(missing_ok=True)
        diagnostics["caller_stage"] = "cached-client-recovery"
        if read_url(proxy) != 200:
            raise SafeError("invalid-response")
        # Reconnect real watch/diagnostic transports; process survival is insufficient.
        diagnostics["caller_stage"] = "reconnect-callers"
        with watch_connection(root, actor), diagnostic_connection(root, actor):
            publisher_operations(root, actor)
            kubectl(root, actor, "observer", "get", "nodes")
        diagnostics["caller_stage"] = "stop-callers"
    diagnostics["caller_stage"] = "verify-caller-refresh"
    assert_caller_refresh(actor, ["observer", "diagnostic", "publisher"])
    assert_caller_refresh(coordinator_actor or actor, ["campaign-coordinator"])
    diagnostics.pop("caller_stage", None)
    return {
        "cached_before_expiry": True,
        "new_command_denied": True,
        "expired_token_denied": True,
        "refresh_failed_then_recovered": True,
        "watch_and_diagnostic_reconnected": True,
        "publisher_and_lease_across_expiry": True,
    }


@contextmanager
def coordinator_window(root, actor):
    holder = (
        "agent-credentials-" + hashlib.sha256(str(actor["directory"]).encode()).hexdigest()[:16]
    )
    stop = actor["directory"] / "coordinator-stop"
    failed = actor["directory"] / "coordinator-failed"
    stop.unlink(missing_ok=True)
    failed.unlink(missing_ok=True)
    credentials.install_kubeconfig(root, actor["directory"], "campaign-coordinator")
    script = """set -euo pipefail
export TEST_LEASE_NAMESPACE=flux-system TEST_LEASE_NAME=homelab-test-run-lock
export TEST_LEASE_DURATION_SECONDS=90 TEST_LEASE_RENEW_INTERVAL_SECONDS=15
unset TEST_LEASE_KUBECTL TEST_LEASE_SLEEP
source scripts/lib/lease.sh
lease_is_expired() { return 1; }
acquire_test_lease "$1" "$2" 1 existing-only
trap 'release_test_lease "$1" "$2" >/dev/null' EXIT
renew_test_lease "$1" "$2"
if acquire_test_lease "$1" "$2-contender" 1 existing-only >/dev/null 2>&1; then exit 1; fi
start_test_lease_renewal "$1" "$2" "$4"
printf 'READY\n'
while [[ ! -f "$3" ]]; do [[ ! -f "$4" ]]; sleep 1; done
[[ ! -f "$4" ]]
stop_test_lease_renewal
renew_test_lease "$1" "$2"
verify_test_lease_holder "$1" "$2"
release_test_lease "$1" "$2"
trap - EXIT
"""
    try:
        with process(
            [
                "bash",
                "-c",
                script,
                "acceptance",
                str(root / ".kube/config"),
                holder,
                str(stop),
                str(failed),
            ],
            root,
            actor,
            stdout=subprocess.PIPE,
        ) as child:
            try:
                if (
                    not select.select([child.stdout], [], [], 30)[0]
                    or child.stdout.readline() != b"READY\n"
                    or child.poll() is not None
                ):
                    raise SafeError("invalid-response")
                yield child
            finally:
                stop.touch(mode=0o600)
                if child.wait(timeout=30) != 0 or failed.exists():
                    raise SafeError("invalid-response")
    finally:
        credentials.install_kubeconfig(root, actor["directory"])


def revocation(scope, actor, other):
    route = BaoClient(workstation.ENDPOINT)
    local = credentials.load_workstation(actor["directory"])
    auth = route.post(
        workstation.LOGIN_PATH, {"role_id": local["role_id"], "secret_id": local["secret_id"]}
    )["auth"]
    workstation.validate_session(auth, local["entity_id"])
    started = time.monotonic()
    issued = route.post("kubernetes/creds/observer", {"ttl": 600}, token=auth["client_token"])[
        "data"
    ]
    if (
        issued.get("service_account_name") != "homelab-observer"
        or issued.get("service_account_namespace") != "kube-system"
    ):
        raise SafeError("invalid-response")
    issuance.token_claims(
        issued["service_account_token"],
        time,
        identity="system:serviceaccount:kube-system:homelab-observer",
    )
    scope.disable(actor)
    if time.monotonic() - started >= 50:
        raise SafeError("timeout")
    for profile in credentials.PROFILES:
        try:
            route.post("kubernetes/creds/" + profile, {"ttl": 600}, token=auth["client_token"])
        except AmbiguousWrite as error:
            if error.http_status != 403:
                raise
        else:
            raise SafeError("authentication-failed")
    if time.monotonic() - started >= 50:
        raise SafeError("timeout")
    scope.destroy_ids(actor)
    try:
        route.post(
            workstation.LOGIN_PATH, {"role_id": local["role_id"], "secret_id": local["secret_id"]}
        )
    except AmbiguousWrite as error:
        if error.http_status not in {400, 403}:
            raise
    else:
        raise SafeError("authentication-failed")
    unaffected = credentials.load_workstation(other["directory"])
    credentials.issue_exec_credential("observer", unaffected, client=route, now=time.time())


def main():
    result = {"status": "fail", "cleanup": "not-required"}
    client = scope = run_dir = None
    private = None
    stage = "preflight"
    try:
        kubeconfig, run_dir = run_inputs()
        approved = workstation.target(kubeconfig)
        confirmation = f"agent-credentials:openbao:{approved['source_revision']}:{run_dir.name}"
        if (
            os.environ.get("AGENT_CREDENTIALS_CONFIRM") != confirmation
            and private_prompt(f"Exact confirmation {confirmation}: ") != confirmation
        ):
            raise SafeError("invalid-source")
        install_interrupt_handlers()
        parent = Path.home() / ".config/homelab-talos/acceptance"
        workstation.ensure_private_directory(parent)
        private = Path(tempfile.mkdtemp(prefix="agent-", dir=parent)).resolve()
        client = OperatorClient(kubeconfig)
        password = private_prompt("Retained OpenBao operator password: ")
        with operator_password_session(client, password) as token:
            client.set_token(token)
            scope = BrokerScope(kubeconfig, run_dir.name, private, client, approved)
            try:
                stage = "create-identities"
                with lease(kubeconfig):
                    if apply.verify_configuration(apply.DESIRED, client) != {"differences": []}:
                        raise SafeError("source-mismatch")
                    metadata = workstation.cluster_metadata(kubeconfig)
                    a, b = scope.actor("a"), scope.actor("b")
                    for actor in (a, b):
                        scope.create(actor, metadata)
                stage = "profiles-and-parallel-checkouts"
                primary, linked = fixtures(private, b)
                for root in (primary, linked):
                    permissions(root, b)
                with ThreadPoolExecutor(max_workers=2) as pool:
                    list(
                        pool.map(
                            lambda root: kubectl(root, b, "observer", "get", "nodes"),
                            (primary, linked),
                        )
                    )
                result["profiles_and_parallel_checkouts"] = True
                stage = "lifetime-outage"
                result["lifetime_outage"] = lifetime_outage(
                    primary, b, coordinator_root=linked, coordinator_actor=a, diagnostics=result
                )
                result["caller_transports_and_coordinator"] = True
                stage = "revocation-and-rotation"
                with lease(kubeconfig):
                    revocation(scope, a, b)
                    old = credentials.load_workstation(b["directory"])
                    scope.rotate(b, metadata)
                    try:
                        BaoClient(workstation.ENDPOINT).post(
                            workstation.LOGIN_PATH,
                            {"role_id": old["role_id"], "secret_id": old["secret_id"]},
                        )
                    except AmbiguousWrite as error:
                        if error.http_status not in {400, 403}:
                            raise
                    else:
                        raise SafeError("authentication-failed")
                kubectl(primary, b, "observer", "get", "nodes")
                events = [
                    json.loads(line)
                    for actor in (a, b)
                    for line in (actor["directory"] / "events.jsonl").read_text().splitlines()
                ]
                result.update(
                    issuance_count=len(events),
                    maximum_issuance_ms=round(max(e["elapsed_ms"] for e in events), 2),
                    revocation=True,
                    rotation=True,
                    status="pass",
                )
            except BaseException as error:
                result["failure_stage"] = stage
                result["classification"] = (
                    str(error) if isinstance(error, SafeError) else "invalid-response"
                )
                raise
            finally:
                try:
                    with lease(kubeconfig):
                        scope.cleanup()
                    result["cleanup"] = "passed"
                except BaseException as error:
                    result["cleanup_classification"] = (
                        str(error) if isinstance(error, SafeError) else "invalid-response"
                    )
                    result.setdefault("failure_stage", "cleanup")
                    raise
    except BaseException as error:  # noqa: BLE001 -- Includes interrupt cleanup; never expose secret-bearing exceptions.
        result["status"] = "fail"
        result.setdefault(
            "classification", str(error) if isinstance(error, SafeError) else "invalid-response"
        )
        if scope and result["cleanup"] != "passed":
            result["cleanup"] = "failed"
    finally:
        if client:
            client.close()
        if private and result["cleanup"] == "passed":
            shutil.rmtree(private)
        if run_dir:
            atomic_write_json(run_dir / "diagnostics/agent-credentials.json", result)
            for phase in ("cleanup", "recovery"):
                atomic_write_json(
                    run_dir / (phase + ".json"),
                    {
                        "status": result["cleanup"],
                        "reason": "owned acceptance identities and Lease sections",
                    },
                )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
