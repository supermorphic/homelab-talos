"""Attended production news acceptance with explicitly supplied credentials."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import secrets
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

from scripts.openbao.issuance import AUDIENCE
from scripts.test.news.extraction_corpus import assess, validate_corpus

ROOT = Path(__file__).resolve().parents[3]
RUN_LABEL = "homelab-talos/news-acceptance"
PHASE_LABEL = "homelab-talos/acceptance-phase"
GATE = "homelab.supermorphic.com/acceptance"


def fixture_metadata(run: str, phase: str) -> dict:
    if not re.fullmatch(r"[a-f0-9]{12}", run) or phase not in {"cold", "recovered"}:
        raise ValueError("invalid acceptance identity")
    return {
        "name": "news-acceptance-" + run + "-" + phase,
        "namespace": "news",
        "labels": {RUN_LABEL: run, PHASE_LABEL: phase},
    }


def worker_fixture(deployment: dict, run: str, phase: str) -> dict:
    metadata = fixture_metadata(run, phase)
    template = copy.deepcopy(deployment["spec"]["template"])
    spec = template["spec"]
    if (
        {RUN_LABEL, PHASE_LABEL} & template["metadata"]["labels"].keys()
        or any(spec.get(key) for key in ("hostNetwork", "hostPID", "hostIPC", "imagePullSecrets"))
        or spec.get("serviceAccountName", "default") != "default"
    ):
        raise ValueError("worker fixture must not inherit reserved identity or host access")
    if spec.get("automountServiceAccountToken") is not False or any(
        set(volume) - {"name", "configMap", "emptyDir"} for volume in spec.get("volumes", [])
    ):
        raise ValueError("worker fixture must not adopt credentials or persistent storage")
    for container in spec["initContainers"] + spec["containers"]:
        security = container.get("securityContext", {})
        if (
            security.get("runAsNonRoot") is not True
            or security.get("runAsUser") != 1000
            or security.get("readOnlyRootFilesystem") is not True
            or security.get("allowPrivilegeEscalation") is not False
            or security.get("privileged", False)
            or security.get("capabilities", {}).get("drop") != ["ALL"]
            or security.get("capabilities", {}).get("add")
        ):
            raise ValueError("worker fixture must keep restricted process permissions")
        if any("valueFrom" in env for env in container.get("env", [])):
            raise ValueError("worker fixture must not adopt external environment values")
    metadata["labels"].update(template["metadata"]["labels"])
    spec.update(
        restartPolicy="Never",
        activeDeadlineSeconds=420,
        readinessGates=[{"conditionType": GATE}],
    )
    return {"apiVersion": "v1", "kind": "Pod", "metadata": metadata, "spec": spec}


def cold_policy(run: str) -> dict:
    metadata = fixture_metadata(run, "cold")
    return {
        "apiVersion": "cilium.io/v2",
        "kind": "CiliumNetworkPolicy",
        "metadata": metadata,
        "spec": {
            "endpointSelector": {"matchLabels": metadata["labels"].copy()},
            "egressDeny": [{"toEntities": ["world"]}],
        },
    }


class Acceptance:
    def __init__(self, config: Path, directory: Path, private: Path):
        self.config, self.directory, self.private = config, directory, private
        self.run = hashlib.sha256(directory.name.encode()).hexdigest()[:12]
        self.kc = ["kubectl", "--kubeconfig", str(config), "--request-timeout=20s"]
        self.namespace_uid = ""
        self.ledger = private / "owned.jsonl"
        self.account_created = False
        self.credentials = {
            "user": "news583_" + self.run,
            "owner": secrets.token_hex(32),
            "password": secrets.token_hex(24),
            "api_password": secrets.token_hex(24),
        }
        self.release = json.loads(
            (ROOT / "kubernetes/apps/news/graby/app/release.json").read_text()
        )
        self.result = {
            "release_id": self.release["id"],
            "status": "failed",
            "cleanup": "not-required",
        }

    def call(self, args, *, data=None, timeout=60):
        result = subprocess.run(
            args, input=data, text=True, capture_output=True, timeout=timeout, check=False
        )
        if result.returncode:
            (self.private / "last-command-error.txt").write_text(
                (result.stdout + result.stderr)[-16000:]
            )
            raise RuntimeError("acceptance operation failed")
        return result.stdout

    def get(self, kind, name="", namespace="news"):
        args = [*self.kc, "-n", namespace, "get", kind]
        if name:
            args.append(name)
        return json.loads(self.call([*args, "-o", "json"]))

    def lease(self):
        holder = os.environ.get("TEST_CAMPAIGN_LEASE_HOLDER") or self.directory.name
        self.call(
            [
                "bash",
                "-e",
                "-c",
                'source scripts/lib/lease.sh; verify_test_lease_holder "$1" "$2"',
                "acceptance",
                str(self.config),
                holder,
            ]
        )

    def namespace(self):
        actual = self.get("namespace", "news")["metadata"]["uid"]
        if not self.namespace_uid:
            self.namespace_uid = actual
        if actual != self.namespace_uid:
            raise RuntimeError("news namespace changed")

    def preflight(self):
        self.lease()
        self.namespace()
        deployments = {d["metadata"]["name"]: d for d in self.get("deployments")["items"]}
        for name in ("freshrss", "news-graby"):
            obj = deployments[name]
            if (
                obj["status"].get("observedGeneration") != obj["metadata"]["generation"]
                or obj["status"].get("availableReplicas") != 1
            ):
                raise RuntimeError("production workload is unavailable")
        app = next(
            c
            for c in deployments["freshrss"]["spec"]["template"]["spec"]["containers"]
            if c["name"] == "freshrss"
        )
        if (
            next(e["value"] for e in app["env"] if e["name"] == "NEWS_EXTRACTION_REQUESTS_ENABLED")
            != "false"
        ):
            raise RuntimeError("acceptance requires requests disabled")
        if app["image"] != self.release["freshrss_image"]:
            raise RuntimeError("FreshRSS image differs from release")
        worker = deployments["news-graby"]
        for container in (
            worker["spec"]["template"]["spec"]["initContainers"]
            + worker["spec"]["template"]["spec"]["containers"]
        ):
            if container["image"] != self.release["image"]:
                raise RuntimeError("worker image differs from release")
        volume = next(
            v["configMap"]
            for v in worker["spec"]["template"]["spec"]["volumes"]
            if v["name"] == "code"
        )
        config = self.get("configmap", volume["name"])
        if config.get("immutable") is not True:
            raise RuntimeError("worker package must be immutable")
        mounted = {v["path"]: config["data"][v["key"]] for v in volume["items"]}
        if json.loads(mounted["release.json"]) != self.release or set(mounted) - {
            "release.json"
        } != set(self.release["files"]):
            raise RuntimeError("mounted worker release differs")
        if any(
            hashlib.sha256(mounted[p].encode()).hexdigest() != digest
            for p, digest in self.release["files"].items()
        ):
            raise RuntimeError("mounted worker integrity failed")
        return worker

    def owned(self, operation, obj):
        self.namespace()
        if operation == "create":
            self.preflight()
            script = 'source scripts/test/lib/owned-resources.sh; test_create_owned_stream "$1" kubectl --kubeconfig "$2" --namespace news'
            args = [str(self.ledger), str(self.config)]
            data = json.dumps(obj)
        else:
            script = 'source scripts/test/lib/owned-resources.sh; test_delete_owned "$1" "$3" news "$4" kubectl --kubeconfig "$2" --namespace news'
            args = [str(self.ledger), str(self.config), obj["kind"], obj["metadata"]["name"]]
            data = None
        self.call(["bash", "-e", "-c", script, "acceptance", *args], data=data, timeout=360)

    def recorded(self):
        return (
            [json.loads(line) for line in self.ledger.read_text().splitlines()]
            if self.ledger.exists()
            else []
        )

    def pod(self, phase):
        name = fixture_metadata(self.run, phase)["name"]
        record = next(
            r for r in self.recorded() if r["kind"] == "Pod" and r["metadata"]["name"] == name
        )
        obj = self.get("pod", name)
        if (
            obj["metadata"]["uid"] != record["metadata"]["uid"]
            or obj["metadata"]["labels"] != record["metadata"]["labels"]
        ):
            raise RuntimeError("fixture identity changed")
        if obj["spec"].get("readinessGates") != [{"conditionType": GATE}]:
            raise RuntimeError("fixture traffic gate changed")
        slices = self.get("endpointslices")["items"]
        if any(
            e.get("targetRef", {}).get("uid") == obj["metadata"]["uid"]
            and e.get("conditions", {}).get("ready") is not False
            for item in slices
            for e in item.get("endpoints", [])
        ):
            raise RuntimeError("fixture entered production service traffic")
        return obj

    def account(self, operation, **values):
        if operation == "delete":
            self.namespace()
        else:
            self.preflight()
        payload = {**self.credentials, "operation": operation, **values}
        program = (
            (Path(__file__).with_name("production-account.php")).read_text().removeprefix("<?php")
        )
        output = self.call(
            [
                *self.kc,
                "-n",
                "news",
                "exec",
                "-i",
                "deployment/freshrss",
                "-c",
                "freshrss",
                "--",
                "php",
                "-r",
                program,
            ],
            data=json.dumps(payload),
            timeout=180,
        )
        return json.loads(output)

    def private_json(self, name, value):
        path = self.private / name
        temporary = path.with_name(path.name + ".new")
        temporary.write_text(json.dumps(value, indent=2) + "\n")
        temporary.chmod(0o600)
        temporary.replace(path)

    def create_account(self):
        self.private_json(
            "account-creation-intent.json",
            {"user": self.credentials["user"], "owner": self.credentials["owner"]},
        )
        # An exec failure can lose the reply after FreshRSS has committed the account.
        self.account_created = True
        if self.account("create") != {"created": True}:
            raise RuntimeError("temporary account creation failed")

    def wait_pod(self, phase, *, initialized=False):
        deadline = time.monotonic() + 350
        while time.monotonic() < deadline:
            self.lease()
            pod = self.pod(phase)
            status = pod["status"]
            init = status.get("initContainerStatuses", [])
            if (
                initialized
                and init
                and "terminated" in init[0]["state"]
                and (
                    init[0]["state"]["terminated"]["exitCode"] != 0
                    or (
                        status.get("containerStatuses")
                        and all("running" in c["state"] for c in status["containerStatuses"])
                    )
                )
            ):
                return pod
            if not initialized and status.get("podIP") and init:
                return pod
            time.sleep(3)
        raise RuntimeError("worker fixture initialization deadline exceeded")

    def cleanup(self):
        failed = False
        if self.result.get("native_client_cleanup") == "pending":
            confirmation = self.private / "native-client-removed.json"
            try:
                removed = json.loads(confirmation.read_text()) if confirmation.exists() else {}
                if removed.get("run") == self.run and removed.get("removed") is True:
                    self.result["native_client_cleanup"] = "confirmed"
            except (OSError, ValueError):
                pass
        if self.account_created:
            if self.result.get("native_client_cleanup") == "pending":
                self.private_json(
                    "cleanup-required.json",
                    {
                        "reason": "Remove the temporary NetNewsWire account before server cleanup.",
                        "user": self.credentials["user"],
                        "confirmation": {"run": self.run, "removed": True},
                        "ownership_ledger": str(self.ledger),
                        "next_action": "After client removal, remove only this temporary account through FreshRSS account administration.",
                    },
                )
                failed = True
            else:
                try:
                    if self.account("delete") != {"deleted": True}:
                        raise RuntimeError("temporary account cleanup failed")
                    self.account_created = False
                    (self.private / "fixture-credentials.json").unlink(missing_ok=True)
                    (self.private / "cleanup-required.json").unlink(missing_ok=True)
                except Exception:  # noqa: BLE001 -- Complete every owned cleanup without exposing adapter errors.
                    self.private_json(
                        "cleanup-required.json",
                        {
                            "reason": "Account ownership or deletion could not be reconciled.",
                            "user": self.credentials["user"],
                            "creation_intent": "account-creation-intent.json",
                            "next_action": "Inspect the private ownership evidence before removing this temporary account through FreshRSS account administration.",
                        },
                    )
                    failed = True
        for record in reversed(self.recorded()):
            try:
                self.owned("delete", record)
            except Exception:  # noqa: BLE001 -- One cleanup failure must not strand other owned resources.
                failed = True
        self.result["cleanup"] = "failed" if failed else "passed"
        return not failed


def selected_cases(manifest):
    eligible = [
        c
        for c in manifest["cases"]
        if c["expected"] == "accepted" and c["capture_kind"] == "public_article"
    ]
    selected = []
    predicates = (
        lambda c: (urlsplit(c["url"]).hostname or "").removeprefix("www.") == "wired.com",
        lambda c: (urlsplit(c["url"]).hostname or "").removeprefix("www.") == "arstechnica.com",
        lambda c: any(b["tag"] == "th" for b in c["reference"]["blocks"]),
        lambda c: any(b["tag"] == "li" for b in c["reference"]["blocks"]),
        lambda c: (
            len(c["reference"]["images"]) >= 3
            and len(c["reference"]["captions"]) >= 3
            and not any(b["tag"] == "li" for b in c["reference"]["blocks"])
        ),
    )
    for predicate in predicates:
        case = next(c for c in eligible if predicate(c))
        if case["url"] not in {c["url"] for c in selected}:
            selected.append(case)
    return selected


def network_observations(client):
    program = r"""
$checks=[];$targets=['public'=>['example.com',443],'database'=>['news-postgresql.news.svc.cluster.local',5432]];
if($argv[1]==='worker')$targets['api']=[getenv('KUBERNETES_SERVICE_HOST'),(int)getenv('KUBERNETES_SERVICE_PORT_HTTPS')];
foreach($targets as $name=>[$host,$port]){$start=microtime(true);$socket=@stream_socket_client('tcp://'.$host.':'.$port,$errno,$error,1);$checks[$name]=['connected'=>$socket!==false,'seconds'=>microtime(true)-$start];if($socket!==false)fclose($socket);}
echo json_encode($checks,JSON_THROW_ON_ERROR);
"""
    values = {}
    for deployment, container, binary in (
        ("freshrss", "freshrss", "php"),
        ("news-graby", "worker", "/usr/bin/php8.4"),
    ):
        values[container] = json.loads(
            client.call(
                [
                    *client.kc,
                    "-n",
                    "news",
                    "exec",
                    "deployment/" + deployment,
                    "-c",
                    container,
                    "--",
                    binary,
                    "-r",
                    program,
                    container,
                ],
                timeout=30,
            )
        )
    checks = {
        "freshrss_public": values["freshrss"]["public"]["connected"],
        "worker_public": values["worker"]["public"]["connected"],
        "database_positive_control": values["freshrss"]["database"]["connected"],
        "worker_database_denied": not values["worker"]["database"]["connected"]
        and values["worker"]["database"]["seconds"] >= 0.8,
        "worker_api_denied": not values["worker"]["api"]["connected"]
        and values["worker"]["api"]["seconds"] >= 0.8,
    }
    if not all(checks.values()):
        raise RuntimeError("deployed network observations failed")
    return checks


def admission_observations(client):
    program = r"""
$release=json_decode(file_get_contents('/opt/news-extraction/release.json'),true,32,JSON_THROW_ON_ERROR)['id'];$results=[];
foreach(['loopback','mismatch'] as $case){$body=['url'=>$case==='loopback'?'http://127.0.0.1/':'https://example.com/','expected_release'=>$case==='loopback'?$release:str_repeat('0',64),'validators'=>new stdClass()];$ch=curl_init('http://news-graby.news.svc.cluster.local:8080/extract');curl_setopt_array($ch,[CURLOPT_PROXY=>'',CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT_MS=>1000,CURLOPT_TIMEOUT_MS=>11000,CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>json_encode($body),CURLOPT_HTTPHEADER=>['Content-Type: application/json'],CURLOPT_RETURNTRANSFER=>true]);$raw=curl_exec($ch);$status=(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE);curl_close($ch);$reply=json_decode($raw?:'',true);$results[$case]=$status===($case==='loopback'?200:503)&&($reply['release_id']??'')===$release&&($reply['decision']??'')==='rejected'&&($reply['reason']??'')===($case==='loopback'?'destination_rejected':'reply_invalid')&&!isset($reply['html']);}
echo json_encode($results,JSON_THROW_ON_ERROR);
"""
    checks = json.loads(
        client.call(
            [
                *client.kc,
                "-n",
                "news",
                "exec",
                "deployment/freshrss",
                "-c",
                "freshrss",
                "--",
                "php",
                "-r",
                program,
            ],
            timeout=30,
        )
    )
    if not checks or not all(checks.values()):
        raise RuntimeError("deployed admission observations failed")
    return checks


def load_live_references(path: Path | None, corpus_sha: str, originals: dict) -> dict:
    """Bind separately reviewed current observations without changing frozen replay inputs."""
    if path is None:
        return {}
    document = json.loads(path.read_text())
    if document.get("schema") != 1 or document.get("corpus_sha256") != corpus_sha:
        raise ValueError("live references must identify the frozen corpus")
    result, identities = {}, set(originals)
    for case in document["cases"]:
        previous, identity = case["replaces_case_id"], case["id"]
        if (
            previous not in originals
            or previous in result
            or not re.fullmatch(r"[a-zA-Z0-9_-]+", identity)
            or identity in identities
            or case["url"] != originals[previous]["url"]
        ):
            raise ValueError("live reference identity differs from its selected publisher")
        source = Path(case["source"])
        if source.is_absolute() or ".." in source.parts:
            raise ValueError("live source must remain beside its reference")
        source = path.parent / source
        if (
            source.is_symlink()
            or not source.resolve().is_relative_to(path.parent.resolve())
            or not source.is_file()
            or hashlib.sha256(source.read_bytes()).hexdigest() != case["source_sha256"]
        ):
            raise ValueError("live source fingerprint differs")
        reference, review = case["reference"], case.get("review", {})
        reference_sha = hashlib.sha256(
            json.dumps(
                reference, sort_keys=True, ensure_ascii=False, separators=(",", ":")
            ).encode()
        ).hexdigest()
        if (
            not reference.get("blocks")
            or review.get("status") != "reviewed"
            or review.get("source_sha256") != case["source_sha256"]
            or review.get("reference_sha256") != reference_sha
            or review.get("schema_segments_missing") != 0
        ):
            raise ValueError("live reference requires complete independently reviewed evidence")
        identities.add(identity)
        result[previous] = case
    return result


def validate_native(receipt):
    required = (
        "clean_account",
        "complete_text",
        "images",
        "captions",
        "structure",
        "links",
        "light",
        "dark",
        "read_sync_both_directions",
        "favorite_sync_both_directions",
        "reader_view_summary_tested",
        "cache_behavior_observed",
        "client_account_removed",
    )
    if receipt.get("client") != "NetNewsWire" or not re.fullmatch(
        r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", receipt.get("version", "")
    ):
        raise ValueError("native client identity is incomplete")
    if any(receipt.get(key) is not True for key in required):
        raise ValueError("native acceptance is incomplete")
    if receipt.get("reader_view_result") not in {
        "rendered",
        "failed_as_documented",
    } or not isinstance(receipt.get("cached_summary_updated"), bool):
        raise ValueError("native Reader View or cache result is missing")
    return {
        "client": receipt["client"],
        "version": receipt["version"],
        **{key: True for key in required},
        "reader_view_result": receipt["reader_view_result"],
        "cached_summary_updated": receipt["cached_summary_updated"],
    }


def execute(client: Acceptance, corpus: Path):
    manifest, digest = validate_corpus(corpus)
    if digest != client.release["corpus"]["sha256"]:
        raise RuntimeError("retained corpus differs from release")
    cases = selected_cases(manifest)
    live_path = os.environ.get("NEWS_ACCEPTANCE_LIVE_REFERENCES")
    live = load_live_references(
        Path(live_path) if live_path else None,
        digest,
        {c["id"]: c for c in manifest["cases"]},
    )
    now = int(time.time())
    payload = [
        {
            "id": c["id"],
            "mode": "community",
            "url": c["url"],
            "rss": "<p>Private acceptance source summary.</p>",
            "published": now,
        }
        for c in cases
    ]
    rich = next(
        c
        for c in manifest["cases"]
        if c["id"].startswith("newsline-")
        and c["mode"] == "rss"
        and c.get("reference", {}).get("images")
        and "rss" in c
    )
    summary = next(
        c for c in manifest["cases"] if c["id"].startswith("engadget-live-0") and "rss" in c
    )
    payload.extend(
        {
            "id": c["id"],
            "mode": "rss",
            "url": c["url"],
            "rss": (corpus / c["rss"]).read_text(),
            "published": now,
        }
        for c in (rich, summary)
    )
    worker = client.preflight()
    client.result["stage"] = "network-and-admission"
    client.result["network"] = network_observations(client)
    client.result["admission"] = admission_observations(client)
    production = [
        p
        for p in client.get("pods")["items"]
        if p["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "news-graby"
        and RUN_LABEL not in p["metadata"].get("labels", {})
    ]
    if len(production) != 1:
        raise RuntimeError("production worker identity is ambiguous")
    node = production[0]["spec"]["nodeName"]
    if client.get("node", node)["status"]["nodeInfo"]["architecture"] != "amd64":
        raise RuntimeError("deployed worker architecture differs from the native test runtime")
    client.result["runtime"] = {"architecture": "amd64", "restricted_processes": True}
    print("Creating isolated cold-package-outage fixture", flush=True)
    client.result["stage"] = "cold-fixture"
    client.owned("create", cold_policy(client.run))
    cold = worker_fixture(worker, client.run, "cold")
    cold["spec"]["nodeName"] = node
    client.owned("create", cold)
    cold = client.wait_pod("cold")
    client.private_json(
        "fixture-credentials.json",
        {**client.credentials, "server": "https://news.lab.supermorphic.com"},
    )
    client.create_account()
    client.result["stage"] = "deployed-ingestion"
    print("Testing actual ingestion through the deployed public-fetch worker", flush=True)
    rich_payload = next(p for p in payload if p["id"] == rich["id"])
    baseline = client.account("rss", cases=[{**rich_payload, "id": "rich-rss-baseline"}])
    stored = client.account("ingest", cases=payload)
    client.private_json("initial-ingestion.json", stored)
    by_id = {c["case_id"]: c for c in stored["cases"]}
    quality = []
    for case in cases:
        reference = live.get(case["id"], case)
        observation = {
            "case_id": reference["id"],
            **assess(by_id[case["id"]]["html"], reference["reference"]),
        }
        if case["id"] in live:
            observation.update(
                replaces_case_id=case["id"], source_sha256=reference["source_sha256"]
            )
        quality.append(observation)
    client.result["editorial"] = quality
    if (
        not all(q["pass"] for q in quality)
        or by_id[rich["id"]]["html"] != baseline["cases"][0]["html"]
    ):
        raise RuntimeError("deployed editorial or rich RSS preservation gate failed")
    client.result["rich_rss_unchanged"] = True
    fault_cases = [{**payload[0], "rss": "<p>Genuine changed summary during outage.</p>"}]
    fault_cases.extend(
        {**payload[0], "id": "outage-" + str(i), "rss": f"<p>Cold outage RSS {i}.</p>"}
        for i in range(20)
    )
    cache_case = {
        **payload[1],
        "id": "cache-observation",
        "rss": "<p>Cached summary before the genuine publisher update.</p>",
    }
    fault_cases.append(cache_case)
    client.result["stage"] = "outage-fallback"
    fault = client.account("fault", worker_ip=cold["status"]["podIP"], cases=fault_cases)
    client.private_json("outage-ingestion.json", fault)
    if fault["worker_calls"] != 1 or fault["seconds"] >= 15:
        raise RuntimeError("outage fallback was not bounded")
    first = fault["cases"][0]
    if (
        first["id"] != by_id[payload[0]["id"]]["id"]
        or first["body_sha256"] != by_id[payload[0]["id"]]["body_sha256"]
    ):
        raise RuntimeError("outage lost accepted body or identity")
    if any(
        c["html"] != original["rss"]
        for c, original in zip(fault["cases"][1:], fault_cases[1:], strict=True)
    ):
        raise RuntimeError("outage lost original RSS")
    client.result["outage"] = {
        "new_rss_entries": 21,
        "availability_calls": 1,
        "seconds": round(fault["seconds"], 3),
        "accepted_body_and_identity_retained": True,
    }
    print("Waiting for bounded cold initialization failure", flush=True)
    client.result["stage"] = "cold-initialization"
    cold = client.wait_pod("cold", initialized=True)
    state = cold["status"]["initContainerStatuses"][0]["state"]["terminated"]
    logs = client.call(
        [*client.kc, "-n", "news", "logs", cold["metadata"]["name"], "-c", "initialize"]
    )
    (client.private / "cold-initialization.log").write_text(logs)
    seconds = (
        datetime.fromisoformat(state["finishedAt"]) - datetime.fromisoformat(state["startedAt"])
    ).total_seconds()
    attempts = logs.count("installation_attempt")
    if (
        state["exitCode"] == 0
        or seconds > 300
        or not 1 <= attempts <= 2
        or "initialization_ready" in logs
    ):
        raise RuntimeError("cold package outage exposed partial readiness or exceeded limits")
    client.result["cold_package_outage"] = {
        "bounded_failure": True,
        "attempts": attempts,
        "seconds": seconds,
        "no_service_traffic": True,
    }
    client.result["stage"] = "worker-recovery"
    recovery = worker_fixture(worker, client.run, "recovered")
    recovery["spec"]["nodeName"] = node
    client.owned("create", recovery)
    recovered = client.wait_pod("recovered", initialized=True)
    if recovered["status"]["initContainerStatuses"][0]["state"]["terminated"]["exitCode"] != 0:
        raise RuntimeError("worker recovery initialization failed")
    ready = client.call(
        [
            *client.kc,
            "-n",
            "news",
            "exec",
            recovered["metadata"]["name"],
            "-c",
            "worker",
            "--",
            "/usr/bin/php8.4",
            "-d",
            "extension=tidy",
            "/app/scripts/ready.php",
        ]
    )
    if ready.strip() != client.release["id"]:
        raise RuntimeError("recovered worker release differs")
    client.result["recovery"] = {
        "initialized": True,
        "release_matches": True,
        "no_service_traffic": True,
    }
    api = client.account("inspect")
    client.private_json("native-api-initial.json", api)
    delivered = {item["title"]: item for item in api["items"]}
    for case in payload:
        body = delivered["Acceptance " + case["id"]]["summary"]["content"]
        if hashlib.sha256(body.encode()).hexdigest() != by_id[case["id"]]["body_sha256"]:
            raise RuntimeError("Reader API differs from the accepted stored body")
    client.result["api_delivery"] = {"matching_bodies": len(payload)}
    native_fields = [
        "clean_account",
        "complete_text",
        "images",
        "captions",
        "structure",
        "links",
        "light",
        "dark",
        "read_sync_both_directions",
        "favorite_sync_both_directions",
        "reader_view_summary_tested",
        "cache_behavior_observed",
        "client_account_removed",
    ]
    client.result["native_client_cleanup"] = "pending"
    client.private_json(
        "native-request.json",
        {
            "stage": "ready",
            "release_id": client.release["id"],
            "case_ids": [c["id"] for c in payload],
            "cache_case_id": cache_case["id"],
            "credentials_file": str(client.private / "fixture-credentials.json"),
            "live_reference_file": live_path,
            "client_removal_confirmation": {"run": client.run, "removed": True},
            "receipt_template": {
                "client": "NetNewsWire",
                "version": None,
                **dict.fromkeys(native_fields),
                "reader_view_result": None,
                "cached_summary_updated": None,
            },
        },
    )
    print("Native Mac fixture ready; awaiting private client observations", flush=True)
    client.result["stage"] = "native-client"
    deadline = time.monotonic() + 1800
    handled = set()
    while time.monotonic() < deadline:
        client.lease()
        receipt = client.private / "native-receipt.json"
        if receipt.exists():
            client.result["native"] = validate_native(json.loads(receipt.read_text()))
            client.result["native_client_cleanup"] = "confirmed"
            client.result["status"] = "passed"
            return
        control = client.private / "native-control.json"
        if control.exists():
            command = json.loads(control.read_text())
            identity = command.get("request_id", "")
            if not re.fullmatch(r"[a-f0-9]{12}", identity):
                raise RuntimeError("invalid native control identity")
            if identity not in handled:
                if command["operation"] == "cache-update":
                    reply = client.account(
                        "ingest",
                        cases=[
                            {
                                **cache_case,
                                "rss": "<p>Genuine updated RSS triggers accepted extraction.</p>",
                            }
                        ],
                    )
                elif command["operation"] == "inspect":
                    reply = client.account("inspect")
                elif command["operation"] == "state":
                    reply = client.account("state", changes=command["changes"])
                else:
                    raise RuntimeError("unsupported native control operation")
                client.private_json("native-reply-" + identity + ".json", reply)
                handled.add(identity)
        time.sleep(2)
    raise RuntimeError("native acceptance deadline exceeded")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Run through just test record test.news-production-acceptance. Set NEWS_ACCEPTANCE_KUBECONFIG to an explicitly authorized absolute config path, NEWS_ACCEPTANCE_PRIVATE_ROOT to an existing private retained directory, NEWS_EXTRACTION_CORPUS to the protected corpus, and NEWS_PRODUCTION_ACCEPTANCE_CONFIRM=test:news:production-acceptance. The suite pauses for actual Mac observations in its private native-request.json; fill its receipt template only from observed results.",
    )
    parser.parse_args()
    client = None
    stage = "input"
    try:
        os.umask(0o077)
        if (
            os.environ.get("NEWS_PRODUCTION_ACCEPTANCE_CONFIRM")
            != "test:news:production-acceptance"
        ):
            raise RuntimeError("explicit acceptance intent required")
        selected = os.environ.get("NEWS_ACCEPTANCE_KUBECONFIG", "")
        config = Path(selected)
        if (
            not selected
            or not config.is_absolute()
            or not config.is_file()
            or os.environ.get("TEST_KUBECONFIG") != selected
        ):
            raise RuntimeError("explicit selected operator input required")
        directory = Path(os.environ["HOMELAB_TEST_RUN_DIR"])
        root = Path(os.environ["NEWS_ACCEPTANCE_PRIVATE_ROOT"])
        if not root.is_absolute() or not root.is_dir() or root.stat().st_mode & 0o077:
            raise RuntimeError("approved private root required")
        private = root / directory.name
        private.mkdir(mode=0o700)
        client = Acceptance(config, directory, private)
        server = client.call(
            [
                *client.kc,
                "config",
                "view",
                "--minify",
                "-o",
                "jsonpath={.clusters[0].cluster.server}",
            ]
        )
        if server != AUDIENCE:
            raise RuntimeError("operator input targets another cluster")

        def interrupted(_signum, _frame):
            raise InterruptedError("acceptance interrupted")

        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        stage = "acceptance"
        execute(client, Path(os.environ["NEWS_EXTRACTION_CORPUS"]))
    except Exception:  # noqa: BLE001 -- Keep credential-bearing adapter errors outside canonical output.
        if client:
            stage = client.result.get("stage", stage)
            client.result["failed_stage"] = stage
        print("News production acceptance failed at " + stage, flush=True)
    finally:
        if client:
            if not client.cleanup():
                client.result["status"] = "failed"
            client.private_json("result.json", client.result)
            (client.directory / "diagnostics/news-production-acceptance.json").write_text(
                json.dumps(client.result, indent=2) + "\n"
            )
    return 0 if client and client.result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
