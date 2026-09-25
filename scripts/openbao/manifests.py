"""Independent safety invariants for the staged OpenBao package."""


def _get(document, *path):
    for key in path:
        if not isinstance(document, dict):
            return None
        document = document.get(key)
    return document


def validate_issuance_role(role: dict) -> list[str]:
    errors = []
    if role.get("kind") != "Role" or _get(role, "metadata", "namespace") != "openbao-acceptance":
        errors.append("tokenrequest-namespace")
    rules = role.get("rules", [])
    exact = {"apiGroups": [""], "resources": ["serviceaccounts/token"],
             "verbs": ["create"], "resourceNames": ["openbao-issued-reader"]}
    if any("secrets" in rule.get("resources", []) and
           set(rule.get("verbs", [])) & {"get", "list", "watch", "*"} for rule in rules):
        errors.append("secret-read-grant")
    if any("serviceaccounts/token" in rule.get("resources", []) and
           rule.get("resourceNames") != ["openbao-issued-reader"] for rule in rules):
        errors.append("unbounded-tokenrequest")
    if rules != [exact]:
        errors.append("tokenrequest-scope")
    return errors


def validate_gateway_namespace(namespace: dict) -> list[str]:
    if (namespace.get("kind") == "Namespace" and
            _get(namespace, "metadata", "name") == "openbao" and
            _get(namespace, "metadata", "labels", "gateway.supermorphic.com/access") == "internal"):
        return []
    return ["route-namespace"]


def validate_network_policy(policy: dict) -> list[str]:
    if any("fromEntities" in rule or "fromCIDR" in rule or "fromCIDRSet" in rule
           for rule in _get(policy, "spec", "ingress") or []):
        return ["broad-node-api-ingress"]
    return []


def validate_tokenrequest_binding(binding: dict) -> list[str]:
    if (binding.get("kind") == "RoleBinding" and
            _get(binding, "metadata", "namespace") == "openbao-acceptance" and
            binding.get("roleRef") == {"apiGroup": "rbac.authorization.k8s.io",
                                       "kind": "Role", "name": "openbao-tokenrequest"} and
            binding.get("subjects") == [{"kind": "ServiceAccount", "name": "openbao",
                                         "namespace": "openbao"}]):
        return []
    return ["tokenrequest-binding"]


def validate_flux_units(documents: list[dict]) -> list[str]:
    expected = {
        "openbao-prerequisites": "namespace",
        "openbao": "app",
        "openbao-access": "access",
        "openbao-acceptance": "acceptance",
    }
    units = [d for d in documents if d.get("kind") == "Kustomization" and
             (str(_get(d, "metadata", "name") or "").startswith("openbao") or
              str(_get(d, "spec", "path") or "").startswith(
                  "./kubernetes/apps/security/openbao/"))]
    if (len(units) == len(expected) and
            {_get(d, "metadata", "name") for d in units} == set(expected) and
            all(_get(d, "metadata", "namespace") == "flux-system" and
                _get(d, "spec", "suspend") is True and
                _get(d, "spec", "path") ==
                "./kubernetes/apps/security/openbao/" + expected[_get(d, "metadata", "name")]
                for d in units)):
        return []
    return ["flux-activation"]


def validate_documents(documents: list[dict]) -> list[str]:
    errors = []
    statefulsets = [d for d in documents if d.get("kind") == "StatefulSet" and
                    _get(d, "metadata", "name") == "openbao"]
    budgets = [d for d in documents if d.get("kind") == "PodDisruptionBudget" and
               _get(d, "metadata", "name") == "openbao"]
    if len(statefulsets) != 1:
        errors.append("server-statefulset")
    else:
        sts = statefulsets[0]
        if _get(sts, "spec", "replicas") != 3:
            errors.append("three-voters")
        terms = _get(sts, "spec", "template", "spec", "affinity", "podAntiAffinity",
                     "requiredDuringSchedulingIgnoredDuringExecution") or []
        selector = {"app.kubernetes.io/name": "openbao",
                    "app.kubernetes.io/instance": "openbao", "component": "server"}
        if not any(t.get("topologyKey") == "kubernetes.io/hostname" and
                   _get(t, "labelSelector", "matchLabels") == selector for t in terms):
            errors.append("voter-colocation")
        retention = _get(sts, "spec", "persistentVolumeClaimRetentionPolicy") or {}
        if retention.get("whenDeleted") != "Retain" or retention.get("whenScaled") != "Retain":
            errors.append("pvc-retention")
        if _get(sts, "spec", "podManagementPolicy") != "Parallel":
            errors.append("peer-startup")
        if _get(sts, "spec", "updateStrategy", "type") != "OnDelete":
            errors.append("unattended-upgrade")
    if len(budgets) != 1 or _get(budgets[0], "spec", "minAvailable") != 2:
        errors.append("pdb-quorum")
    elif _get(budgets[0], "spec", "selector", "matchLabels") != {
            "app.kubernetes.io/name": "openbao", "app.kubernetes.io/instance": "openbao",
            "component": "server"}:
        errors.append("pdb-selector")
    for document in documents:
        if document.get("kind") in ("Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding") and \
                _get(document, "metadata", "name") != "openbao-tokenrequest":
            # The official chart must not introduce discovery or authentication RBAC.
            errors.append("unexpected-chart-rbac")
        if document.get("kind") == "ClusterRoleBinding" and _get(document, "roleRef", "name") == "system:auth-delegator":
            errors.append("auth-delegator-binding")
        if document.get("kind") == "Role" and _get(document, "metadata", "name") == "openbao-tokenrequest":
            errors.extend(validate_issuance_role(document))
    return list(dict.fromkeys(errors))
