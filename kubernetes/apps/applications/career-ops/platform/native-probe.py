"""Fixed synthetic storage and connectivity checks; never read application data."""

import errno
import ipaddress
import json
import os
import re
import runpy
import shutil
import socket
import struct
import sys
from pathlib import Path

MOUNT = runpy.run_path(str(Path(__file__).with_name("mount-probe.py")))


def directories(roots, run):
    if not re.fullmatch("[0-9a-f]{32}", run):
        raise ValueError("invalid synthetic run")
    return [
        roots["releases"] / "published" / run,
        roots["releases"] / "candidates" / run,
        roots["requests"] / "requests" / run,
        roots["artifacts"] / run,
    ]


def owner(directory, run):
    if directory.is_symlink() or (directory / "owner").is_symlink():
        raise ValueError("synthetic ownership changed")
    if (directory / "owner").read_text() != run:
        raise ValueError("synthetic ownership changed")


def seed(roots, run):
    for directory in directories(roots, run):
        directory.parent.mkdir(parents=True, exist_ok=True)
        directory.mkdir()
        with (directory / "owner").open("x") as marker:
            marker.write(run)
            marker.flush()
            os.fsync(marker.fileno())
    request = roots["requests"] / "requests" / run
    (request / "input").mkdir()
    for pod in ["write", "read"]:
        (request / "attempts" / "attempt" / "pods" / pod).mkdir(parents=True)
    for directory in [
        roots["releases"] / "published" / run,
        roots["releases"] / "candidates" / run,
        request / "input",
        roots["artifacts"] / run,
    ]:
        MOUNT["publish"](directory)


def cleanup(roots, run):
    owned = [d for d in directories(roots, run) if d.exists() or d.is_symlink()]
    # Check every marker before removing any owned run directory.
    for directory in owned:
        owner(directory, run)
    for directory in owned:
        shutil.rmtree(directory)


def tcp(targets, allowed):
    for address, port in targets:
        try:
            with socket.create_connection((address, port), timeout=3):
                if not allowed:
                    raise ValueError("offline network unexpectedly reachable")
        except TimeoutError:
            if allowed:
                raise
        # Refusal, unreachable routes and authentication errors are failures.


def dns(address, allowed):
    query_id = os.urandom(2)
    name = b"".join(
        bytes([len(p)]) + p for p in b"kubernetes.default.svc.cluster.local".split(b".")
    )
    packet = query_id + struct.pack("!5H", 0x0100, 1, 0, 0, 0) + name + b"\0\0\1\0\1"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(3)
        client.connect((address, 53))
        client.send(packet)
        try:
            reply = client.recv(4096)
        except TimeoutError:
            if allowed:
                raise
            return
        if not allowed:
            raise ValueError("offline DNS unexpectedly reachable")
        if len(reply) < 12 or reply[:2] != query_id or not (reply[2] & 0x80) or reply[3] & 0x0F:
            raise ValueError("DNS response did not validate the positive control")


def network(addresses, allowed):
    for address in addresses:
        if ipaddress.ip_address(address).version != 4:
            raise ValueError("fixture requires observed IPv4 Service addresses")
    tcp(list(zip(addresses, [443, 5432, 53], strict=True)), allowed)
    dns(addresses[2], allowed)


def network_probe(mode, addresses):
    phases = {
        "network-" + stage + "-" + target
        for stage in ["write", "read"]
        for target in ["api", "database", "dns-tcp", "dns-udp"]
    }
    if mode not in phases or len(addresses) != 3:
        raise ValueError("invalid single-target phase")
    if any(ipaddress.ip_address(a).version != 4 for a in addresses):
        raise ValueError("fixture requires observed IPv4 Service addresses")
    target = mode.split("-", 2)[2]
    if target == "dns-udp":
        dns(addresses[2], allowed=False)
    else:
        index, port = {"api": (0, 443), "database": (1, 5432), "dns-tcp": (2, 53)}[target]
        tcp([(addresses[index], port)], allowed=False)


def worker(mode):
    for directory in [Path("/releases"), Path("/input")]:
        MOUNT["verify_bundle"](directory)
        MOUNT["assert_read_only"](directory)
    if mode == "write":
        directory = Path("/staging/input")
        directory.mkdir()
        MOUNT["publish"](directory)
        try:
            MOUNT["publish"](directory)
        except FileExistsError as error:
            if error.errno != errno.EEXIST:
                raise
        else:
            raise ValueError("exclusive creation failed")
        MOUNT["verify_bundle"](directory)


def main(argv):
    result = {"result": "failed"}
    code = 1
    try:
        mode, run, *addresses = argv
        if mode not in {"seed", "write", "read", "cleanup"} and not mode.startswith("network-"):
            raise ValueError("invalid fixed fixture invocation")
        if len(addresses) != 3:
            raise ValueError("invalid fixed fixture invocation")
        roots = {name: Path("/" + name) for name in ["releases", "requests", "artifacts"]}
        directories(roots, run)
        if mode.startswith("network-"):
            network_probe(mode, addresses)
        else:
            network(addresses, allowed=mode in {"seed", "cleanup"})
        if mode == "seed":
            seed(roots, run)
        elif mode == "cleanup":
            cleanup(roots, run)
        elif mode in {"write", "read"}:
            worker(mode)
        result = {
            "result": "passed",
            "phase": mode,
            "network": "allowed" if mode in {"seed", "cleanup"} else "denied",
        }
        code = 0
    except (OSError, ValueError) as error:
        result["error"] = type(error).__name__
        result["errno"] = getattr(error, "errno", None)
    # Fixed non-secret evidence. No container logs, tokens, addresses or host IDs.
    Path("/dev/termination-log").write_text(json.dumps(result))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
