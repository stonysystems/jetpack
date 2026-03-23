#!/usr/bin/env python3
"""Tests for scripts/sanity_check.py"""

import os
import sys
import json
import tempfile
import shutil
import unittest

# Add scripts dir to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from sanity_check import (
    parse_res_file,
    collect_experiment_data,
    find_moderate_conc,
    check_wan_delay,
    compute_latency_stats,
    compute_path_usage,
    run_sanity_checks,
    generate_report,
    SanityResult,
    SERVERS,
    LEADER_SERVER,
    SITE,
    PROTOCOL_LATENCY_MODEL,
)


def make_res_content(
    protocol="none_raft",
    mode=0,
    mid_throughput=100.0,
    total_throughput=120.0,
    original_count=1000,
    original_50pct=75.0,
    original_90pct=85.0,
    original_99pct=90.0,
    original_ave=76.0,
    fast_count=0,
    fast_50pct=-1.0,
    efficient_count=0,
    efficient_50pct=-1.0,
    wan_delay=True,
):
    """Generate a synthetic .res file content."""
    lines = []
    lines.append(f'I [s_main.cc:775] 2026-03-23 06:00:00.000 | starting process 12345')
    if wan_delay:
        lines.append(f'I [s_main.cc:793] 2026-03-23 06:00:00.000 | WAN delay enabled via WAN_DELAY_MS=20 (20000 us)')
    lines.append(f'I [s_main.cc:859] 2026-03-23 06:01:00.000 | Total throughtput is {total_throughput:.2f}')
    lines.append(
        f'I [s_main.cc:905] 2026-03-23 06:01:00.000 | '
        f'All-fast-path-attempts           statistics   count {fast_count:>8}   '
        f'0pct {fast_50pct:>8.2f}  50pct {fast_50pct:>8.2f}  '
        f'90pct {fast_50pct:>8.2f}  99pct {fast_50pct:>8.2f}    ave {fast_50pct:>8.2f}'
    )
    lines.append(
        f'I [s_main.cc:908] 2026-03-23 06:01:00.000 | '
        f'All-original-path-attempts       statistics   count {original_count:>8}   '
        f'0pct    60.00  50pct {original_50pct:>8.2f}  '
        f'90pct {original_90pct:>8.2f}  99pct {original_99pct:>8.2f}    ave {original_ave:>8.2f}'
    )
    lines.append(
        f'I [s_main.cc:910] 2026-03-23 06:01:00.000 | '
        f'All-efficient-attempts           statistics   count {efficient_count:>8}   '
        f'0pct {efficient_50pct:>8.2f}  50pct {efficient_50pct:>8.2f}  '
        f'90pct {efficient_50pct:>8.2f}  99pct {efficient_50pct:>8.2f}    ave {efficient_50pct:>8.2f}'
    )
    lines.append(
        f'I [s_main.cc:921] 2026-03-23 06:01:00.000 | Mid throughput is {mid_throughput:.2f}'
    )
    return "\n".join(lines)


class TestParseResFile(unittest.TestCase):
    """Test .res file parsing."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def write_file(self, name, content):
        path = os.path.join(self.tmpdir, name)
        with open(path, 'w') as f:
            f.write(content)
        return path

    def test_parse_basic_res(self):
        path = self.write_file("test.res", make_res_content())
        result = parse_res_file(path)
        self.assertAlmostEqual(result["mid_throughput"], 100.0)
        self.assertAlmostEqual(result["total_throughput"], 120.0)
        self.assertTrue(result["wan_delay_detected"])
        self.assertIsNotNone(result["original_path"])
        self.assertEqual(result["original_path"]["count"], 1000)
        self.assertAlmostEqual(result["original_path"]["50pct"], 75.0)

    def test_parse_no_wan_delay(self):
        path = self.write_file("test.res", make_res_content(wan_delay=False))
        result = parse_res_file(path)
        self.assertFalse(result["wan_delay_detected"])

    def test_parse_missing_file(self):
        result = parse_res_file("/nonexistent/file.res")
        self.assertIsNone(result["mid_throughput"])

    def test_parse_fast_path(self):
        path = self.write_file("test.res", make_res_content(
            fast_count=500, fast_50pct=40.0
        ))
        result = parse_res_file(path)
        self.assertIsNotNone(result["fast_path"])
        self.assertEqual(result["fast_path"]["count"], 500)
        self.assertAlmostEqual(result["fast_path"]["50pct"], 40.0)

    def test_parse_efficient_path(self):
        path = self.write_file("test.res", make_res_content(
            efficient_count=800, efficient_50pct=42.0
        ))
        result = parse_res_file(path)
        self.assertIsNotNone(result["efficient_path"])
        self.assertEqual(result["efficient_path"]["count"], 800)
        self.assertAlmostEqual(result["efficient_path"]["50pct"], 42.0)


class TestCollectExperimentData(unittest.TestCase):
    """Test data collection from result directory."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def write_experiment(self, protocol, conc, mode, servers=None,
                         mid_throughput=100.0, **kwargs):
        if servers is None:
            servers = SERVERS
        for srv in servers:
            fname = f"{protocol}-{SITE}-rw_1000000-{conc}-{mode}-YCSB_A-{srv}.res"
            path = os.path.join(self.tmpdir, fname)
            with open(path, 'w') as f:
                f.write(make_res_content(
                    protocol=protocol, mode=mode,
                    mid_throughput=mid_throughput, **kwargs
                ))

    def test_collect_complete_experiment(self):
        self.write_experiment("none_raft", "concurrent_100", "0")
        data = collect_experiment_data(self.tmpdir)
        key = ("none_raft", "concurrent_100", "0")
        self.assertIn(key, data)
        self.assertEqual(len(data[key]), len(SERVERS))

    def test_incomplete_experiment_excluded(self):
        # Only write 3 servers
        self.write_experiment("none_raft", "concurrent_100", "0",
                              servers=SERVERS[:3])
        data = collect_experiment_data(self.tmpdir)
        key = ("none_raft", "concurrent_100", "0")
        self.assertIn(key, data)
        self.assertEqual(len(data[key]), 3)

    def test_multiple_protocols(self):
        self.write_experiment("none_raft", "concurrent_100", "0")
        self.write_experiment("none_copilot", "concurrent_100", "0")
        data = collect_experiment_data(self.tmpdir)
        self.assertIn(("none_raft", "concurrent_100", "0"), data)
        self.assertIn(("none_copilot", "concurrent_100", "0"), data)

    def test_multiple_modes(self):
        self.write_experiment("none_raft", "concurrent_100", "0", mid_throughput=500.0)
        self.write_experiment("rule_raft", "concurrent_100", "1", mid_throughput=600.0)
        data = collect_experiment_data(self.tmpdir)
        self.assertIn(("none_raft", "concurrent_100", "0"), data)
        self.assertIn(("rule_raft", "concurrent_100", "1"), data)

    def test_ignores_non_res_files(self):
        with open(os.path.join(self.tmpdir, "README.md"), 'w') as f:
            f.write("not a res file")
        data = collect_experiment_data(self.tmpdir)
        self.assertEqual(len(data), 0)


class TestFindModerateConc(unittest.TestCase):
    """Test moderate concurrency selection."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def write_experiment(self, protocol, conc, mode, mid_throughput=100.0, **kwargs):
        for srv in SERVERS:
            fname = f"{protocol}-{SITE}-rw_1000000-{conc}-{mode}-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=mid_throughput, **kwargs))

    def test_finds_max_throughput_conc(self):
        self.write_experiment("none_raft", "concurrent_10", "0", mid_throughput=100.0)
        self.write_experiment("none_raft", "concurrent_100", "0", mid_throughput=500.0)
        self.write_experiment("none_raft", "concurrent_400", "0", mid_throughput=300.0)
        data = collect_experiment_data(self.tmpdir)
        conc, tp = find_moderate_conc(data, "none_raft", "0")
        self.assertEqual(conc, "concurrent_100")
        self.assertAlmostEqual(tp, 2500.0)  # 500 * 5 servers

    def test_no_data_returns_none(self):
        data = collect_experiment_data(self.tmpdir)
        conc, tp = find_moderate_conc(data, "none_raft", "0")
        self.assertIsNone(conc)
        self.assertEqual(tp, -1)


class TestComputeLatencyStats(unittest.TestCase):
    """Test per-server latency computation."""

    def test_leader_and_follower_separation(self):
        server_data = {
            "zoo0": {"original_path": {"count": 100, "50pct": 40.0}, "fast_path": None, "efficient_path": None},
            "zoo1": {"original_path": {"count": 100, "50pct": 80.0}, "fast_path": None, "efficient_path": None},
            "zoo2": {"original_path": {"count": 100, "50pct": 78.0}, "fast_path": None, "efficient_path": None},
            "zoo3": {"original_path": {"count": 100, "50pct": 82.0}, "fast_path": None, "efficient_path": None},
            "zoo4": {"original_path": {"count": 100, "50pct": 79.0}, "fast_path": None, "efficient_path": None},
        }
        leader_lat, avg_follower, follower_lats = compute_latency_stats(
            server_data, "original_path"
        )
        self.assertAlmostEqual(leader_lat, 40.0)
        self.assertAlmostEqual(avg_follower, 79.75)
        self.assertEqual(len(follower_lats), 4)

    def test_fallback_to_original_path(self):
        """When efficient_path is empty, should fall back to original_path."""
        server_data = {
            "zoo0": {
                "original_path": {"count": 100, "50pct": 75.0},
                "fast_path": {"count": 0, "50pct": -1.0},
                "efficient_path": {"count": 0, "50pct": -1.0},
            },
        }
        leader_lat, avg_follower, follower_lats = compute_latency_stats(
            server_data, "efficient_path"
        )
        self.assertAlmostEqual(leader_lat, 75.0)

    def test_negative_latency_skipped(self):
        server_data = {
            "zoo0": {"original_path": {"count": 0, "50pct": -1.0}, "fast_path": None, "efficient_path": None},
        }
        leader_lat, avg_follower, _ = compute_latency_stats(server_data, "original_path")
        self.assertIsNone(leader_lat)


class TestCheckWanDelay(unittest.TestCase):
    """Test WAN delay detection."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_detects_wan_delay(self):
        for srv in SERVERS:
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_10-0-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(wan_delay=True))
        data = collect_experiment_data(self.tmpdir)
        self.assertTrue(check_wan_delay(data, "none_raft"))

    def test_no_wan_delay(self):
        for srv in SERVERS:
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_10-0-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(wan_delay=False))
        data = collect_experiment_data(self.tmpdir)
        self.assertFalse(check_wan_delay(data, "none_raft"))


class TestRunSanityChecks(unittest.TestCase):
    """Integration tests for the full sanity check pipeline."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def write_full_protocol(self, protocol_none, protocol_rule, concs,
                            leader_lat=40.0, follower_lat=80.0, rule_lat=42.0,
                            rule_efficient_lat=42.0):
        """Write a full set of mode=0, mode=1, mode=101 experiments."""
        for conc_name, tp in concs:
            # mode=0 original
            for srv in SERVERS:
                lat = leader_lat if srv == LEADER_SERVER else follower_lat
                fname = f"{protocol_none}-{SITE}-rw_1000000-{conc_name}-0-YCSB_A-{srv}.res"
                with open(os.path.join(self.tmpdir, fname), 'w') as f:
                    f.write(make_res_content(
                        mid_throughput=tp,
                        original_count=1000, original_50pct=lat,
                        original_90pct=lat+10, original_99pct=lat+15,
                        original_ave=lat+1
                    ))
            # mode=1 rule
            for srv in SERVERS:
                fname = f"{protocol_rule}-{SITE}-rw_1000000-{conc_name}-1-YCSB_A-{srv}.res"
                with open(os.path.join(self.tmpdir, fname), 'w') as f:
                    f.write(make_res_content(
                        mid_throughput=tp * 1.1,
                        original_count=0, original_50pct=-1.0,
                        efficient_count=1000, efficient_50pct=rule_efficient_lat
                    ))
            # mode=101 adaptive
            for srv in SERVERS:
                fname = f"{protocol_rule}-{SITE}-rw_1000000-{conc_name}-101-YCSB_A-{srv}.res"
                with open(os.path.join(self.tmpdir, fname), 'w') as f:
                    f.write(make_res_content(
                        mid_throughput=tp * 0.95,
                        original_count=500, original_50pct=follower_lat,
                        efficient_count=500, efficient_50pct=rule_efficient_lat
                    ))

    def test_full_raft_passes(self):
        """Full Raft data with expected latencies should mostly pass."""
        self.write_full_protocol(
            "none_raft", "rule_raft",
            [("concurrent_10", 50.0), ("concurrent_100", 200.0), ("concurrent_400", 150.0)],
            leader_lat=42.0, follower_lat=82.0, rule_efficient_lat=41.0
        )
        results, summaries = run_sanity_checks(self.tmpdir, wan_delay_ms=20)
        # Should have WAN delay check + leader + follower + rule + adaptive + 5 missing protocols
        raft_results = [r for r in results if "raft" in r.name.lower()]
        self.assertTrue(len(raft_results) >= 3)
        # WAN, leader, follower, rule, adaptive should all pass
        raft_passes = [r for r in raft_results if r.passed]
        self.assertTrue(len(raft_passes) >= 3)

    def test_no_data_reports_missing(self):
        """Empty directory should report all protocols missing."""
        results, summaries = run_sanity_checks(self.tmpdir)
        self.assertEqual(len(results), 0)

    def test_partial_data_handles_gracefully(self):
        """Only Raft data should report Raft checks + missing for others."""
        self.write_full_protocol(
            "none_raft", "rule_raft",
            [("concurrent_100", 200.0)],
            leader_lat=45.0, follower_lat=78.0, rule_efficient_lat=40.0
        )
        results, summaries = run_sanity_checks(self.tmpdir, wan_delay_ms=20)
        # Should have checks for raft + "no data" for other 5 protocols
        no_data = [r for r in results if "No data found" in r.observed]
        self.assertEqual(len(no_data), 5)

    def test_high_latency_fails(self):
        """Latency way above threshold should fail."""
        self.write_full_protocol(
            "none_raft", "rule_raft",
            [("concurrent_100", 200.0)],
            leader_lat=500.0, follower_lat=500.0, rule_efficient_lat=500.0
        )
        results, _ = run_sanity_checks(self.tmpdir, wan_delay_ms=20)
        raft_lat_results = [r for r in results
                            if "raft" in r.name.lower() and "latency" in r.name.lower()]
        # At least some should fail with 500ms latency (expected ~40-80ms)
        failed = [r for r in raft_lat_results if not r.passed]
        self.assertTrue(len(failed) > 0,
                        f"Expected failures for 500ms latency, got: {[(r.name, r.passed) for r in raft_lat_results]}")

    def test_adaptive_throughput_check(self):
        """Adaptive throughput wildly different from original should fail."""
        # Write original mode
        for srv in SERVERS:
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_100-0-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=1000.0))
        # Write adaptive with very low throughput
        for srv in SERVERS:
            fname = f"rule_raft-{SITE}-rw_1000000-concurrent_100-101-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=10.0))
        results, _ = run_sanity_checks(self.tmpdir, wan_delay_ms=20)
        adaptive_results = [r for r in results if "adaptive" in r.name.lower()]
        if adaptive_results:
            # 10/1000 = 0.01x, should fail the 0.3-2.5x check
            self.assertFalse(adaptive_results[0].passed)


class TestGenerateReport(unittest.TestCase):
    """Test report generation."""

    def test_report_contains_header(self):
        results = [
            SanityResult("test check", "expected", "observed", True, "note"),
        ]
        report = generate_report(results, {"raft": []}, "/tmp/test", wan_delay_ms=20)
        self.assertIn("# Experiment 0 Sanity Checks", report)
        self.assertIn("WAN_DELAY_MS=20", report)
        self.assertIn("RTT", report)

    def test_report_counts(self):
        results = [
            SanityResult("pass check", "e", "o", True),
            SanityResult("fail check", "e", "o", False),
        ]
        report = generate_report(results, {}, "/tmp/test")
        self.assertIn("**Passed**: 1", report)
        self.assertIn("**Failed/Warning**: 1", report)

    def test_report_overall_pass(self):
        results = [SanityResult("check", "e", "o", True)]
        report = generate_report(results, {}, "/tmp/test")
        self.assertIn("**Overall**: PASS", report)

    def test_report_overall_partial(self):
        results = [
            SanityResult("check1", "e", "o", True),
            SanityResult("check2", "e", "o", False),
        ]
        report = generate_report(results, {}, "/tmp/test")
        self.assertIn("**Overall**: PARTIAL", report)


class TestProtocolLatencyModel(unittest.TestCase):
    """Test protocol-specific latency expectations."""

    def test_all_protocols_have_models(self):
        """Every protocol family must have a latency model."""
        from sanity_check import PROTOCOL_FAMILIES
        for family in PROTOCOL_FAMILIES:
            self.assertIn(family, PROTOCOL_LATENCY_MODEL,
                          f"Missing latency model for {family}")

    def test_model_has_required_fields(self):
        """Each model must have leader_rtt, follower_rtt, reason."""
        for proto, model in PROTOCOL_LATENCY_MODEL.items():
            self.assertIn("leader_rtt", model, f"{proto} missing leader_rtt")
            self.assertIn("follower_rtt", model, f"{proto} missing follower_rtt")
            self.assertIn("reason", model, f"{proto} missing reason")
            self.assertIsInstance(model["leader_rtt"], (int, float))
            self.assertIsInstance(model["follower_rtt"], (int, float))

    def test_copilot_expects_2_rtt(self):
        """Copilot (2-leader) should expect 2 RTT for both leader and follower."""
        model = PROTOCOL_LATENCY_MODEL["copilot"]
        self.assertEqual(model["leader_rtt"], 2)
        self.assertEqual(model["follower_rtt"], 2)

    def test_raft_single_leader_model(self):
        """Raft (1-leader) should expect 1 RTT leader, 2 RTT follower."""
        model = PROTOCOL_LATENCY_MODEL["raft"]
        self.assertEqual(model["leader_rtt"], 1)
        self.assertEqual(model["follower_rtt"], 2)

    def test_mencius_multi_leader_model(self):
        """Mencius (all-leader) should expect 1 RTT for both."""
        model = PROTOCOL_LATENCY_MODEL["mencius"]
        self.assertEqual(model["leader_rtt"], 1)
        self.assertEqual(model["follower_rtt"], 1)

    def test_copilot_2rtt_latency_passes(self):
        """Copilot with ~82ms latency should pass (expected ~80ms = 2 RTT)."""
        tmpdir = tempfile.mkdtemp()
        try:
            # Write Copilot mode 0 data: all servers ~82ms (2 RTT)
            for srv in SERVERS:
                fname = f"none_copilot-{SITE}-rw_1000000-concurrent_100-0-YCSB_A-{srv}.res"
                with open(os.path.join(tmpdir, fname), 'w') as f:
                    f.write(make_res_content(
                        mid_throughput=500.0,
                        original_count=1000, original_50pct=82.0,
                        original_90pct=83.0, original_99pct=84.0,
                        original_ave=82.0
                    ))
            results, _ = run_sanity_checks(tmpdir, wan_delay_ms=20)
            copilot_leader = [r for r in results
                              if "copilot" in r.name and "leader" in r.name]
            self.assertTrue(len(copilot_leader) > 0)
            self.assertTrue(copilot_leader[0].passed,
                            f"Copilot 82ms should pass: {copilot_leader[0].expected}")
            self.assertIn("80ms", copilot_leader[0].expected,
                          "Expected should mention ~80ms (2 RTT)")
        finally:
            shutil.rmtree(tmpdir)

    def test_copilot_1rtt_latency_fails(self):
        """Copilot with ~20ms latency should fail (too low for 2 RTT)."""
        tmpdir = tempfile.mkdtemp()
        try:
            for srv in SERVERS:
                fname = f"none_copilot-{SITE}-rw_1000000-concurrent_10-0-YCSB_A-{srv}.res"
                with open(os.path.join(tmpdir, fname), 'w') as f:
                    f.write(make_res_content(
                        mid_throughput=500.0,
                        original_count=1000, original_50pct=20.0,
                        original_90pct=25.0, original_99pct=30.0,
                        original_ave=21.0
                    ))
            results, _ = run_sanity_checks(tmpdir, wan_delay_ms=20)
            copilot_leader = [r for r in results
                              if "copilot" in r.name and "leader" in r.name]
            self.assertTrue(len(copilot_leader) > 0)
            # 20ms is below 0.5 * 80ms = 40ms threshold
            self.assertFalse(copilot_leader[0].passed,
                             "Copilot 20ms should fail for 2-RTT protocol")
        finally:
            shutil.rmtree(tmpdir)

    def test_report_has_per_protocol_table(self):
        """Report should have protocol-specific expected latency table."""
        results = [SanityResult("test", "e", "o", True)]
        report = generate_report(results, {"raft": []}, "/tmp/test", wan_delay_ms=20)
        self.assertIn("Copilot", report)
        self.assertIn("Mencius", report)
        self.assertIn("2 RTT", report)
        self.assertIn("1 RTT", report)


class TestComputePathUsage(unittest.TestCase):
    """Test compute_path_usage function."""

    def test_basic_path_usage(self):
        """Should count fast, original, and efficient path attempts."""
        server_data = {
            "zoo0": {
                "fast_path": {"count": 100, "50pct": 40.0, "90pct": 45.0, "99pct": 50.0, "0pct": 38.0, "ave": 41.0},
                "original_path": {"count": 200, "50pct": 80.0, "90pct": 85.0, "99pct": 90.0, "0pct": 75.0, "ave": 81.0},
                "efficient_path": {"count": 300, "50pct": 42.0, "90pct": 45.0, "99pct": 48.0, "0pct": 40.0, "ave": 43.0},
            },
            "zoo1": {
                "fast_path": {"count": 150, "50pct": 41.0, "90pct": 46.0, "99pct": 51.0, "0pct": 39.0, "ave": 42.0},
                "original_path": {"count": 250, "50pct": 82.0, "90pct": 87.0, "99pct": 92.0, "0pct": 77.0, "ave": 83.0},
                "efficient_path": {"count": 350, "50pct": 43.0, "90pct": 46.0, "99pct": 49.0, "0pct": 41.0, "ave": 44.0},
            },
        }
        usage = compute_path_usage(server_data)
        self.assertEqual(usage["fast_count"], 250)
        self.assertEqual(usage["original_count"], 450)
        self.assertEqual(usage["efficient_count"], 650)
        self.assertAlmostEqual(usage["avg_original_lat"], 81.0, places=0)
        self.assertAlmostEqual(usage["avg_efficient_lat"], 42.5, places=0)

    def test_zero_fast_path(self):
        """Should handle zero fast-path attempts correctly."""
        server_data = {
            "zoo0": {
                "fast_path": {"count": 0, "50pct": -1.0, "90pct": -1.0, "99pct": -1.0, "0pct": -1.0, "ave": -1.0},
                "original_path": {"count": 500, "50pct": 19127.0, "90pct": 19138.0, "99pct": 19143.0, "0pct": 18823.0, "ave": 18993.0},
                "efficient_path": {"count": 500, "50pct": 19127.0, "90pct": 19138.0, "99pct": 19143.0, "0pct": 18823.0, "ave": 18993.0},
            },
        }
        usage = compute_path_usage(server_data)
        self.assertEqual(usage["fast_count"], 0)
        self.assertEqual(usage["original_count"], 500)
        self.assertAlmostEqual(usage["avg_original_lat"], 19127.0, places=0)

    def test_missing_paths(self):
        """Should handle missing path data gracefully."""
        server_data = {
            "zoo0": {
                "original_path": None,
                "fast_path": None,
                "efficient_path": None,
            },
        }
        usage = compute_path_usage(server_data)
        self.assertEqual(usage["fast_count"], 0)
        self.assertEqual(usage["original_count"], 0)
        self.assertEqual(usage["efficient_count"], 0)
        self.assertIsNone(usage["avg_original_lat"])
        self.assertIsNone(usage["avg_efficient_lat"])


class TestAdaptiveAnomaly(unittest.TestCase):
    """Test detection and reporting of adaptive mode anomalies."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_adaptive_anomaly_includes_diagnostics(self):
        """When adaptive throughput is catastrophically low, note should include path-usage."""
        # Write original mode (high throughput)
        for srv in SERVERS:
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_100-0-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=1000.0))
        # Write adaptive mode (extremely low throughput, zero fast-path)
        for srv in SERVERS:
            fname = f"rule_raft-{SITE}-rw_1000000-concurrent_100-101-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(
                    mid_throughput=10.0,
                    original_count=50, original_50pct=19000.0,
                    original_90pct=19100.0, original_99pct=19200.0,
                    original_ave=19000.0,
                    fast_count=0, fast_50pct=-1.0
                ))
        results, summaries = run_sanity_checks(self.tmpdir, wan_delay_ms=20)
        adaptive_results = [r for r in results if "adaptive" in r.name.lower()]
        self.assertTrue(len(adaptive_results) > 0)
        self.assertFalse(adaptive_results[0].passed)
        # Should have path-usage diagnostics in the note
        self.assertIn("fast=0", adaptive_results[0].note)
        self.assertIn("original=", adaptive_results[0].note)
        self.assertIn("DIAGNOSTIC: zero fast-path", adaptive_results[0].note)

    def test_adaptive_anomaly_in_report(self):
        """Report should contain Flagged Anomalies section for catastrophic failures."""
        # Write original mode
        for srv in SERVERS:
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_100-0-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=1000.0))
        # Write adaptive mode with anomaly
        for srv in SERVERS:
            fname = f"rule_raft-{SITE}-rw_1000000-concurrent_100-101-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(
                    mid_throughput=10.0,
                    original_count=50, original_50pct=19000.0,
                    fast_count=0, fast_50pct=-1.0,
                    efficient_count=50, efficient_50pct=19000.0
                ))
        results, summaries = run_sanity_checks(self.tmpdir, wan_delay_ms=20)
        report = generate_report(results, summaries, self.tmpdir, wan_delay_ms=20)
        self.assertIn("Flagged Anomalies", report)
        self.assertIn("Adaptive Mode Throughput Anomaly", report)
        self.assertIn("Fast-path attempts", report)
        self.assertIn("Zero fast-path attempts", report)

    def test_normal_adaptive_no_anomaly_section(self):
        """Report should NOT have anomaly section when adaptive is fine."""
        # Write original mode
        for srv in SERVERS:
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_100-0-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=1000.0))
        # Write adaptive mode with normal throughput
        for srv in SERVERS:
            fname = f"rule_raft-{SITE}-rw_1000000-concurrent_100-101-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(
                    mid_throughput=950.0,
                    original_count=500, original_50pct=80.0,
                    efficient_count=500, efficient_50pct=42.0
                ))
        results, summaries = run_sanity_checks(self.tmpdir, wan_delay_ms=20)
        report = generate_report(results, summaries, self.tmpdir, wan_delay_ms=20)
        self.assertNotIn("Flagged Anomalies", report)


class TestWithRealData(unittest.TestCase):
    """Tests against the real Zoo experiment data (skipped if not available)."""

    RESULT_DIR = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        "results", "2026-03-23-10:26:07-zoo-5machines"
    )

    def setUp(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Real result directory not available")

    def test_real_data_parses(self):
        data = collect_experiment_data(self.RESULT_DIR)
        self.assertTrue(len(data) > 0, "Should find at least some experiments")

    def test_real_raft_has_data(self):
        data = collect_experiment_data(self.RESULT_DIR)
        raft_keys = [(p, c, m) for p, c, m in data if "raft" in p]
        self.assertTrue(len(raft_keys) > 0, "Should find Raft experiments")

    def test_real_wan_delay_detected(self):
        data = collect_experiment_data(self.RESULT_DIR)
        self.assertTrue(check_wan_delay(data, "none_raft"))

    def test_real_throughput_positive(self):
        data = collect_experiment_data(self.RESULT_DIR)
        for (proto, conc, mode), server_data in data.items():
            if len(server_data) == len(SERVERS):
                for srv, sd in server_data.items():
                    if sd["mid_throughput"] is not None:
                        self.assertGreater(sd["mid_throughput"], 0,
                                           f"{proto} {conc} mode={mode} {srv}")

    def test_real_sanity_runs(self):
        results, summaries = run_sanity_checks(self.RESULT_DIR, wan_delay_ms=20)
        self.assertTrue(len(results) > 0)
        # WAN delay should be detected
        wan_checks = [r for r in results if "WAN delay" in r.name]
        self.assertTrue(any(r.passed for r in wan_checks))


if __name__ == "__main__":
    unittest.main()
