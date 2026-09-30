"""Stable issuer source and bounded evidence; never return issuer credential bytes."""

import copy
import json

import yaml

from . import guards, issuance

CLAIMS_PROBE = """
import base64, json, sys
from pathlib import Path
try:
    token = Path('/identity/token').read_text().strip()
    part = token.split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
    valid = ('exp' not in claims
             and claims.get('sub') == 'system:serviceaccount:openbao:openbao'
             and claims.get('kubernetes.io/serviceaccount/secret.name') == sys.argv[1])
    print(json.dumps({'stable_issuer': valid}))
except Exception:
    print(json.dumps({'stable_issuer': False}))
"""


def volume():
    values = yaml.safe_load((guards.PACKAGE / "app/values.yaml").read_bytes())
    return copy.deepcopy(next(v for v in values["server"]["volumes"] if v["name"] == "kubernetes-api-token"))


def verify_identity(probe):
    probe.scope.check()
    probe.scope.assert_owned(probe.pod)
    name = volume()["projected"]["sources"][0]["secret"]["name"]
    metadata = probe.pod["metadata"]
    raw = probe.scope.command("-n", metadata["namespace"], "exec", metadata["name"],
                              "-c", "probe", "--", "python", "-c", CLAIMS_PROBE, name)
    if json.loads(raw) != {"stable_issuer": True}:
        raise issuance.AcceptanceError()
    response = issuance.call(probe, "POST", "/apis/authentication.k8s.io/v1/selfsubjectreviews",
                             {201}, payload={"apiVersion": "authentication.k8s.io/v1",
                                             "kind": "SelfSubjectReview"})
    if response.get("status", {}).get("userInfo", {}).get("username") != "system:serviceaccount:openbao:openbao":
        raise issuance.AcceptanceError()


def server_processes(scope):
    result = {}
    for name in ("openbao-0", "openbao-1", "openbao-2"):
        pod = scope.get({"kind": "Pod", "metadata": {"namespace": "openbao", "name": name}})
        current = next(v for v in pod["spec"]["volumes"] if v["name"] == "kubernetes-api-token")
        if current != volume():
            raise issuance.AcceptanceError()
        status = next(c for c in pod["status"]["containerStatuses"] if c["name"] == "openbao")
        if not status["ready"] or not status.get("state", {}).get("running"):
            raise issuance.AcceptanceError()
        result[name] = (pod["metadata"]["uid"], status["restartCount"], status["state"]["running"]["startedAt"])
    return result
