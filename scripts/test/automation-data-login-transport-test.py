#!/usr/bin/env python3
"""Offline security boundaries for the expiring application-login relay."""

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import automation_data_login_transport as relay
from automation_data_client import PrivateFileError

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "login_command", ROOT / "scripts/operations/automation-data-login.py"
)
command = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(command)


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.directory = self.root / "transport"
        self.now = int(time.time())
        self.scope = {"domain": "sample", "application": "interview", "schema": "interview_api"}
        self.receipt = relay.prepare(
            self.directory, **self.scope, credential_id="synthetic-header", now=self.now
        )
        self.profile = json.loads((self.directory / "transport.json").read_text())
        self.graph = json.loads((self.directory / "workflow.json").read_text())
        self.payload = {
            "domain": "sample",
            "application": "interview",
            "operation": "login-validate",
        }

    def published(self):
        graph = json.loads(json.dumps(self.graph))
        graph.update(
            id="synthetic-workflow",
            active=True,
            versionId="version-one",
            activeVersionId="version-one",
        )
        graph["activeVersion"] = {key: graph[key] for key in ("nodes", "connections")}
        graph["activeVersion"]["versionId"] = "version-one"
        return graph

    def verify(self, graph=None):
        observed = self.root / "observed.json"
        observed.write_text(json.dumps(graph or self.published()))
        relay.verify(self.directory, observed, now=self.now)

    def invoke(self, name, value, now=None):
        code = next(n["parameters"]["jsCode"] for n in self.graph["nodes"] if n["name"] == name)
        # Execute the rendered guard, not a Python reimplementation of its policy.
        harness = "const fs=require('fs');const p=JSON.parse(fs.readFileSync(0,'utf8'));Date.now=()=>p.now*1000;try { process.stdout.write(JSON.stringify(new Function('$json',p.code)(p.value))); } catch {process.exit(9)}"
        result = subprocess.run(
            ["node", "-e", harness],
            input=json.dumps(
                {"code": code, "value": value, "now": self.now if now is None else now}
            ),
            text=True,
            capture_output=True,
            check=False,
        )
        return json.loads(result.stdout)[0]["json"] if result.returncode == 0 else None

    def authenticated(self, payload=None):
        return {
            "request": self.payload if payload is None else payload,
            "tokenDigest": hashlib.sha256(self.profile["token"].encode()).hexdigest(),
        }

    def test_preparation_is_private_inactive_exclusive_and_secret_free(self):
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.directory / "transport.json").stat().st_mode & 0o777, 0o600)
        self.assertNotIn(self.profile["token"], json.dumps(self.graph))
        self.assertNotIn(self.profile["token"], json.dumps(self.receipt))
        self.assertFalse(self.graph["active"])
        with self.assertRaises((PrivateFileError, FileExistsError)):
            relay.prepare(self.directory, **self.scope, credential_id="synthetic-header")
        for key in ("saveDataSuccessExecution", "saveDataErrorExecution"):
            self.assertEqual(self.graph["settings"][key], "none")
        self.assertFalse(self.graph["settings"]["saveManualExecutions"])
        self.assertFalse(self.graph["settings"]["saveExecutionProgress"])
        self.assertNotIn("errorWorkflow", self.graph["settings"])
        request = next(n for n in self.graph["nodes"] if n["name"] == "Call Provisioner")
        self.assertFalse(request.get("retryOnFail", False))
        self.assertFalse(
            request["parameters"]["options"]["redirect"]["redirect"]["followRedirects"]
        )
        self.assertEqual(request["credentials"]["httpHeaderAuth"]["id"], "synthetic-header")
        self.assertEqual(
            request["parameters"]["url"], "http://127.0.0.1:5678/webhook/automation-data-provision"
        )

    def test_no_private_material_in_any_git_checkout_or_symlink(self):
        checkout = self.root / "checkout"
        checkout.mkdir()
        (checkout / ".git").write_text("gitdir: elsewhere")
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        for target in (checkout / "private", link / "private"):
            with self.subTest(target=target), self.assertRaises(PrivateFileError):
                relay.prepare(target, **self.scope, credential_id="synthetic-header")
            self.assertFalse(target.exists())

    def test_published_graph_is_required_and_drift_is_rejected(self):
        with self.assertRaises(PrivateFileError):
            relay.request_configuration(
                self.directory / "transport.json", self.payload, now=self.now
            )
        for mutate in ("active", "draft", "retention", "credential", "guard"):
            graph = self.published()
            if mutate == "active":
                graph["active"] = False
            elif mutate == "draft":
                graph["activeVersionId"] = "old-version"
            elif mutate == "retention":
                graph["settings"]["saveDataErrorExecution"] = "all"
            elif mutate == "credential":
                next(n for n in graph["nodes"] if n["name"] == "Call Provisioner")["credentials"][
                    "httpHeaderAuth"
                ]["id"] = "wrong"
            else:
                graph["activeVersion"]["nodes"][1]["parameters"] = {}
            with self.subTest(mutate=mutate), self.assertRaises(PrivateFileError):
                self.verify(graph)
        self.verify()
        url, headers = relay.request_configuration(
            self.directory / "transport.json", self.payload, now=self.now
        )
        self.assertTrue(
            url.startswith(command.WEBHOOK.rsplit("/", 1)[0] + "/automation-data-login-")
        )
        self.assertEqual(headers["X-Automation-Data-Login"], self.profile["token"])

    def test_accepts_mcp_same_as_draft_published_representation(self):
        graph = self.published()
        graph["activeVersion"] = {"sameAsDraft": True}
        self.verify(graph)

    def test_file_mode_and_hardlink_are_rejected(self):
        self.verify()
        path = self.directory / "transport.json"
        path.chmod(0o644)
        with self.assertRaises(PrivateFileError):
            relay.request_configuration(path, self.payload, now=self.now)
        path.chmod(0o600)
        (self.directory / "alias").hardlink_to(path)
        with self.assertRaises(PrivateFileError):
            relay.request_configuration(path, self.payload, now=self.now)

    def test_selected_transport_sends_only_its_bearer_and_preserves_payload(self):
        self.verify()
        with (
            mock.patch.dict(
                os.environ,
                {
                    "AUTOMATION_DATA_LOGIN_TRANSPORT": str(self.directory / "transport.json"),
                    "AUTOMATION_DATA_PROVISIONING_TOKEN": "s" * 48,
                },
            ),
            mock.patch.object(
                command, "send_private_request", return_value={"ok": True}
            ) as request,
        ):
            self.assertEqual(command.send_request(self.payload), {"ok": True})
        request.assert_called_once_with(
            self.profile["url"],
            {"X-Automation-Data-Login": self.profile["token"]},
            self.payload,
            timeout=90,
        )

    def test_client_refuses_expired_wrong_scope_and_invalid_url(self):
        self.verify()
        path = self.directory / "transport.json"
        for payload, now in (
            ({**self.payload, "domain": "foreign"}, self.now),
            (self.payload, self.now + 3600),
            ({**self.payload, "operation": "login-rotate"}, self.now),
        ):
            with self.subTest(payload=payload, now=now), self.assertRaises(PrivateFileError):
                relay.request_configuration(path, payload, now=now)
        for url in (
            "https://evil.example/webhook/x",
            self.profile["url"] + "?x=1",
            self.profile["url"] + "#x",
        ):
            changed = {**self.profile, "url": url}
            path.write_text(json.dumps(changed))
            with self.assertRaises(PrivateFileError):
                relay.request_configuration(path, self.payload, now=self.now)

    def test_invalid_selected_transport_never_falls_back_to_operator_token(self):
        with (
            mock.patch.dict(
                os.environ,
                {
                    "AUTOMATION_DATA_LOGIN_TRANSPORT": str(self.directory / "transport.json"),
                    "AUTOMATION_DATA_PROVISIONING_TOKEN": "s" * 48,
                },
            ),
            mock.patch.object(command.WEBHOOK_OPENER, "open") as request,
        ):
            with self.assertRaises((PrivateFileError, command.RequestError)):
                command.send_request(self.payload)
            request.assert_not_called()

    def test_prepare_guard_strips_headers_and_limits_request(self):
        value = {
            "headers": {"x-automation-data-login": self.profile["token"], "unrelated": "drop"},
            "body": self.payload,
        }
        result = self.invoke("Prepare Request", value)
        self.assertEqual(result, {"token": self.profile["token"], "request": self.payload})
        for changed in (
            {**value, "headers": {}},
            {**value, "body": []},
            {**value, "body": {"x": "s" * 5000}},
        ):
            self.assertIsNone(self.invoke("Prepare Request", changed))

    def test_server_enforces_digest_scope_expiry_and_closed_operation_fields(self):
        self.assertEqual(self.invoke("Authorize Request", self.authenticated()), self.payload)
        invalid = [
            self.authenticated({**self.payload, "domain": "foreign"}),
            self.authenticated({**self.payload, "application": "foreign"}),
            self.authenticated({**self.payload, "operation": "provision"}),
            self.authenticated({**self.payload, "operation": "login-rotate"}),
            self.authenticated({**self.payload, "password": "s" * 48}),
            self.authenticated({**self.payload, "url": "https://evil.example"}),
            {**self.authenticated(), "tokenDigest": "0" * 64},
        ]
        for value in invalid:
            with self.subTest(value=value):
                self.assertIsNone(self.invoke("Authorize Request", value))
        self.assertIsNone(self.invoke("Authorize Request", self.authenticated(), self.now + 3600))
        self.assertIsNone(self.invoke("Authorize Request", self.authenticated(), self.now - 1))
        activate = {
            **self.payload,
            "operation": "login-activate",
            "operationId": "00000000-0000-4000-8000-000000000001",
            "expectedGeneration": 0,
            "password": "s" * 48,
        }
        self.assertEqual(self.invoke("Authorize Request", self.authenticated(activate)), activate)
        for extra in (
            {"expectedGeneration": 1},
            {"expectedGeneration": False},
            {"password": "short"},
            {"operationId": "invalid"},
        ):
            self.assertIsNone(
                self.invoke("Authorize Request", self.authenticated({**activate, **extra}))
            )
        register = {**self.payload, "operation": "login-register", "schema": "interview_api"}
        self.assertEqual(self.invoke("Authorize Request", self.authenticated(register)), register)
        self.assertIsNone(
            self.invoke("Authorize Request", self.authenticated({**register, "schema": "public"}))
        )
        complete = {
            **self.payload,
            "operation": "login-complete",
            "operationId": activate["operationId"],
            "credentialGeneration": 1,
        }
        self.assertEqual(self.invoke("Authorize Request", self.authenticated(complete)), complete)
        self.assertIsNone(
            self.invoke(
                "Authorize Request", self.authenticated({**complete, "credentialGeneration": 2})
            )
        )

    def test_registered_schema_is_checked_before_any_activation_or_completion(self):
        nodes = {node["name"]: node for node in self.graph["nodes"]}
        self.assertEqual(
            nodes["Check Registered Scope"]["parameters"]["jsCode"],
            nodes["Safe Response"]["parameters"]["jsCode"],
        )
        # Every route to the mutating dispatch must pass through the registry check.
        connections = self.graph["connections"]
        visited = set()

        def walk(name, checked=False):
            checked = checked or name == "Check Registered Scope"
            if name == "Call Provisioner":
                self.assertTrue(checked)
            key = (name, checked)
            if key in visited:
                return
            visited.add(key)
            for output in connections.get(name, {}).get("main", []):
                for edge in output:
                    walk(edge["node"], checked)

        walk("Login Webhook")
        self.assertIn(("Call Provisioner", True), visited)
        self.assertEqual(
            nodes["Read Registered Login"]["credentials"], nodes["Call Provisioner"]["credentials"]
        )
        self.assertIn("login-validate", nodes["Read Registered Login"]["parameters"]["jsonBody"])
        self.assertNotIn("password", nodes["Read Registered Login"]["parameters"]["jsonBody"])
        self.assertIn("Date.now()", nodes["Call Provisioner"]["parameters"]["jsonBody"])

    def test_wrong_registered_schema_never_receives_candidate(self):
        harness = r"""
const fs = require('fs'), crypto = require('crypto');
const fixture = JSON.parse(fs.readFileSync(0, 'utf8'));
const nodes = new Map(fixture.graph.nodes.map(node => [node.name, node]));
Date.now = () => fixture.now * 1000;
const outputs = new Map(), requests = [];
const $ = name => ({first: () => ({json: outputs.get(name)})});
const expression = (value, item) => new Function('$json', '$', 'return (' + value.slice(3, -2) + ')')(item, $);
let current = 'Login Webhook';
let item = {headers: {'x-automation-data-login': fixture.token}, body: fixture.payload};
let error = false;
try {
  while (current) {
    const node = nodes.get(current);
    let branch = 0;
    if (node.type === 'n8n-nodes-base.code') {
      item = new Function('$json', '$', node.parameters.jsCode)(item, $)[0].json;
    } else if (node.type === 'n8n-nodes-base.crypto') {
      item = {...item, tokenDigest: crypto.createHash('sha256').update(item.token).digest('hex')};
    } else if (node.type === 'n8n-nodes-base.httpRequest') {
      const request = expression(node.parameters.jsonBody, item);
      requests.push(request.operation);
      item = {ok: true, domain: 'sample', database: 'sample', application: 'interview',
        schema: fixture.registeredSchema,
        role: 'app_' + crypto.createHash('md5').update('sample:interview').digest('hex') + '_integration',
        state: request.operation === 'login-activate' ? 'activating' : 'awaiting_grants',
        credentialGeneration: request.operation === 'login-activate' ? 1 : 0,
        operationId: request.operationId ?? null, expectedGeneration: request.expectedGeneration ?? null,
        valid: true};
    } else if (node.type === 'n8n-nodes-base.if') {
      branch = expression(node.parameters.conditions.conditions[0].leftValue, item) ? 0 : 1;
    }
    outputs.set(current, item);
    current = fixture.graph.connections[current]?.main[branch]?.[0]?.node;
  }
} catch { error = true; }
process.stdout.write(JSON.stringify({requests, error}));
"""
        payload = {
            **self.payload,
            "operation": "login-activate",
            "operationId": "00000000-0000-4000-8000-000000000001",
            "expectedGeneration": 0,
            "password": "synthetic-candidate-" + "s" * 32,
        }
        for schema, requests, error in (
            ("another_api", ["login-validate"], True),
            ("interview_api", ["login-validate", "login-activate"], False),
        ):
            result = subprocess.run(
                ["node", "-e", harness],
                input=json.dumps(
                    {
                        "graph": self.graph,
                        "token": self.profile["token"],
                        "payload": payload,
                        "now": self.now,
                        "registeredSchema": schema,
                    }
                ),
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(json.loads(result.stdout), {"requests": requests, "error": error})

    def test_response_is_typed_metadata_and_cannot_echo_private_fields(self):
        role = (
            "app_"
            + hashlib.md5(b"sample:interview", usedforsecurity=False).hexdigest()
            + "_integration"
        )
        response = {
            "ok": True,
            **self.scope,
            "database": "sample",
            "role": role,
            "state": "awaiting_grants",
            "credentialGeneration": 0,
            "operationId": None,
            "expectedGeneration": None,
            "valid": True,
        }
        self.assertEqual(
            self.invoke(
                "Safe Response",
                {
                    **response,
                    "password": "sentinel",
                    "checks": {"error": "sentinel"},
                    "headers": {"x": "sentinel"},
                },
            ),
            response,
        )
        for field, value in [
            ("domain", "foreign"),
            ("schema", "public"),
            ("role", "postgres"),
            ("state", "sentinel"),
            ("credentialGeneration", "sentinel"),
            ("valid", "sentinel"),
            ("operationId", "sentinel"),
        ]:
            with self.subTest(field=field):
                self.assertIsNone(self.invoke("Safe Response", {**response, field: value}))


if __name__ == "__main__":
    unittest.main()
