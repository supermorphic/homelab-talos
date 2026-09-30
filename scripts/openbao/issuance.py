"""Actual API acceptance. Bearer values stay in memory and never enter evidence."""

import base64
import json
from datetime import datetime

NAMESPACE = "openbao-acceptance"
ACCOUNT = "openbao-issued-reader"
IDENTITY = f"system:serviceaccount:{NAMESPACE}:{ACCOUNT}"
AUDIENCE = "https://192.168.90.20:6443"
SKEW = 30
# Kubernetes v1.35.6 validates ServiceAccount claims with go-jose DefaultLeeway.
API_EXPIRY_LEEWAY = 60
EXPIRY_POLL_INTERVAL = 5


class AcceptanceError(Exception):
    """Sanitized failure; never include transport or response text."""

    def __init__(self, *, step=None, http_status=None):
        super().__init__()
        self.step = step if step in {
            "login", "issue", "denial", "revoke", "claims", "identity", "canary",
            "protected", "expiry",
        } else None
        self.http_status = http_status if type(http_status) is int and 100 <= http_status <= 599 else None
        self.session_cleanup_failed = False

    def evidence(self):
        result = {}
        if self.step:
            result["step"] = self.step
        if self.http_status is not None:
            result["http_status"] = self.http_status
        if self.session_cleanup_failed:
            result["session_cleanup"] = "failed"
        return result


def call(api, method, path, expected, **kwargs):
    try:
        status, body = api.request(method, path, **kwargs)
        if status not in expected or not isinstance(body, dict):
            raise AcceptanceError(http_status=status)
        return body
    except AcceptanceError:
        raise
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        raise AcceptanceError() from None


def token_claims(token, clock):
    try:
        parts = token.split(".")
        if len(parts) != 3 or len(token) > 32768:
            raise AcceptanceError()
        claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
        issued, expires = claims["iat"], claims["exp"]
        if (
            claims["sub"] != IDENTITY
            or claims["aud"] != [AUDIENCE]
            or type(issued) is not int
            or type(expires) is not int
            or expires - issued != 600
            or abs(clock.time() - issued) > SKEW
            or not 0 < expires - clock.time() <= 600 + SKEW
        ):
            raise AcceptanceError()
        return expires
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        raise AcceptanceError() from None


def prove_identity(kube, token):
    body = call(
        kube,
        "POST",
        "/apis/authentication.k8s.io/v1/selfsubjectreviews",
        {201},
        token=token,
        payload={"apiVersion": "authentication.k8s.io/v1", "kind": "SelfSubjectReview"},
    )
    if body.get("status", {}).get("userInfo", {}).get("username") != IDENTITY:
        raise AcceptanceError()


def acceptance(bao, kube, clock, *, wait_expiry=True):
    """Use dedicated workload authentication; check the credential Kubernetes accepts."""
    session = None
    failure = None
    step = "login"
    try:
        session = bao.login()
        step = "issue"
        data = bao.issue(session)
        step = "denial"
        if bao.deny_unapproved(session) is not True:
            raise AcceptanceError()
        # The OpenBao session also expires after 600 seconds. Revoke it before
        # waiting on the independently issued Kubernetes credential. Never retry
        # an ambiguous revoke; the run must fail if that one request fails.
        issued_session, session = session, None
        step = "revoke"
        bao.revoke(issued_session)
        step = "claims"
        if (
            data["service_account_name"] != ACCOUNT
            or data["service_account_namespace"] != NAMESPACE
        ):
            raise AcceptanceError()
        token = data["service_account_token"]
        expires = token_claims(token, clock)
        step = "identity"
        prove_identity(kube, token)
        path = f"/api/v1/namespaces/{NAMESPACE}/configmaps/"
        step = "canary"
        body = call(kube, "GET", path + "openbao-canary", {200}, token=token)
        if body.get("data") != {"marker": "synthetic-openbao-reader-canary"}:
            raise AcceptanceError()
        step = "protected"
        call(kube, "GET", path + "openbao-protected", {403}, token=token)
        if wait_expiry:
            step = "expiry"
            reject_by = expires + API_EXPIRY_LEEWAY + SKEW + EXPIRY_POLL_INTERVAL
            deadline = clock.monotonic() + reject_by - clock.time()
            while clock.time() <= expires + SKEW:
                if clock.monotonic() >= deadline:
                    raise AcceptanceError()
                clock.sleep(min(EXPIRY_POLL_INTERVAL, expires + SKEW + 1 - clock.time()))
            while True:
                if clock.monotonic() > deadline:
                    raise AcceptanceError()
                status, _ = kube.request("GET", path + "openbao-canary", token=token)
                if clock.monotonic() > deadline:
                    raise AcceptanceError()
                if status == 401:
                    break
                # Success within API leeway is permitted. Forbidden, transport
                # failure, and success beyond the bound cannot prove expiry.
                if status != 200 or clock.monotonic() >= deadline or clock.time() >= reject_by:
                    raise AcceptanceError()
                clock.sleep(min(EXPIRY_POLL_INTERVAL, deadline - clock.monotonic()))
        return {
            "status": "pass",
            "identity": IDENTITY,
            "expires_at": expires,
            "canary": True,
            "protected_denied": True,
            "openbao_issuance_denied": True,
            "expired": wait_expiry,
        }
    except Exception as error:  # noqa: BLE001 -- Retain only fixed step and numeric HTTP status.
        status = error.http_status if isinstance(error, AcceptanceError) else None
        failure = AcceptanceError(step=step, http_status=status)
        raise failure from None
    finally:
        if session:
            try:
                bao.revoke(session)
            except Exception:  # noqa: BLE001 -- Preserve the original failure before cleanup.
                if failure is None:
                    raise AcceptanceError(step="revoke") from None
                failure.session_cleanup_failed = True


def sustained_acceptance(bao, kube, clock):
    """Issue again after the initial credential's real expiry/rotation window."""
    initial = acceptance(bao, kube, clock)
    after_rotation = acceptance(bao, kube, clock, wait_expiry=False)
    return {"initial": initial, "after_rotation": after_rotation}


def issuer_boundary(issuer, clock, suffix, *, owner=None):
    """Exercise named subresource RBAC using the actual issuer Pod identity."""
    payload = {
        "apiVersion": "authentication.k8s.io/v1",
        "kind": "TokenRequest",
        "spec": {"audiences": [AUDIENCE], "expirationSeconds": 600},
    }
    path = f"/api/v1/namespaces/{NAMESPACE}/serviceaccounts/"
    body = call(issuer, "POST", path + ACCOUNT + "/token", {201}, payload=payload)
    try:
        token = body["status"]["token"]
        expires = token_claims(token, clock)
        timestamp = datetime.fromisoformat(body["status"]["expirationTimestamp"])
        if timestamp.timestamp() != expires:
            raise AcceptanceError()
        prove_identity(issuer, token)
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        raise AcceptanceError() from None
    for namespace, account in [
        (NAMESPACE, "openbao-unapproved"),
        ("openbao-acceptance-wrong", ACCOUNT),
    ]:
        call(
            issuer,
            "POST",
            f"/api/v1/namespaces/{namespace}/serviceaccounts/{account}/token",
            {403},
            payload=payload,
        )
    # These objects cannot confer permissions even if an overbroad issuer creates them.
    name = "openbao-zero-" + suffix
    metadata = {
        "name": name,
        "namespace": NAMESPACE,
        "annotations": {"homelab.supermorphic.com/test-run": owner or suffix},
    }
    mutations = [
        (
            f"/api/v1/namespaces/{NAMESPACE}/serviceaccounts",
            {
                "apiVersion": "v1",
                "kind": "ServiceAccount",
                "metadata": metadata,
                "automountServiceAccountToken": False,
            },
        ),
        (
            f"/apis/rbac.authorization.k8s.io/v1/namespaces/{NAMESPACE}/roles",
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "Role",
                "metadata": metadata,
                "rules": [],
            },
        ),
        (
            f"/apis/rbac.authorization.k8s.io/v1/namespaces/{NAMESPACE}/rolebindings",
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "RoleBinding",
                "metadata": metadata,
                "subjects": [],
                "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": name},
            },
        ),
    ]
    for target, value in mutations:
        call(issuer, "POST", target, {403}, payload=value)
    call(
        issuer,
        "POST",
        "/apis/authentication.k8s.io/v1/selfsubjectreviews",
        {403},
        payload={"apiVersion": "authentication.k8s.io/v1", "kind": "SelfSubjectReview"},
        headers={"Impersonate-User": f"system:serviceaccount:{NAMESPACE}:openbao-unapproved"},
    )
    return {
        "status": "pass",
        "identity": IDENTITY,
        "expires_at": expires,
        "named_tokenrequest": True,
        "boundary_denied": True,
    }
