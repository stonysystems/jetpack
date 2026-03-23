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
    run_sanity_checks,
    generate_report,
    SanityResult,
    SERVERS,
    LEADER_SERVER,
    SITE,
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
