#!/usr/bin/env python3
"""Open one fixed loopback PostgreSQL tunnel using a current protected CLI profile."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from automation_data_access import (
    ProfileMetadata,
    assert_profile_unchanged,
    revalidate_connection_profile,
    select_connection_profile,
)
from automation_data_client import (
    PrivateFileError,
    assert_tunnel_active,
    authenticate_candidate,
    private_database_tunnel,
    validate_private_file,
    validate_service_profile,
)

DOMAIN = re.compile(r"^[a-z][a-z0-9_]{0,47}$")
APPLICATION = re.compile(r"^[a-z][a-z0-9_]{0,23}$")
SERVICE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,127}$")


def local_port() -> int:
    value = os.environ.get("AUTOMATION_DATA_LOCAL_PORT", "15432")
    if not value.isdigit() or not 1024 <= int(value) <= 65535:
        raise ValueError("invalid_local_port")
    return int(value)


def selected_profile(
    domain: str, identity: str, port: int, selected: ProfileMetadata | None = None
) -> tuple[str, str, Path]:
    if identity == "migrator":
        role = f"{domain}_migrator"
        application = None
    elif identity.startswith("application/") and APPLICATION.fullmatch(identity[12:]):
        application = identity[12:]
        role = (
            "app_"
            + hashlib.md5(f"{domain}:{application}".encode(), usedforsecurity=False).hexdigest()
            + "_integration"
        )
    else:
        raise ValueError("invalid_registered_identity")
    selected = selected or select_connection_profile(domain, identity)
    revalidate_connection_profile(domain, identity, selected)
    if selected.local_port is not None and selected.local_port != port:
        raise PrivateFileError("profile_port_mismatch")
    section = selected.service
    service_file = validate_private_file(selected.service_file)
    expected_section = f"automation_data_{domain}_{role}"
    if application is not None and section != expected_section:
        raise PrivateFileError("application_service_mismatch")
    profile = validate_service_profile(service_file, section, domain, role, port)
    if (
        selected.automatic
        and selected.file_signature is not None
        and profile["passfile"] != selected.file_signature[-1][0]
    ):
        raise PrivateFileError("profile_passfile_mismatch")
    if application is not None:
        binding_path = service_file.parent / "binding.json"
        binding = json.loads(validate_private_file(binding_path).read_text())
        if (
            binding.get("domain") != domain
            or binding.get("database") != domain
            or binding.get("application") != application
            or binding.get("role") != role
            or type(binding.get("credentialGeneration")) is not int
            or binding["credentialGeneration"] < 1
            or binding.get("localPort") != port
            or not re.fullmatch(r"[a-z][a-z0-9_]{0,47}", str(binding.get("schema", "")))
            or profile["passfile"]
            != str(
                service_file.parent
                / f"generation-{binding['credentialGeneration']}"
                / "credential.pgpass"
            )
        ):
            raise PrivateFileError("application_binding_mismatch")
    assert_profile_unchanged(selected)
    return role, profile["password"], service_file


def main(argv: list[str]) -> int:
    try:
        if len(argv) != 2:
            raise ValueError("invalid_arguments")
        domain, identity = argv
        if not DOMAIN.fullmatch(domain) or domain in {
            "postgres",
            "template0",
            "template1",
            "automation_data_control",
        }:
            raise ValueError("invalid_domain")
        selected = select_connection_profile(domain, identity)
        port = (
            selected.local_port
            if selected.local_port is not None and "AUTOMATION_DATA_LOCAL_PORT" not in os.environ
            else local_port()
        )
        raw_config = os.environ.get("AUTOMATION_DATA_KUBECONFIG")
        config = Path(raw_config) if raw_config else None
        with private_database_tunnel(config, port):
            role, password, service_file = selected_profile(domain, identity, port, selected)
            authenticate_candidate(port, domain, role, password)
            print(
                json.dumps(
                    {
                        "ready": True,
                        "database": domain,
                        "role": role,
                        "service": selected.service,
                        "serviceFile": str(service_file),
                        "localPort": port,
                    }
                ),
                flush=True,
            )
            while True:
                time.sleep(2)
                assert_tunnel_active(port)
    except KeyboardInterrupt:
        return 0
    except Exception:  # noqa: BLE001 - never print credentials, API output, or profile contents
        print("Automation-data private connection failed or ended.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
