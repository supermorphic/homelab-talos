"""Emit the scoped fixture policy from reviewed Pod templates and bounded inputs."""

import json

import yaml

from scripts.test.news import cluster_recovery as fixture

TARGET = fixture.ROOT / "kubernetes/apps/kube-system/agent-access/app/news-recovery-admission.yaml"


def literal(value):
    if isinstance(value, dict):
        return (
            "{"
            + ",".join(json.dumps(k) + ":dyn(" + literal(v) + ")" for k, v in value.items())
            + "}"
        )
    if isinstance(value, list):
        return "[" + ",".join("dyn(" + literal(v) + ")" for v in value) + "]"
    if isinstance(value, str) and value.startswith("news-drill-000000000000"):
        return (
            "('news-drill-' + variables.run + "
            + json.dumps(value.removeprefix("news-drill-000000000000"))
            + ")"
        )
    if value == "set-1234567890-ABC123":
        return "variables.selected"
    if value == "node-avoid-placeholder":
        return "variables.avoidNode"
    return json.dumps(value)


def policy(name, resources, operations, variables, validations):
    return [
        {
            "apiVersion": "admissionregistration.k8s.io/v1",
            "kind": "ValidatingAdmissionPolicy",
            "metadata": {"name": name},
            "spec": {
                "failurePolicy": "Fail",
                "matchConstraints": {
                    "resourceRules": [
                        {
                            "apiGroups": [""],
                            "apiVersions": ["v1"],
                            "operations": operations,
                            "resources": resources,
                        }
                    ]
                },
                "matchConditions": [
                    {
                        "name": "test-runner",
                        "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-runner'",
                    }
                ],
                "variables": [
                    {"name": key, "expression": value} for key, value in variables.items()
                ],
                "validations": [
                    {"expression": expression, "message": message}
                    for expression, message in validations
                ],
            },
        },
        {
            "apiVersion": "admissionregistration.k8s.io/v1",
            "kind": "ValidatingAdmissionPolicyBinding",
            "metadata": {"name": name},
            "spec": {
                "policyName": name,
                "validationActions": ["Deny"],
                "matchResources": {
                    "namespaceSelector": {
                        "matchLabels": {"kubernetes.io/metadata.name": fixture.NAMESPACE}
                    }
                },
            },
        },
    ]


def documents():
    owner = {
        "item": "request.operation == 'DELETE' ? oldObject : object",
        "run": "variables.item.metadata.labels['homelab-talos/run-id']",
        "prefix": "'news-drill-' + variables.run",
    }
    metadata = """request.namespace == 'news-recovery-test' && request.operation != 'UPDATE' &&
      variables.run.matches('^[0-9a-f]{12}$') && variables.item.metadata.namespace == request.namespace &&
      variables.item.metadata.labels == {'homelab-talos/run-id': dyn(variables.run), 'homelab-talos/test': dyn('news-restore-drill')} &&
      !has(variables.item.metadata.ownerReferences) &&
      (!has(variables.item.metadata.finalizers) || variables.item.metadata.finalizers.size() == 0 ||
       (variables.item.kind == 'PersistentVolumeClaim' && variables.item.metadata.finalizers == ['kubernetes.io/pvc-protection'])) &&
      (request.operation == 'DELETE' || !has(variables.item.metadata.annotations)) &&
      (request.operation != 'DELETE' || (has(variables.item.metadata.uid) && variables.item.metadata.uid != ''))"""
    templates = {
        phase: fixture.pod(
            "000000000000", phase, "" if phase == "source" else "set-1234567890-ABC123"
        )["spec"]
        for phase in ("source", "restored")
    }
    templates["reattached"] = fixture.pod(
        "000000000000", "reattached", avoid_node="node-avoid-placeholder"
    )["spec"]
    pod_variables = {
        **owner,
        "restored": "variables.item.metadata.name == variables.prefix + '-restored'",
        "reattached": "variables.item.metadata.name == variables.prefix + '-reattached'",
        "pod": "variables.item.spec",
        "avoidNode": "variables.reattached ? variables.pod.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchFields[0].values[0] : ''",
        "selectionEnv": "variables.pod.containers[2].env.filter(e, e.name == 'NEWS_SELECTED_SET')[0]",
        "selected": "has(variables.selectionEnv.value) ? variables.selectionEnv.value : ''",
        "expected": "variables.restored ? "
        + literal(templates["restored"])
        + " : variables.reattached ? "
        + literal(templates["reattached"])
        + " : "
        + literal(templates["source"]),
        "defaults": literal(
            {
                "dnsPolicy": "ClusterFirst",
                "schedulerName": "default-scheduler",
                "serviceAccountName": "default",
                "serviceAccount": "default",
                "hostNetwork": False,
                "hostPID": False,
                "hostIPC": False,
                "priority": 0,
                "preemptionPolicy": "PreemptLowerPriority",
            }
        ),
        "containerDefaults": literal(
            {
                "terminationMessagePath": "/dev/termination-log",
                "terminationMessagePolicy": "File",
                "stdin": False,
                "stdinOnce": False,
                "tty": False,
            }
        ),
    }
    pods = policy(
        "homelab-test-news-pods",
        ["pods"],
        ["CREATE", "UPDATE", "DELETE"],
        pod_variables,
        [
            (
                metadata
                + " && variables.item.metadata.name in [variables.prefix + '-source', variables.prefix + '-reattached', variables.prefix + '-restored']",
                "Only run-owned synthetic news Pods may be created or deleted.",
            ),
            (
                "(variables.restored ? variables.selected.matches('^set-[0-9]{10}-[A-Za-z0-9]{6}$') : variables.selected == '')",
                "The selected paired set must have a bounded directory name.",
            ),
            (
                "!variables.reattached || (variables.avoidNode.size() <= 253 && variables.avoidNode.matches('^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'))",
                "Reattachment must exclude one bounded previous node name.",
            ),
            (
                """variables.expected.all(k, k in variables.pod && (k in ['containers','volumes'] || variables.pod[k] == variables.expected[k])) &&
          variables.pod.all(k, k in variables.expected || (k in variables.defaults && variables.pod[k] == variables.defaults[k]) ||
           (k == 'nodeName' && request.operation == 'DELETE') ||
           (k == 'tolerations' ? variables.pod[k].all(t, t.key in ['node.kubernetes.io/not-ready','node.kubernetes.io/unreachable'] &&
             t.operator == 'Exists' && t.effect == 'NoExecute' && t.tolerationSeconds == 300 &&
             t.all(f, f in ['key','operator','effect','tolerationSeconds'])) : false))""",
                "Synthetic news Pods cannot change identity, storage, security, scheduling, or lifetime.",
            ),
            (
                """variables.pod.containers.size() == 3 && [0,1,2].all(i,
          variables.expected.containers[i].all(k, k in variables.pod.containers[i] && variables.pod.containers[i][k] == variables.expected.containers[i][k]) &&
          variables.pod.containers[i].all(k, k in variables.expected.containers[i] ||
            (k in variables.containerDefaults && variables.pod.containers[i][k] == variables.containerDefaults[k]))) &&
          variables.pod.volumes == variables.expected.volumes""",
                "Images, commands, credentials and mounts are limited to the isolated fixture.",
            ),
        ],
    )
    names = [
        fixture.prefix("000000000000") + "-" + key
        for key in ("source-db", "source-data", "backups", "restored-db", "restored-data")
    ]
    inputs = policy(
        "homelab-test-news-inputs",
        ["persistentvolumeclaims", "secrets", "configmaps"],
        ["CREATE", "UPDATE", "DELETE"],
        owner,
        [
            (metadata, "Only immutable run-owned synthetic recovery inputs are allowed."),
            (
                """variables.item.kind != 'PersistentVolumeClaim' ||
          (variables.item.metadata.name in """
                + literal(names)
                + """ &&
           variables.item.spec.storageClassName == 'longhorn' && variables.item.spec.accessModes == ['ReadWriteOnce'] &&
           variables.item.spec.resources.requests == {'storage':'1Gi'} &&
           variables.item.spec.resources.all(k, k == 'requests') && variables.item.spec.all(k,
            k in ['storageClassName','accessModes','resources'] || (k == 'volumeMode' && variables.item.spec[k] == 'Filesystem') ||
            (k == 'volumeName' && request.operation == 'DELETE')))""",
                "Claims must be fresh bounded Longhorn filesystem claims, without adoption or clone sources.",
            ),
            (
                """variables.item.kind != 'Secret' || (variables.item.metadata.name == variables.prefix + '-credentials' &&
          variables.item.type == 'Opaque' && variables.item.immutable && !has(variables.item.binaryData) &&
          ((has(variables.item.stringData) && !has(variables.item.data) && variables.item.stringData.size() == 6 &&
            variables.item.stringData.all(k, k in ['postgres-password','db-password','backup-password','monitoring-password','operator-password','api-password'] &&
              variables.item.stringData[k].matches('^[a-f0-9]{48}$'))) ||
           (has(variables.item.data) && !has(variables.item.stringData) && variables.item.data.size() == 6 &&
            variables.item.data.all(k, k in ['postgres-password','db-password','backup-password','monitoring-password','operator-password','api-password'] &&
              variables.item.data[k].matches('^[A-Za-z0-9+/]{64}$')))))""",
                "The ephemeral Secret has only the six synthetic fixture passwords.",
            ),
            (
                """variables.item.kind != 'ConfigMap' || (variables.item.metadata.name == variables.prefix + '-scripts' &&
          variables.item.immutable && !has(variables.item.binaryData) && variables.item.data.size() == """
                + str(len(fixture.config_data()))
                + " && variables.item.data.all(k, k in "
                + json.dumps(list(fixture.config_data()))
                + " && variables.item.data[k].size() <= 65536))",
                "Fixture programs are bounded public input in the isolated namespace.",
            ),
        ],
    )
    execute = policy(
        "homelab-test-news-exec",
        ["pods/exec"],
        ["CONNECT"],
        {},
        [
            (
                """request.namespace == 'news-recovery-test' && request.name.matches('^news-drill-[0-9a-f]{12}-(source|reattached|restored)$') &&
          ((object.container == 'app' && object.command == ['php','/opt/news/drill.php',request.name.endsWith('-source') ? 'source' : request.name.endsWith('-reattached') ? 'reattached' : 'restored']) ||
           (request.name.endsWith('-source') &&
            ((object.container == 'app' && object.command == ['php','/opt/news/drill.php','unavailable']) ||
             (object.container == 'database' && object.command == ['pg_ctl','--pgdata=/var/lib/postgresql/data/pgdata','--mode=fast','--no-wait','stop']) ||
             (object.container == 'helper' && object.command in [['sh','/opt/news/drill-helper.sh','capture'],['sh','/opt/news/drill-helper.sh','captured']])))) &&
          (!has(object.tty) || !object.tty) && object.stdout && object.stderr &&
          (request.name.endsWith('-source') ? (!has(object.stdin) || !object.stdin) : object.stdin)""",
                "Only non-interactive fixture phase commands may execute.",
            ),
        ],
    )
    return pods + inputs + execute


if __name__ == "__main__":
    TARGET.write_text(yaml.safe_dump_all(documents(), sort_keys=False))
