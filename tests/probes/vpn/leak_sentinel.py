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
import datetime
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


def _parse_ts(value):
    """Parse an ISO8601 UTC timestamp (e.g. 2026-07-25T16:01:20Z) to epoch seconds, or None."""
    text = str(value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


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


def evaluate_outage(parsed, home_wan, vpn_ip, stop_ts, settle_s=5):
    """Verdict for a controlled VPN-stop transition (resilience item 4).

    Partitions a single continuous timeline by the moment the VPN was stopped and
    asserts the kill switch held: pre-stop egress is via the VPN, and during the outage
    (after a settle window) egress is fully blocked — with NO home-WAN IP in any segment.
    """
    home_wan = _ip(home_wan)
    vpn_ip = _ip(vpn_ip)
    egress = parsed.get("egress", [])
    stop_epoch = _parse_ts(stop_ts)

    def base(status, reason, extra=None):
        out = {
            "status": status,
            "reason": reason,
            "mode": "outage",
            "references": {
                "home_wan": home_wan,
                "vpn_ip": vpn_ip,
                "stop_ts": stop_ts,
                "settle_s": settle_s,
            },
        }
        if extra:
            out.update(extra)
        return out

    if not home_wan:
        return base(UNEVALUABLE, "home WAN reference IP is empty; cannot evaluate leak")
    if not vpn_ip:
        return base(UNEVALUABLE, "VPN IP reference is empty; cannot confirm egress path")
    if stop_epoch is None:
        return base(UNEVALUABLE, f"could not parse stop timestamp '{stop_ts}'")

    pre, during, unparsed = [], [], 0
    for sample in egress:
        ts = _parse_ts(sample.get("ts"))
        if ts is None:
            unparsed += 1
            continue
        if ts < stop_epoch:
            pre.append(_ip(sample.get("ip")))
        elif ts >= stop_epoch + settle_s:
            during.append(_ip(sample.get("ip")))
        # else: transition/settle window — the tunnel is still tearing down; ignored.

    leak_samples = [ip for ip in (pre + during) if ip == home_wan]
    pre_non_empty = [ip for ip in pre if ip]
    pre_via_vpn = [ip for ip in pre_non_empty if ip == vpn_ip]
    pre_anomaly = [ip for ip in pre_non_empty if ip not in (vpn_ip, home_wan)]
    during_egress = [ip for ip in during if ip]  # any egress during the outage is a breach

    counts = {
        "pre_stop_total": len(pre),
        "pre_stop_via_vpn": len(pre_via_vpn),
        "during_outage_total": len(during),
        "during_outage_egress": len(during_egress),
        "egress_leak": len(leak_samples),
        "unparsed_ts": unparsed,
    }

    def verdict(status, reason):
        return base(status, reason, {"counts": counts, "leak_samples": leak_samples})

    # Worst-first. The home-WAN leak guard holds across every segment.
    if leak_samples:
        return verdict(LEAK, f"egress showed the home WAN IP {home_wan} across the VPN transition")
    if pre_anomaly:
        return verdict(ANOMALY, f"pre-stop egress showed {len(pre_anomaly)} IP(s) not via the VPN")
    if not pre_via_vpn:
        return verdict(UNEVALUABLE, "no pre-stop egress via the VPN IP to establish a baseline")
    if not during:
        return verdict(
            UNEVALUABLE,
            "no egress samples during the outage window (settle too long or capture too short)",
        )
    if during_egress:
        return verdict(
            ANOMALY,
            f"KILL-SWITCH BREACH: {len(during_egress)} egress sample(s) succeeded during the VPN outage",
        )
    return verdict(
        PASSED,
        f"kill switch held: {len(pre_via_vpn)} pre-stop sample(s) via VPN {vpn_ip}, "
        f"{len(during)} outage sample(s) all blocked, no home-WAN leak",
    )


def is_pass(verdict):
    return verdict.get("status") == PASSED


def main(argv=None):
    parser = argparse.ArgumentParser(description="Analyze a qBittorrent VPN egress timeline.")
    parser.add_argument("--timeline", required=True, help="JSONL timeline file, or - for stdin")
    parser.add_argument("--home-wan", required=True, help="home/WAN reference IP (must never appear)")
    parser.add_argument("--vpn-ip", required=True, help="expected ProtonVPN public IP")
    parser.add_argument("--expected-resolver", default="127.0.0.1", help="expected in-netns resolver")
    parser.add_argument("--mode", choices=("baseline", "outage"), default="baseline",
                        help="baseline (VPN up) or outage (controlled VPN-stop transition)")
    parser.add_argument("--stop-ts", help="outage mode: ISO8601 timestamp when the VPN was stopped")
    parser.add_argument("--settle", type=float, default=5.0,
                        help="outage mode: seconds after stop to ignore while the tunnel tears down")
    args = parser.parse_args(argv)

    if args.mode == "outage" and not args.stop_ts:
        parser.error("--stop-ts is required in --mode outage")

    if args.timeline == "-":
        text = sys.stdin.read()
    else:
        with open(args.timeline, "r", encoding="utf-8") as handle:
            text = handle.read()

    parsed = parse_timeline(text)
    if args.mode == "outage":
        verdict = evaluate_outage(parsed, args.home_wan, args.vpn_ip, args.stop_ts, args.settle)
    else:
        verdict = evaluate(parsed, args.home_wan, args.vpn_ip, args.expected_resolver)
    json.dump(verdict, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if is_pass(verdict) else 1


if __name__ == "__main__":
    sys.exit(main())
