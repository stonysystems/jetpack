#!/usr/bin/env python3
"""Tests for scripts/generate_summary.py"""

import os
import sys
import tempfile
import shutil
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from generate_summary import (
    scan_results,
    get_protocol_status,
    check_artifact,
    generate_summary,
    parse_mid_throughput,
    SERVERS,
    SITE,
)


def make_res_content(mid_throughput=100.0, wan_delay=True):
    """Generate minimal synthetic .res file content."""
    lines = []
    lines.append('I [s_main.cc:775] 2026-03-23 06:00:00.000 | starting process 12345')
    if wan_delay:
        lines.append('I [s_main.cc:793] 2026-03-23 06:00:00.000 | WAN delay enabled via WAN_DELAY_MS=20 (20000 us)')
    lines.append(f'I [s_main.cc:921] 2026-03-23 06:01:00.000 | Mid throughput is {mid_throughput:.2f}')
    return "\n".join(lines)


class TestParseMidThroughput(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_parses_throughput(self):
        path = os.path.join(self.tmpdir, "test.res")
        with open(path, 'w') as f:
            f.write(make_res_content(mid_throughput=1234.56))
        self.assertAlmostEqual(parse_mid_throughput(path), 1234.56)

    def test_missing_file(self):
        self.assertIsNone(parse_mid_throughput("/nonexistent.res"))

    def test_no_throughput_line(self):
        path = os.path.join(self.tmpdir, "test.res")
        with open(path, 'w') as f:
            f.write("some random content\n")
        self.assertIsNone(parse_mid_throughput(path))


class TestScanResults(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def write_experiment(self, protocol, conc, mode, servers=None, tp=100.0):
        if servers is None:
            servers = SERVERS
        for srv in servers:
            fname = f"{protocol}-{SITE}-rw_1000000-{conc}-{mode}-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=tp))

    def test_empty_dir(self):
        scan = scan_results(self.tmpdir)
        self.assertEqual(scan["total_configs"], 0)
        self.assertEqual(scan["complete_configs"], 0)

    def test_single_complete_experiment(self):
        self.write_experiment("none_raft", "concurrent_100", "0")
        scan = scan_results(self.tmpdir)
        self.assertEqual(scan["total_configs"], 1)
        self.assertEqual(scan["complete_configs"], 1)
        self.assertIn("none_raft", scan["protocols"])
        self.assertIn("0", scan["modes"])

    def test_incomplete_experiment(self):
        self.write_experiment("none_raft", "concurrent_100", "0", servers=SERVERS[:3])
        scan = scan_results(self.tmpdir)
        self.assertEqual(scan["total_configs"], 1)
        self.assertEqual(scan["complete_configs"], 0)

    def test_multiple_protocols(self):
        self.write_experiment("none_raft", "concurrent_100", "0")
        self.write_experiment("none_copilot", "concurrent_100", "0")
        scan = scan_results(self.tmpdir)
        self.assertEqual(scan["total_configs"], 2)
        self.assertEqual(scan["complete_configs"], 2)
        self.assertIn("none_raft", scan["protocols"])
        self.assertIn("none_copilot", scan["protocols"])

    def test_multiple_modes(self):
        self.write_experiment("none_raft", "concurrent_100", "0")
        self.write_experiment("rule_raft", "concurrent_100", "1")
        scan = scan_results(self.tmpdir)
        self.assertIn("0", scan["modes"])
        self.assertIn("1", scan["modes"])

    def test_res_file_count(self):
        self.write_experiment("none_raft", "concurrent_100", "0")  # 5 files
        scan = scan_results(self.tmpdir)
        self.assertEqual(scan["total_res_files"], 5)

    def test_ignores_non_res_files(self):
        with open(os.path.join(self.tmpdir, "README.md"), 'w') as f:
            f.write("not a res file")
        scan = scan_results(self.tmpdir)
        self.assertEqual(scan["total_res_files"], 0)


class TestGetProtocolStatus(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def write_experiment(self, protocol, conc, mode, tp=100.0):
        for srv in SERVERS:
            fname = f"{protocol}-{SITE}-rw_1000000-{conc}-{mode}-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=tp))

    def test_mode0_count(self):
        self.write_experiment("none_raft", "concurrent_10", "0", tp=50.0)
        self.write_experiment("none_raft", "concurrent_100", "0", tp=200.0)
        scan = scan_results(self.tmpdir)
        status = get_protocol_status(scan, "Raft", "none_raft", "rule_raft")
        self.assertEqual(status["mode0_concs"], 2)

    def test_peak_throughput(self):
        self.write_experiment("none_raft", "concurrent_10", "0", tp=50.0)
        self.write_experiment("none_raft", "concurrent_100", "0", tp=200.0)
        scan = scan_results(self.tmpdir)
        status = get_protocol_status(scan, "Raft", "none_raft", "rule_raft")
        self.assertAlmostEqual(status["max_throughput"], 1000.0)  # 200 * 5
        self.assertEqual(status["best_conc"], "concurrent_100")

    def test_mixed_modes(self):
        self.write_experiment("none_raft", "concurrent_100", "0")
        self.write_experiment("rule_raft", "concurrent_100", "1")
        self.write_experiment("rule_raft", "concurrent_100", "101")
        scan = scan_results(self.tmpdir)
        status = get_protocol_status(scan, "Raft", "none_raft", "rule_raft")
        self.assertEqual(status["mode0_concs"], 1)
        self.assertEqual(status["mode1_concs"], 1)
        self.assertEqual(status["mode101_concs"], 1)
        self.assertEqual(status["total_complete"], 3)

    def test_no_data(self):
        scan = scan_results(self.tmpdir)
        status = get_protocol_status(scan, "Copilot", "none_copilot", "rule_copilot")
        self.assertEqual(status["total_complete"], 0)
        self.assertIsNone(status["best_conc"])


class TestCheckArtifact(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_existing_artifact(self):
        path = os.path.join(self.tmpdir, "test.md")
        with open(path, 'w') as f:
            f.write("content")
        exists, info = check_artifact(self.tmpdir, "test.md")
        self.assertTrue(exists)
        self.assertIn("bytes", info)

    def test_missing_artifact(self):
        exists, info = check_artifact(self.tmpdir, "nonexistent.md")
        self.assertFalse(exists)
        self.assertEqual(info, "missing")


class TestGenerateSummary(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_summary_contains_header(self):
        summary = generate_summary(self.tmpdir)
        self.assertIn("# Zoo 5-Machine Experiment Summary", summary)

    def test_summary_contains_config(self):
        summary = generate_summary(self.tmpdir)
        self.assertIn("30c1s5r5p-zoo", summary)
        self.assertIn("WAN_DELAY_MS=20", summary)
        self.assertIn("Open-loop", summary)

    def test_summary_contains_protocol_table(self):
        summary = generate_summary(self.tmpdir)
        self.assertIn("Per-Protocol Status", summary)
        self.assertIn("Raft", summary)
        self.assertIn("Copilot", summary)
        self.assertIn("Mencius", summary)
        self.assertIn("MongoDB", summary)
        self.assertIn("etcd", summary)
        self.assertIn("ZooKeeper", summary)

    def test_summary_contains_experiment_defs(self):
        summary = generate_summary(self.tmpdir)
        self.assertIn("Experiment 0", summary)
        self.assertIn("Experiment 1", summary)
        self.assertIn("Experiment 2", summary)

    def test_summary_contains_artifact_table(self):
        summary = generate_summary(self.tmpdir)
        self.assertIn("Artifacts", summary)
        self.assertIn("SUMMARY.md", summary)
        self.assertIn("sanity_checks.md", summary)

    def test_summary_with_data(self):
        for srv in SERVERS:
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_100-0-YCSB_A-{srv}.res"
            with open(os.path.join(self.tmpdir, fname), 'w') as f:
                f.write(make_res_content(mid_throughput=200.0))
        summary = generate_summary(self.tmpdir)
        self.assertIn("none_raft", summary)
        self.assertIn("1000", summary)  # 200 * 5 = 1000 throughput

    def test_summary_shows_progress(self):
        summary = generate_summary(self.tmpdir)
        self.assertIn("Progress", summary)
        self.assertIn("Total .res files", summary)


class TestWithRealData(unittest.TestCase):
    """Tests against real data if available."""

    RESULT_DIR = os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        "results", "2026-03-23-10:26:07-zoo-5machines"
    )

    def setUp(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Real result directory not available")

    def test_real_scan(self):
        scan = scan_results(self.RESULT_DIR)
        self.assertGreater(scan["total_res_files"], 0)
        self.assertGreater(scan["complete_configs"], 0)

    def test_real_summary_generation(self):
        summary = generate_summary(self.RESULT_DIR)
        self.assertIn("Zoo 5-Machine", summary)
        self.assertIn("none_raft", summary)

    def test_real_artifacts_present(self):
        exists, _ = check_artifact(self.RESULT_DIR, "LATENCY_MECHANISM.md")
        self.assertTrue(exists)


if __name__ == "__main__":
    unittest.main()
