"""Operator-only retained discovery installation and bounded n8n enrollment."""

from __future__ import annotations

import http.client
import json
import os
import re
import secrets
import ssl
import sys
import uuid
from pathlib import Path

from automation_data_access import safe_path
from automation_data_client import PrivateFileError, fsync_directory, write_private_file_exclusive

SOURCES = {
    "platform": (
        "automation-data",
        "automation-data-postgresql",
        "automation_data_control",
        "automation_data_inventory",
        "Automation Data Inventory Reader",
    ),
    "nocodb": (
        "automation-data",
        "automation-data-postgresql",
        "nocodb",
        "nocodb_inventory",
        "NocoDB Inventory Reader",
    ),
    "n8n": ("automation", "n8n-postgresql", "n8n", "n8n_inventory", "n8n Inventory Reader"),
    "header": (None, None, None, None, "Automation Data Inventory Header"),
}
ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (
    ROOT / "kubernetes/apps/automation/n8n/app/workflows/automation-data-credential-inventory.json"
)


def state(root: Path) -> dict:
    path = safe_path(root / "pending" / "operation.json")
    if path.stat().st_size > 16384:
        raise PrivateFileError("installation_state_invalid")
    data = json.loads(path.read_text())
    if (
        not isinstance(data, dict)
        or set(data)
        != {
            "schemaVersion",
            "operationId",
            "credentials",
            "creating",
            "workflowId",
            "workflowCreating",
            "complete",
        }
        or data["schemaVersion"] != 1
        or not re.fullmatch("[a-f0-9]{32}", str(data["operationId"]))
        or not isinstance(data["credentials"], dict)
        or set(data["credentials"]) - set(SOURCES)
        or any(
            not isinstance(v, str) or not re.fullmatch("[A-Za-z0-9_-]{1,128}", v)
            for v in data["credentials"].values()
        )
        or data["creating"] not in [None, *SOURCES]
        or type(data["workflowCreating"]) is not bool
        or type(data["complete"]) is not bool
        or (
            data["workflowId"] is not None
            and not re.fullmatch("[A-Za-z0-9_-]{1,128}", str(data["workflowId"]))
        )
    ):
        raise PrivateFileError("installation_state_invalid")
    return data


def save_state(root: Path, data: dict) -> None:
    directory = safe_path(root / "pending", directory=True)
    path = directory / "operation.json"
    if path.exists() or path.is_symlink():
        safe_path(path)
    temporary = directory / f".state-{uuid.uuid4().hex}"
    write_private_file_exclusive(temporary, (json.dumps(data, sort_keys=True) + "\n").encode())
    os.replace(temporary, path)
    fsync_directory(directory)


def candidate(root: Path, source: str) -> str:
    path = safe_path(root / "pending" / f"{source}.candidate")
    if path.stat().st_size > 128:
        raise PrivateFileError("installation_candidate_invalid")
    value = path.read_text().strip()
    if not re.fullmatch("[A-Za-z0-9_-]{48}", value):
        raise PrivateFileError("installation_candidate_invalid")
    return value


def prepare(root: Path) -> dict:
    safe_path(root, directory=True)
    pending = root / "pending"
    if not pending.exists() and not pending.is_symlink():
        pending.mkdir(mode=0o700)
    safe_path(pending, directory=True)
    receipt = pending / "operation.json"
    if receipt.exists() or receipt.is_symlink():
        data = state(root)
    else:
        if any(pending.iterdir()):
            raise PrivateFileError("ambiguous_installation")
        data = {
            "schemaVersion": 1,
            "operationId": uuid.uuid4().hex,
            "credentials": {},
            "creating": None,
            "workflowId": None,
            "workflowCreating": False,
            "complete": False,
        }
        save_state(root, data)
    for source in SOURCES:
        path = pending / f"{source}.candidate"
        if not path.exists() and not path.is_symlink():
            if data["credentials"] or data["creating"] or data["workflowId"]:
                raise PrivateFileError("missing_retained_candidate")
            write_private_file_exclusive(path, secrets.token_urlsafe(36).encode())
        candidate(root, source)
    return data


def make_job(source: str, name: str, run: str, configmap: str, candidates: str) -> dict:
    namespace, host, database, reader, _ = SOURCES[source]
    if source == "header" or any(
        not re.fullmatch("[a-z0-9-]{1,63}", v) for v in (name, run, configmap, candidates)
    ):
        raise ValueError("invalid_installation_target")
    labels = {
        "app.kubernetes.io/name": host + "-backup",
        "homelab-talos/run-id": run,
        "homelab-talos/role": "credential-discovery-install",
    }
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "namespace": namespace, "labels": labels},
        "spec": {
            "activeDeadlineSeconds": 120,
            "backoffLimit": 0,
            "template": {
                "metadata": {"labels": labels},
                "spec": {
                    "automountServiceAccountToken": False,
                    "restartPolicy": "Never",
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 70,
                        "runAsGroup": 70,
                        "fsGroup": 70,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [
                        {
                            "name": "install-discovery",
                            "image": "postgres:17.11-alpine3.24",
                            "imagePullPolicy": "IfNotPresent",
                            "command": ["/bin/sh"],
                            "args": ["/scripts/install-reader.sh"],
                            "env": [
                                {
                                    "name": "PGPASSWORD",
                                    "valueFrom": {
                                        "secretKeyRef": {
                                            "name": "postgresql-credentials",
                                            "key": "postgres-superuser-password",
                                        }
                                    },
                                },
                                *(
                                    {"name": k, "value": v}
                                    for k, v in {
                                        "PGHOST": host,
                                        "PGDATABASE": database,
                                        "PGUSER": "postgres",
                                        "PGPORT": "5432",
                                        "PGCONNECT_TIMEOUT": "5",
                                        "DISCOVERY_READER": reader,
                                        "DISCOVERY_SOURCE": source,
                                    }.items()
                                ),
                            ],
                            "resources": {
                                "requests": {"cpu": "10m", "memory": "32Mi"},
                                "limits": {"memory": "128Mi"},
                            },
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "capabilities": {"drop": ["ALL"]},
                                "readOnlyRootFilesystem": True,
                            },
                            "volumeMounts": [
                                {"name": "scripts", "mountPath": "/scripts", "readOnly": True},
                                {
                                    "name": "candidates",
                                    "mountPath": "/candidates",
                                    "readOnly": True,
                                },
                                {"name": "tmp", "mountPath": "/tmp"},
                            ],
                        }
                    ],
                    "volumes": [
                        {"name": "scripts", "configMap": {"name": configmap}},
                        {
                            "name": "candidates",
                            "secret": {"secretName": candidates, "defaultMode": 0o440},
                        },
                        {"name": "tmp", "emptyDir": {"medium": "Memory"}},
                    ],
                },
            },
        },
    }


class N8nEnrollment:
    def __init__(self, root: Path, guard):
        self.root = root
        self.guard = guard
        path = safe_path(root / "n8n-api-key")
        if path.stat().st_size > 4096:
            raise PrivateFileError("n8n_enrollment_auth_invalid")
        self.token = path.read_text().strip()
        if not self.token or any(c in self.token for c in "\r\n"):
            raise PrivateFileError("n8n_enrollment_auth_invalid")

    def request(self, method: str, path: str, body=None):
        connection = http.client.HTTPSConnection(
            "n8n.lab.supermorphic.com", timeout=10, context=ssl.create_default_context()
        )
        try:
            if method != "GET":
                self.guard()
            connection.request(
                method,
                "/api/v1/" + path,
                None if body is None else json.dumps(body).encode(),
                {"X-N8N-API-KEY": self.token, "Content-Type": "application/json"},
            )
            response = connection.getresponse()
            raw = response.read(1024 * 1024 + 1)
            if not 200 <= response.status < 300 or len(raw) > 1024 * 1024:
                raise PrivateFileError("n8n_enrollment_request_failed")
            return json.loads(raw)
        except Exception:  # noqa: BLE001 - credential responses never become diagnostics
            raise PrivateFileError("n8n_enrollment_request_failed") from None
        finally:
            connection.close()

    def names(self):
        from urllib.parse import quote

        found = []
        cursor = None
        seen = set()
        for _ in range(10):
            page = self.request(
                "GET",
                "credentials?limit=100"
                + ("" if cursor is None else "&cursor=" + quote(cursor, safe="")),
            )
            if not isinstance(page, dict) or not isinstance(page.get("data"), list):
                raise PrivateFileError("n8n_inventory_invalid")
            for item in page["data"]:
                if not isinstance(item, dict):
                    raise PrivateFileError("n8n_inventory_invalid")
                if item.get("name") in {entry[4] for entry in SOURCES.values()}:
                    found.append({k: item.get(k) for k in ("id", "name", "type")})
            cursor = page.get("nextCursor")
            if cursor is None:
                return found
            if not isinstance(cursor, str) or len(cursor) > 1024 or cursor in seen:
                raise PrivateFileError("n8n_inventory_invalid")
            seen.add(cursor)
        raise PrivateFileError("n8n_inventory_limit")

    def enroll(self, source: str):
        data = state(self.root)
        if data["creating"] is not None:
            raise PrivateFileError("ambiguous_credential_creation")
        matches = [item for item in self.names() if item["name"] == SOURCES[source][4]]
        kind = "httpHeaderAuth" if source == "header" else "postgres"
        retained = data["credentials"].get(source)
        if retained is not None:
            if len(matches) != 1 or matches[0]["id"] != retained or matches[0]["type"] != kind:
                raise PrivateFileError("credential_binding_mismatch")
            return
        if matches:
            raise PrivateFileError("unrelated_credential_collision")
        if source == "header":
            body = {"name": "X-Automation-Data-Inventory", "value": candidate(self.root, source)}
        else:
            _, host, database, reader, _ = SOURCES[source]
            body = {
                "host": host
                + (
                    ".automation-data.svc.cluster.local"
                    if source != "n8n"
                    else ".automation.svc.cluster.local"
                ),
                "database": database,
                "user": reader,
                "password": candidate(self.root, source),
                "port": 5432,
                "ssl": "disable",
            }
        data["creating"] = source
        save_state(self.root, data)
        result = self.request(
            "POST", "credentials", {"name": SOURCES[source][4], "type": kind, "data": body}
        )
        identity = result.get("id") if isinstance(result, dict) else None
        if (
            not isinstance(identity, str)
            or not re.fullmatch("[A-Za-z0-9_-]{1,128}", identity)
            or result.get("name") != SOURCES[source][4]
            or result.get("type") != kind
        ):
            raise PrivateFileError("ambiguous_credential_creation")
        data["credentials"][source] = identity
        data["creating"] = None
        save_state(self.root, data)

    def workflow(self):
        data = state(self.root)
        if (
            set(data["credentials"]) != set(SOURCES)
            or data["creating"]
            or data["workflowCreating"]
        ):
            raise PrivateFileError("incomplete_enrollment")
        template = json.loads(WORKFLOW.read_text())
        for node in template["nodes"]:
            for binding in node.get("credentials", {}).values():
                source = next(s for s, entry in SOURCES.items() if entry[4] == binding["name"])
                binding["id"] = data["credentials"][source]
        body = {key: template[key] for key in ("name", "nodes", "connections", "settings")}
        if data["workflowId"] is None:
            page = self.request("GET", "workflows?limit=100")
            if (
                not isinstance(page, dict)
                or not isinstance(page.get("data"), list)
                or page.get("nextCursor") is not None
                or any(w.get("name") == template["name"] for w in page["data"])
            ):
                raise PrivateFileError("ambiguous_inventory_workflow")
            data["workflowCreating"] = True
            save_state(self.root, data)
            result = self.request("POST", "workflows", body)
            identity = result.get("id") if isinstance(result, dict) else None
            if not isinstance(identity, str) or not re.fullmatch("[A-Za-z0-9_-]{1,128}", identity):
                raise PrivateFileError("ambiguous_inventory_workflow")
            data["workflowId"] = identity
            data["workflowCreating"] = False
            save_state(self.root, data)
        current = self.request("GET", "workflows/" + data["workflowId"])
        if (
            not isinstance(current, dict)
            or current.get("name") != template["name"]
            or current.get("nodes") != template["nodes"]
            or current.get("connections") != template["connections"]
            or any(
                current.get("settings", {}).get(k) != v for k, v in template["settings"].items()
            )
        ):
            raise PrivateFileError("inventory_workflow_drift")
        if current.get("active") is not True:
            self.request("POST", "workflows/" + data["workflowId"] + "/publish", {})


def finalize(root: Path):
    from automation_data_access import fetch_observations, load_access_config
    from automation_data_inventory import DiscoveryRequest

    data = state(root)
    if (
        not data["workflowId"]
        or set(data["credentials"]) != set(SOURCES)
        or data["creating"]
        or data["workflowCreating"]
    ):
        raise PrivateFileError("incomplete_enrollment")
    auth = root / "inventory-auth"
    material = candidate(root, "header").encode()
    if auth.exists() or auth.is_symlink():
        if safe_path(auth).read_bytes() != material:
            raise PrivateFileError("inventory_auth_collision")
    else:
        write_private_file_exclusive(auth, material)
    config = safe_path(root / "access.json")
    raw = json.loads(config.read_text())
    if raw.get("inventoryAuthFile") != str(auth):
        raise PrivateFileError("inventory_auth_location_mismatch")
    expected = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    if config != Path(expected) / "homelab" / "automation-data" / "access.json":
        raise PrivateFileError("inventory_access_location_mismatch")
    observed = fetch_observations(load_access_config(), DiscoveryRequest())
    if not all(item.complete for item in observed):
        raise PrivateFileError("inventory_acceptance_incomplete")
    n8n = next(item for item in observed if item.source == "n8n")
    for source, identity in data["credentials"].items():
        matches = [
            item for item in n8n.objects if item["kind"] == "credential" and item["id"] == identity
        ]
        if (
            len(matches) != 1
            or matches[0].get("name") != SOURCES[source][4]
            or matches[0].get("type") != ("httpHeaderAuth" if source == "header" else "postgres")
        ):
            raise PrivateFileError("inventory_credential_binding_mismatch")
    workflows = [
        item
        for item in n8n.objects
        if item["kind"] == "workflow" and item["id"] == data["workflowId"]
    ]
    bindings = {
        item.get("credentialId")
        for item in n8n.objects
        if item["kind"] == "binding"
        and item.get("workflowId") == data["workflowId"]
        and item.get("published") is True
    }
    if (
        len(workflows) != 1
        or workflows[0].get("published") is not True
        or not set(data["credentials"].values()) - {data["credentials"]["header"]} <= bindings
    ):
        raise PrivateFileError("inventory_workflow_binding_mismatch")
    data["complete"] = True
    save_state(root, data)


def main(argv):
    import subprocess

    try:
        command = argv[0]
        root = Path(os.environ["AUTOMATION_DATA_DISCOVERY_INSTALL_DIRECTORY"])
        if command == "prepare":
            prepare(root)
        elif command == "manifest":
            print(json.dumps(make_job(*argv[1:])))
        elif command in {"enroll", "workflow"}:
            kubeconfig, run = argv[-2:]

            def guard():
                subprocess.run(
                    [
                        "bash",
                        str(ROOT / "scripts/operations/automation-data-discovery-install.sh"),
                        kubeconfig,
                        "guard",
                        run,
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

            client = N8nEnrollment(root, guard)
            if command == "enroll":
                client.enroll(argv[1])
            else:
                client.workflow()
        elif command == "finalize":
            finalize(root)
        elif command == "report":
            from automation_data_inventory import SCHEMA_REVISIONS

            data = state(root)
            if data["complete"] is not True:
                raise PrivateFileError("incomplete_enrollment")
            print(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "status": "complete",
                        "schemaRevisions": SCHEMA_REVISIONS,
                        "credentialIds": data["credentials"],
                        "workflowId": data["workflowId"],
                    },
                    sort_keys=True,
                )
            )
        else:
            raise ValueError("invalid_arguments")
        return 0
    except Exception:  # noqa: BLE001 - no credentials or internal exceptions in output
        print(
            "Discovery installation stopped; retain protected pending evidence for attended recovery.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
