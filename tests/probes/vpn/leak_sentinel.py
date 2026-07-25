#!/usr/bin/env python3
"""qBittorrent/Gluetun VPN leak sentinel — timeline analyzer.

Consumes a JSONL egress timeline captured continuously from inside the qBittorrent
network namespace (see capture.sh) and renders a no-leak verdict against two reference
IPs: the ProtonVPN public IP and the home/WAN IP. Enforces the hard invariant that
qBittorrent egress only ever appears as the VPN IP and never as the home WAN IP, and
that the pod's egress path stays structurally pinned to the tunnel.

Pure functions (parse_timeline / evaluate) take plain data and never touch the network
or Kubernetes, so test_leak_sentinel.py unit-tests them offline in `just ci`. The live
capture + reference gathering live in the surrounding bash (leak-sentinel.sh).

Timeline records (one JSON object per line):
  {"ts": "<iso8601>", "type": "egress", "ip": "1.2.3.4"}   # "" == blocked/no egress
  {"ts": "<iso8601>", "type": "structural", "default_route_iface": "tun0",
   "resolver": "127.0.0.1"}

Verdict status precedence (worst first): leak > structural-anomaly > anomaly >
external-dependency > unevaluable > passed. Only "passed" exits 0.
"""

from __future__ import annotations

import argparse
import json
import sys

# Ordered worst -> best; only PASSED is a success.
LEAK = "leak"
STRUCTURAL_ANOMALY = "structural-anomaly"
ANOMALY = "anomaly"
EXTERNAL_DEPENDENCY = "external-dependency"
UNEVALUABLE = "unevaluable"
PASSED = "passed"

FAILING_STATUSES = (LEAK, STRUCTURAL_ANOMALY, ANOMALY, EXTERNAL_DEPENDENCY, UNEVALUABLE)


def parse_timeline(text):
    """Parse JSONL timeline text into {egress, structural, parse_errors}.

    Blank lines are ignored; malformed lines are counted, not fatal.
    """
    egress = []
    structural = []
    parse_errors = 0
    lines = text.splitlines() if isinstance(text, str) else list(text)
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except (ValueError, TypeError):
            parse_errors += 1
            continue
        if not isinstance(record, dict):
            parse_errors += 1
            continue
        kind = record.get("type")
        if kind == "egress":
            egress.append(record)
        elif kind == "structural":
            structural.append(record)
        else:
            parse_errors += 1
    return {"egress": egress, "structural": structural, "parse_errors": parse_errors}


def _ip(value):
    return str(value or "").strip()


# NOTE on the structural check: Gluetun pins egress with a firewall/policy-routing
# kill switch, NOT by making the tunnel the main-table default route. Observed live, the
# app container's /proc/net/route default is still `eth0` while all egress exits via the
# VPN. So the default-route interface is recorded for evidence but is NOT a gating
# signal; the gating structural invariant is DNS isolation (resolver == Gluetun's
# in-netns loopback). The leak proof itself is the egress-IP timeline.
def evaluate(
    parsed,
    home_wan,
    vpn_ip,
    expected_resolver="127.0.0.1",
):
    """Render a verdict dict from a parsed timeline and the reference IPs."""
    home_wan = _ip(home_wan)
    vpn_ip = _ip(vpn_ip)
    egress = parsed.get("egress", [])
    structural = parsed.get("structural", [])

    egress_ips = [_ip(s.get("ip")) for s in egress]
    non_empty = [ip for ip in egress_ips if ip]
    blocked = [ip for ip in egress_ips if not ip]

    leak_samples = [ip for ip in non_empty if home_wan and ip == home_wan]
    via_vpn = [ip for ip in non_empty if vpn_ip and ip == vpn_ip]
    # Any observed egress that is neither the VPN IP nor the home WAN IP is unexpected.
    anomaly_samples = [ip for ip in non_empty if ip not in (vpn_ip, home_wan)]

    bad_structural = [
        s for s in structural if _ip(s.get("resolver")) != expected_resolver
    ]

    counts = {
        "egress_total": len(egress),
        "egress_blocked": len(blocked),
        "egress_via_vpn": len(via_vpn),
        "egress_leak": len(leak_samples),
        "egress_anomaly": len(anomaly_samples),
        "structural_total": len(structural),
        "structural_bad": len(bad_structural),
        "parse_errors": parsed.get("parse_errors", 0),
    }

    def verdict(status, reason):
        return {
            "status": status,
            "reason": reason,
            "counts": counts,
            "references": {
                "home_wan": home_wan,
                "vpn_ip": vpn_ip,
                "expected_resolver": expected_resolver,
            },
            "leak_samples": leak_samples,
            "anomaly_samples": anomaly_samples,
            "first_ts": (egress[0].get("ts") if egress else None),
            "last_ts": (egress[-1].get("ts") if egress else None),
        }

    # A missing reference makes the leak claim unverifiable.
    if not home_wan:
        return verdict(UNEVALUABLE, "home WAN reference IP is empty; cannot evaluate leak")
    if not vpn_ip:
        return verdict(UNEVALUABLE, "VPN IP reference is empty; cannot confirm egress path")

    # Worst-first precedence.
    if leak_samples:
        return verdict(LEAK, f"qBittorrent egress showed the home WAN IP {home_wan}")
    if bad_structural:
        return verdict(
            STRUCTURAL_ANOMALY,
            f"DNS not isolated to the Gluetun resolver {expected_resolver} "
            f"({len(bad_structural)}/{len(structural)} structural samples off)",
        )
    if anomaly_samples:
        return verdict(
            ANOMALY,
            f"egress showed {len(anomaly_samples)} IP(s) that are neither the VPN IP "
            f"nor the home WAN",
        )
    if not non_empty:
        return verdict(
            EXTERNAL_DEPENDENCY,
            "no successful egress observation in the window (VPN down or public-IP "
            "provider outage) — inconclusive, not a pass",
        )
    if not structural:
        return verdict(
            STRUCTURAL_ANOMALY,
            "no structural (route/resolver) samples captured to confirm the egress path",
        )
    return verdict(
        PASSED,
        f"{len(via_vpn)} egress samples all via VPN IP {vpn_ip}; no home-WAN leak; "
        f"DNS isolated to the Gluetun resolver {expected_resolver}",
    )


def is_pass(verdict):
    return verdict.get("status") == PASSED


def main(argv=None):
    parser = argparse.ArgumentParser(description="Analyze a qBittorrent VPN egress timeline.")
    parser.add_argument("--timeline", required=True, help="JSONL timeline file, or - for stdin")
    parser.add_argument("--home-wan", required=True, help="home/WAN reference IP (must never appear)")
    parser.add_argument("--vpn-ip", required=True, help="expected ProtonVPN public IP")
    parser.add_argument("--expected-resolver", default="127.0.0.1", help="expected in-netns resolver")
    args = parser.parse_args(argv)

    if args.timeline == "-":
        text = sys.stdin.read()
    else:
        with open(args.timeline, "r", encoding="utf-8") as handle:
            text = handle.read()

    verdict = evaluate(
        parse_timeline(text),
        args.home_wan,
        args.vpn_ip,
        args.expected_resolver,
    )
    json.dump(verdict, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if is_pass(verdict) else 1


if __name__ == "__main__":
    sys.exit(main())
