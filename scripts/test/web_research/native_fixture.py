#!/usr/bin/env python3
"""Credential-safe probes that run inside the disposable native container."""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BOOTSTRAP = Path("/run/bootstrap")
SUBJECT = "crawl4ai-platform@supermorphic.com"


def request(
    port: int,
    path: str,
    method: str = "GET",
    data: object | None = None,
    authorization: str | None = None,
    host: str = "127.0.0.1",
    timeout: float = 100,
) -> tuple[int, dict[str, str], bytes]:
    headers = {"Content-Type": "application/json"}
    if authorization:
        headers["Authorization"] = authorization
    body = json.dumps(data).encode() if data is not None else None
    call = urllib.request.Request(
        f"http://{host}:{port}{path}", data=body, method=method, headers=headers
    )
    try:
        try:
            response = urllib.request.urlopen(call, timeout=timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return (
                response.status,
                dict(response.headers),
                response.read(8 * 1024 * 1024 + 1),
            )
    except (OSError, TimeoutError):
        return 0, {}, b""


def require(condition: bool, phase: str) -> None:
    if not condition:
        raise AssertionError(phase)


def wait_for(condition, phase: str, timeout: float = 120) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.5)
    raise TimeoutError(phase)


def crawl_body(url: str) -> dict[str, object]:
    return {
        "urls": [url],
        "crawler_config": {
            "type": "CrawlerRunConfig",
            "params": {
                "cache_mode": {"type": "CacheMode", "params": "bypass"},
                "page_timeout": 30000,
                "verbose": False,
                "only_text": True,
                "exclude_all_images": True,
            },
        },
    }


def serve() -> None:
    generation = BOOTSTRAP / "generation-1"
    generation.mkdir(mode=0o700)
    for name in ("api_token", "signing_key"):
        path = generation / name
        path.write_text(secrets.token_hex(32), encoding="ascii")
        path.chmod(0o600)
    (BOOTSTRAP / "..data").symlink_to(generation.name)
    for name in ("api_token", "signing_key"):
        (BOOTSTRAP / name).symlink_to(f"..data/{name}")

    children = [
        subprocess.Popen([sys.executable, "/opt/platform/server_launcher.py"]),
        subprocess.Popen(
            [
                sys.executable,
                "/opt/platform/credential_agent.py",
                "--admin-token-file",
                "/run/bootstrap/api_token",
                "--subject",
                SUBJECT,
            ]
        ),
    ]
    try:
        while all(child.poll() is None for child in children):
            time.sleep(0.5)
        raise RuntimeError("managed process exited")
    finally:
        for child in children:
            child.terminate()
        for child in children:
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def readiness() -> None:
    wait_for(
        lambda: (
            request(9001, "/readyz", timeout=3)[0] == 200
            and request(11235, "/health", timeout=3)[0] == 200
        ),
        "native-readiness",
        180,
    )
    print("PASS native-readiness", flush=True)


def capture_metrics() -> None:
    status, _, body = request(9001, "/metrics", timeout=5)
    require(status == 200 and body, "metrics-response")
    Path("/run/crawl4ai/agent-metrics.prom").write_bytes(body)
    print("PASS credential-agent-metrics-capture", flush=True)


def gateway_contract() -> None:
    inline = crawl_body(
        "raw:<html><body><article><h1>Platform Fixture</h1>"
        "<p>Native credential-free research fixture text.</p></article></body></html>"
    )
    status, headers, body = request(8080, "/crawl", "POST", inline)
    document = json.loads(body)
    require(
        status == 200 and document["results"][0]["success"],
        "credential-free-crawl",
    )
    require(all(key.lower() != "authorization" for key in headers), "response-header")

    status, _, _ = request(
        8080,
        "/crawl",
        "POST",
        inline,
        authorization="Bearer synthetic-invalid-client-token",
    )
    require(status == 200, "authorization-overwrite")
    for method, path in (
        ("GET", "/crawl"),
        ("POST", "/token"),
        ("GET", "/schema"),
        ("POST", "/crawl/stream"),
    ):
        status, _, _ = request(8080, path, method, {})
        require(status == 404, "route-exclusion")

    status, _, body = request(8080, "/crawl", "POST", crawl_body("https://example.com/"))
    document = json.loads(body)
    result = document.get("results", [{}])[0]
    require(status == 200 and document.get("success") is True, "public-crawl")
    require(result.get("success") is True, "public-result")
    require(result.get("status_code") == 200, "canary-status")
    require(result.get("url") == "https://example.com/", "canary-url")
    require(result.get("redirected_url") == "https://example.com/", "canary-final-url")
    require(
        "Example Domain" in result.get("markdown", {}).get("raw_markdown", ""),
        "canary-extraction",
    )
    print("PASS translated-gateway-contract", flush=True)


def rotation_contract() -> None:
    sys.path.insert(0, "/opt/platform")
    import server_launcher as launcher

    old_admin = (BOOTSTRAP / "api_token").read_text(encoding="ascii")
    old_key = (BOOTSTRAP / "signing_key").read_text(encoding="ascii")
    status, headers, _ = request(9000, "/authorize", "POST", timeout=6)
    require(status == 200, "automatic-issuance")
    old_jwt = headers["Authorization"]

    table = launcher._process_table()
    launchers = []
    for pid in table:
        try:
            command = (Path("/proc") / str(pid) / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if b"/opt/platform/server_launcher.py" in command:
            launchers.append(pid)
    require(len(launchers) == 1, "launcher-count")
    launcher_pid = launchers[0]

    def rotate(number: int, admin: str, key: str) -> None:
        descendants = launcher._descendant_identities(launcher_pid, launcher._process_table())
        generation = BOOTSTRAP / f"generation-{number}"
        generation.mkdir(mode=0o700)
        for name, value in (("api_token", admin), ("signing_key", key)):
            path = generation / name
            path.write_text(value, encoding="ascii")
            path.chmod(0o600)
        pending = BOOTSTRAP / "..data-next"
        pending.symlink_to(generation.name)
        os.replace(pending, BOOTSTRAP / "..data")

        def replaced() -> bool:
            current = launcher._process_table()
            return (
                not launcher._living_identities(descendants, current)
                and bool(launcher._descendant_identities(launcher_pid, current))
                and request(11235, "/health", timeout=3)[0] == 200
            )

        wait_for(replaced, "generation-replacement")
        require(
            not launcher._living_identities(descendants, launcher._process_table()),
            "old-descendants",
        )

    new_admin = secrets.token_hex(32)
    rotate(2, new_admin, old_key)
    require(
        request(11235, "/schema", authorization=old_jwt)[0] == 200,
        "jwt-survival",
    )
    require(
        request(
            11235,
            "/token",
            "POST",
            {"email": SUBJECT, "api_token": old_admin},
        )[0]
        in (401, 403),
        "old-admin-denied",
    )
    require(
        request(
            11235,
            "/token",
            "POST",
            {"email": SUBJECT, "api_token": new_admin},
        )[0]
        == 200,
        "new-admin-accepted",
    )

    rotate(3, new_admin, secrets.token_hex(32))
    require(
        request(11235, "/schema", authorization=old_jwt)[0] == 401,
        "old-jwt-revoked",
    )

    def agent_recovered() -> bool:
        status, response_headers, _ = request(9000, "/authorize", "POST", timeout=6)
        authorization = response_headers.get("Authorization")
        return bool(
            status == 200
            and authorization
            and authorization != old_jwt
            and request(11235, "/schema", authorization=authorization)[0] == 200
        )

    wait_for(agent_recovered, "agent-remint", 90)
    status, response_headers, body = request(
        8080,
        "/crawl",
        "POST",
        crawl_body("raw:<html><body>Credential rotation recovered.</body></html>"),
    )
    require(
        status == 200 and json.loads(body)["results"][0]["success"],
        "crawl-recovery",
    )
    require(
        all(key.lower() != "authorization" for key in response_headers),
        "rotation-response-header",
    )
    print("PASS credential-rotation-contract", flush=True)


def searx_contract() -> None:
    wait_for(
        lambda: request(8080, "/healthz", host="searxng", timeout=3)[0] == 200,
        "searx-readiness",
        120,
    )
    status, _, body = request(8080, "/", host="searxng", timeout=20)
    require(status == 200 and b"Private web search" in body, "searx-ui")
    query = "/search?" + urllib.parse.urlencode({"q": "example domain", "format": "json"})
    status, _, body = request(8080, query, host="searxng", timeout=30)
    document = json.loads(body)
    results = document.get("results", [])
    require(status == 200 and results, "searx-json")
    parsed = urllib.parse.urlparse(results[0].get("url", ""))
    require(parsed.scheme in ("http", "https") and bool(parsed.netloc), "searx-result-url")
    print("PASS searxng-contract", flush=True)


def gatus_contract() -> None:
    def statuses():
        status, _, body = request(8080, "/api/v1/endpoints/statuses", host="gatus", timeout=10)
        if status != 200:
            return None
        try:
            return json.loads(body)
        except (TypeError, ValueError):
            return None

    expected = {
        "searxng",
        "crawl4ai-readiness",
        "crawl4ai-e2e",
        "searxng-search-e2e",
    }

    def all_passed() -> bool:
        document = statuses()
        if not isinstance(document, list):
            return False
        records = {
            item.get("name"): item
            for item in document
            if item.get("group") == "Automation" and item.get("name") in expected
        }
        if set(records) != expected:
            return False
        for record in records.values():
            results = record.get("results", [])
            if not results or results[0].get("success") is not True:
                return False
            if not all(
                item.get("success") is True for item in results[0].get("conditionResults", [])
            ):
                return False
        return True

    wait_for(all_passed, "gatus-parser", 180)
    print("PASS gatus-production-conditions", flush=True)


MODES = {
    "serve": serve,
    "readiness": readiness,
    "metrics": capture_metrics,
    "gateway": gateway_contract,
    "rotation": rotation_contract,
    "searx": searx_contract,
    "gatus": gatus_contract,
}


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    action = MODES.get(mode)
    if action is None:
        print("FAIL fixture-usage (ValueError)", file=sys.stderr)
        return 2
    try:
        action()
    except Exception as error:  # noqa: BLE001 - never expose native response details.
        print(f"FAIL {mode} ({type(error).__name__})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
