"""Offline unit tests for the leak_sentinel analyzer. Pure logic; no cluster/network.

Run in `just ci` via `uv run python -m unittest`.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import leak_sentinel as ls  # noqa: E402


# RFC 5737 documentation addresses. These are opaque fixtures compared for equality;
# the real addresses are discovered live at probe time and never committed.
HOME = "192.0.2.1"
VPN = "198.51.100.1"


def egress(ip, ts="2026-07-25T00:00:00Z"):
    return {"ts": ts, "type": "egress", "ip": ip}


def structural(iface="tun0", resolver="127.0.0.1", ts="2026-07-25T00:00:00Z"):
    return {"ts": ts, "type": "structural", "default_route_iface": iface, "resolver": resolver}


def verdict_for(egress_ips, structural_samples=None, home=HOME, vpn=VPN):
    if structural_samples is None:
        structural_samples = [structural()]
    parsed = {
        "egress": [egress(ip) for ip in egress_ips],
        "structural": list(structural_samples),
        "parse_errors": 0,
    }
    return ls.evaluate(parsed, home, vpn)


class ParseTimelineTests(unittest.TestCase):
    def test_splits_kinds_and_ignores_blanks(self):
        text = (
            '{"ts":"t","type":"egress","ip":"1.2.3.4"}\n'
            "\n"
            '   \n'
            '{"ts":"t","type":"structural","default_route_iface":"tun0","resolver":"127.0.0.1"}\n'
        )
        parsed = ls.parse_timeline(text)
        self.assertEqual(len(parsed["egress"]), 1)
        self.assertEqual(len(parsed["structural"]), 1)
        self.assertEqual(parsed["parse_errors"], 0)

    def test_counts_malformed_and_unknown_lines(self):
        text = "not json\n{}\n{\"type\":\"other\"}\n[1,2,3]\n"
        parsed = ls.parse_timeline(text)
        self.assertEqual(parsed["egress"], [])
        self.assertEqual(parsed["structural"], [])
        self.assertEqual(parsed["parse_errors"], 4)


class EvaluateTests(unittest.TestCase):
    def test_clean_baseline_passes(self):
        v = verdict_for([VPN, VPN, VPN])
        self.assertEqual(v["status"], ls.PASSED)
        self.assertTrue(ls.is_pass(v))

    def test_home_wan_leak_fails(self):
        v = verdict_for([VPN, HOME, VPN])
        self.assertEqual(v["status"], ls.LEAK)
        self.assertIn(HOME, v["leak_samples"])
        self.assertFalse(ls.is_pass(v))

    def test_leak_outranks_structural_anomaly(self):
        v = verdict_for([HOME], structural_samples=[structural(resolver="192.168.90.2")])
        self.assertEqual(v["status"], ls.LEAK)

    def test_unexpected_egress_is_anomaly(self):
        v = verdict_for([VPN, "8.8.8.8"])
        self.assertEqual(v["status"], ls.ANOMALY)
        self.assertIn("8.8.8.8", v["anomaly_samples"])

    def test_all_blocked_is_external_dependency(self):
        v = verdict_for(["", "", ""])
        self.assertEqual(v["status"], ls.EXTERNAL_DEPENDENCY)

    def test_route_iface_is_informational_not_gating(self):
        # Gluetun pins egress via firewall, so the main-table default route is eth0 even
        # on a correctly-configured pod. The interface must NOT gate the verdict.
        v = verdict_for([VPN], structural_samples=[structural(iface="eth0")])
        self.assertEqual(v["status"], ls.PASSED)

    def test_wrong_resolver_is_structural_anomaly(self):
        v = verdict_for([VPN], structural_samples=[structural(resolver="192.168.90.2")])
        self.assertEqual(v["status"], ls.STRUCTURAL_ANOMALY)

    def test_missing_structural_is_anomaly(self):
        v = verdict_for([VPN], structural_samples=[])
        self.assertEqual(v["status"], ls.STRUCTURAL_ANOMALY)

    def test_missing_home_reference_is_unevaluable(self):
        v = verdict_for([VPN], home="")
        self.assertEqual(v["status"], ls.UNEVALUABLE)

    def test_missing_vpn_reference_is_unevaluable(self):
        v = verdict_for([VPN], vpn="")
        self.assertEqual(v["status"], ls.UNEVALUABLE)

    def test_blocked_samples_do_not_fail_a_passing_window(self):
        # Occasional blocked ticks are fine as long as some egress confirms the VPN IP.
        v = verdict_for([VPN, "", VPN])
        self.assertEqual(v["status"], ls.PASSED)

    def test_exit_code_via_main(self):
        import io
        import json
        import tempfile

        timeline = "\n".join(
            json.dumps(r)
            for r in [egress(VPN), structural(), egress(VPN)]
        )
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            fh.write(timeline)
            path = fh.name
        try:
            saved = sys.stdout
            sys.stdout = io.StringIO()
            try:
                rc = ls.main(["--timeline", path, "--home-wan", HOME, "--vpn-ip", VPN])
            finally:
                sys.stdout = saved
            self.assertEqual(rc, 0)
        finally:
            os.unlink(path)


STOP = "2026-07-25T16:00:30Z"


def outage_verdict(egress_samples, stop=STOP, home=HOME, vpn=VPN, settle=5):
    parsed = {"egress": list(egress_samples), "structural": [], "parse_errors": 0}
    return ls.evaluate_outage(parsed, home, vpn, stop, settle)


class OutageModeTests(unittest.TestCase):
    # pre-stop (< 16:00:30) via VPN; during outage (>= 16:00:35 with settle=5) blocked.
    PRE = [egress(VPN, "2026-07-25T16:00:10Z"), egress(VPN, "2026-07-25T16:00:20Z")]
    DURING_BLOCKED = [egress("", "2026-07-25T16:00:40Z"), egress("", "2026-07-25T16:00:50Z")]

    def test_kill_switch_held_passes(self):
        v = outage_verdict(self.PRE + self.DURING_BLOCKED)
        self.assertEqual(v["status"], ls.PASSED)
        self.assertTrue(ls.is_pass(v))

    def test_home_wan_during_outage_is_leak(self):
        v = outage_verdict(self.PRE + [egress(HOME, "2026-07-25T16:00:40Z")])
        self.assertEqual(v["status"], ls.LEAK)

    def test_any_egress_during_outage_is_breach_anomaly(self):
        v = outage_verdict(self.PRE + [egress("9.9.9.9", "2026-07-25T16:00:40Z")])
        self.assertEqual(v["status"], ls.ANOMALY)

    def test_pre_stop_not_via_vpn_is_anomaly(self):
        v = outage_verdict([egress("9.9.9.9", "2026-07-25T16:00:10Z")] + self.DURING_BLOCKED)
        self.assertEqual(v["status"], ls.ANOMALY)

    def test_no_during_samples_is_unevaluable(self):
        v = outage_verdict(self.PRE)
        self.assertEqual(v["status"], ls.UNEVALUABLE)

    def test_no_pre_vpn_baseline_is_unevaluable(self):
        v = outage_verdict([egress("", "2026-07-25T16:00:10Z")] + self.DURING_BLOCKED)
        self.assertEqual(v["status"], ls.UNEVALUABLE)

    def test_settle_window_samples_are_ignored(self):
        # A sample inside the settle window (16:00:32, between stop and stop+5s) must not
        # count as an outage breach even though egress briefly lingered.
        v = outage_verdict(self.PRE + [egress(VPN, "2026-07-25T16:00:32Z")] + self.DURING_BLOCKED)
        self.assertEqual(v["status"], ls.PASSED)

    def test_unparseable_stop_ts_is_unevaluable(self):
        v = outage_verdict(self.PRE + self.DURING_BLOCKED, stop="not-a-timestamp")
        self.assertEqual(v["status"], ls.UNEVALUABLE)

    def test_leak_guard_holds_in_pre_segment(self):
        v = outage_verdict([egress(HOME, "2026-07-25T16:00:10Z")] + self.DURING_BLOCKED)
        self.assertEqual(v["status"], ls.LEAK)


if __name__ == "__main__":
    unittest.main()
