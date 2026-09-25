"""Sequential, fail-closed eviction and upgrade. No deletion or rollback fallback."""

import re

NAMES = {f"openbao-{i}" for i in range(3)}


class MaintenanceError(Exception):
    """Fixed failure category with no supplied response text."""


def healthy(state):
    try:
        return (
            bool(state["cluster_id"])
            and bool(state["owner_uid"])
            and set(state["pods"]) == NAMES
            and set(state["members"]) == NAMES
            and {n for n, v in state["members"].items() if v["leader"]} == {state["leader"]}
            and len({v["node"] for v in state["pods"].values()}) == 3
            and all(
                p["ready"] is True
                and p["owner_uid"] == state["owner_uid"]
                and p["uid"]
                and p["node"]
                for p in state["pods"].values()
            )
            and all(
                m["healthy"] is True
                and m["voter"] is True
                and type(m["index"]) is int
                and m["index"] > 0
                for m in state["members"].values()
            )
        )
    except (KeyError, TypeError, AttributeError):
        return False


def identities(state):
    return (
        state["cluster_id"],
        state["owner_uid"],
        state["leader"],
        {name: (pod["uid"], pod["image"], pod["revision"]) for name, pod in state["pods"].items()},
    )


def replace_member(expected_uid, expected_role, kube, bao, clock, *, progress=None):
    progress = {} if progress is None else progress
    try:
        before = bao.snapshot()
        candidates = [n for n, p in before["pods"].items() if p["uid"] == expected_uid]
        if (
            not healthy(before)
            or len(candidates) != 1
            or expected_role not in {"leader", "standby"}
        ):
            raise MaintenanceError()
        name = candidates[0]
        if (before["leader"] == name) != (expected_role == "leader") or not bao.probe():
            raise MaintenanceError()
        kube.check()
        fresh = bao.snapshot()
        if not healthy(fresh) or identities(fresh) != identities(before):
            raise MaintenanceError()
        pod = fresh["pods"][name]
        baseline = fresh["members"][fresh["leader"]]["index"]
        # The server enforces both UID and resourceVersion; the eviction API exercises the PDB.
        kube.check()
        start = clock.monotonic()
        # Set before sending: a lost eviction response can still mean disruption.
        progress["recovery"] = "failed"
        kube.evict(name, expected_uid, pod["resource_version"])
        deadline = start + 180
        outage_start = None
        longest = 0
        while clock.monotonic() < deadline:
            available = bao.probe()
            now = clock.monotonic()
            if now >= deadline:
                raise MaintenanceError()
            if not available and outage_start is None:
                outage_start = now
            if available and outage_start is not None:
                longest = max(longest, now - outage_start)
                outage_start = None
            try:
                current = bao.snapshot()
            except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
                clock.sleep(2)
                continue
            now = clock.monotonic()
            if now >= deadline:
                raise MaintenanceError()
            if (
                current["cluster_id"] != before["cluster_id"]
                or current["owner_uid"] != before["owner_uid"]
                or any(
                    current["pods"].get(n, {}).get("uid") != p["uid"]
                    for n, p in before["pods"].items()
                    if n != name
                )
            ):
                raise MaintenanceError()
            if (
                healthy(current)
                and current["pods"][name]["uid"] != expected_uid
                and current["members"][name]["index"] >= baseline
                and available
            ):
                progress["recovery"] = "passed"
                return {
                    "status": "pass",
                    "member": name,
                    "role": expected_role,
                    "recovery_seconds": round(now - start, 3),
                    "issuance_interruption_seconds": round(longest, 3),
                }
            clock.sleep(2)
        raise MaintenanceError()
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        raise MaintenanceError() from None


def version(image):
    match = re.fullmatch(
        r"quay\.io/openbao/openbao:(\d+)\.(\d+)\.(\d+)@sha256:[0-9a-f]{64}", image
    )
    if not match:
        raise MaintenanceError()
    return tuple(map(int, match.groups()))


def upgrade(kube, bao, clock, *, progress=None):
    """The adapter proves a fresh retained snapshot and the deployed Git template."""
    progress = {} if progress is None else progress
    try:
        plan = kube.upgrade_preconditions()
        initial = bao.snapshot()
        target = version(plan["image"])
        if (
            not healthy(initial)
            or not plan["snapshot"]
            or not plan["revision"]
            or any(version(p["image"]) >= target for p in initial["pods"].values())
            or any(version(p["image"])[0] != target[0] for p in initial["pods"].values())
            or any(p["revision"] == plan["revision"] for p in initial["pods"].values())
        ):
            raise MaintenanceError()
        leader = initial["leader"]
        results = []
        upgraded = set()
        for name in sorted(NAMES - {leader}):
            if kube.upgrade_preconditions() != plan:
                raise MaintenanceError()
            current = bao.snapshot()
            if current["leader"] != leader:
                raise MaintenanceError()
            results.append(
                replace_member(initial["pods"][name]["uid"], "standby", kube, bao, clock,
                               progress=progress)
            )
            current = bao.snapshot()
            if (
                current["pods"][name]["image"] != plan["image"]
                or current["pods"][name]["revision"] != plan["revision"]
            ):
                raise MaintenanceError()
            upgraded.add(name)
        before = bao.snapshot()
        if not healthy(before) or before["leader"] != leader:
            raise MaintenanceError()
        kube.check()
        # Explicit step-down followed by proof that an upgraded voter owns leadership.
        progress["recovery"] = "failed"
        bao.transfer(leader, upgraded)
        deadline = clock.monotonic() + 60
        while clock.monotonic() < deadline:
            current = bao.snapshot()
            if healthy(current) and current["leader"] in upgraded:
                progress["recovery"] = "passed"
                break
            clock.sleep(2)
        else:
            raise MaintenanceError()
        if kube.upgrade_preconditions() != plan:
            raise MaintenanceError()
        results.append(replace_member(initial["pods"][leader]["uid"], "standby", kube, bao, clock,
                                      progress=progress))
        final = bao.snapshot()
        if not healthy(final) or any(
            p["image"] != plan["image"] or p["revision"] != plan["revision"]
            for p in final["pods"].values()
        ):
            raise MaintenanceError()
        return {"status": "pass", "replacements": results}
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        raise MaintenanceError() from None


def isolated_scope(sandbox, expected=None):
    """Interface guard: adapters must bind every API/TLS connection to this namespace UID.

    No production adapter implements this interface. Provisioning and authorizing
    a three-voter isolated environment is a separate attended prerequisite.
    """
    if not isinstance(sandbox.namespace, str) or not re.fullmatch(
        r"openbao-isolated-[a-z0-9-]+", sandbox.namespace
    ):
        raise MaintenanceError()
    meta = sandbox.namespace_state()["metadata"]
    identity = (sandbox.namespace, meta.get("uid"), sandbox.run_id)
    if (
        meta.get("name") != sandbox.namespace
        or not meta.get("uid")
        or not sandbox.run_id
        or meta.get("deletionTimestamp")
        or meta.get("annotations", {}).get("homelab.supermorphic.com/test-run") != sandbox.run_id
        or (expected is not None and identity != expected)
    ):
        raise MaintenanceError()
    return identity


def isolated_renewal(sandbox, clock):
    """Observe actual verified TLS sockets across a synthetic certificate replacement."""
    import hashlib
    import ssl

    def fingerprint():
        with sandbox.connect_tls() as connection:
            if (
                connection.context.verify_mode != ssl.CERT_REQUIRED
                or not connection.context.check_hostname
            ):
                raise MaintenanceError()
            return hashlib.sha256(connection.getpeercert(binary_form=True)).hexdigest()

    try:
        scope = isolated_scope(sandbox)
        initial = sandbox.snapshot()
        if not healthy(initial):
            raise MaintenanceError()
        old = fingerprint()
        isolated_scope(sandbox, scope)
        fresh = sandbox.snapshot()
        if not healthy(fresh) or identities(fresh) != identities(initial):
            raise MaintenanceError()
        expected = sandbox.rotate_certificate()
        if (
            not isinstance(expected, str)
            or not re.fullmatch("[0-9a-f]{64}", expected)
            or expected == old
        ):
            raise MaintenanceError()
        deadline = clock.monotonic() + 180
        while clock.monotonic() < deadline:
            isolated_scope(sandbox, scope)
            current = sandbox.snapshot()
            if not healthy(current) or identities(current) != identities(initial):
                raise MaintenanceError()
            if fingerprint() == expected:
                return {
                    "status": "pass",
                    "verified_tls": True,
                    "certificate_changed": True,
                    "quorum_preserved": True,
                }
            clock.sleep(2)
        raise MaintenanceError()
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        raise MaintenanceError() from None


def isolated_drift(sandbox):
    """Inject and restore bounded configuration only through an isolated adapter.

    observe_drift must run the real desired-versus-live comparator through its
    reader identity. request uses the separately authorized isolated operator.
    """
    import json

    scope = isolated_scope(sandbox)
    cases = [
        ("auth-method", "sys/auth/homelab-jwt/tune", {"description": "isolated-synthetic-drift"}),
        ("policy", "sys/policies/acl/openbao-acceptance", {"policy": json.dumps({"path": {}})}),
        ("issuance-role", "kubernetes/roles/openbao-acceptance", {"token_default_ttl": 300}),
        (
            "reader-denial",
            "sys/policies/acl/openbao-config-reader",
            {"policy": json.dumps({"path": {}})},
        ),
    ]

    def request(method, path, payload=None):
        isolated_scope(sandbox, scope)
        status, body = sandbox.request(method, path, payload=payload)
        if status not in ({200} if method == "GET" else {200, 204}):
            raise MaintenanceError()
        return body.get("data", body)

    try:
        if not healthy(sandbox.snapshot()) or sandbox.observe_drift():
            raise MaintenanceError()
        for kind, path, mutation in cases:
            saved = request("GET", path)
            # Restore only fields we change; never write arbitrary response metadata.
            original = {field: saved[field] for field in mutation}
            try:
                request("POST", path, mutation)
                if kind == "reader-denial":
                    status, _ = sandbox.reader_request(
                        "GET", "sys/policies/acl/openbao-config-reader"
                    )
                    if status != 403:
                        raise MaintenanceError()
                elif kind not in sandbox.observe_drift():
                    raise MaintenanceError()
            finally:
                request("POST", path, original)
            if sandbox.observe_drift() or not healthy(sandbox.snapshot()):
                raise MaintenanceError()
        return {
            "status": "pass",
            "auth_method": True,
            "policy": True,
            "role": True,
            "reader_denial": True,
            "restored": True,
        }
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        raise MaintenanceError() from None
