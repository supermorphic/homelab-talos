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
