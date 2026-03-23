#!/usr/bin/env python3
"""Tests for generate_experiment_report.py."""

import json
import os
import re
import sys
import tempfile
import shutil
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import generate_experiment_report as ger

SITE = "30c1s5r5p-zoo"
SERVERS = [f"zoo{i}" for i in range(5)]


class TestParseResFile(unittest.TestCase):
    """Test .res file parsing."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_report_")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_res(self, content):
        path = os.path.join(self.tmpdir, "test.res")
        with open(path, "w") as f:
            f.write(content)
        return path

    def test_parse_throughput(self):
        path = self._write_res(
            "I [s_main.cc:921] 2026-01-01 | Mid throughput is 1234.56\n"
        )
        m = ger.parse_res_file(path)
        self.assertAlmostEqual(m["throughput"], 1234.56)

    def test_parse_latency_stats(self):
        path = self._write_res(
            "I [s_main.cc:908] | All-original-path-attempts       statistics   "
            "count    17994   0pct    68.75  50pct    80.86  90pct    88.88  "
            "99pct   206.25    ave    85.02\n"
        )
        m = ger.parse_res_file(path)
        self.assertEqual(m["count"], 17994)
        self.assertAlmostEqual(m["p50"], 80.86)
        self.assertAlmostEqual(m["p90"], 88.88)
        self.assertAlmostEqual(m["p99"], 206.25)
        self.assertAlmostEqual(m["ave"], 85.02)

    def test_parse_missing_file(self):
        m = ger.parse_res_file("/nonexistent/file.res")
        self.assertEqual(m, {})

    def test_parse_empty_file(self):
        path = self._write_res("")
        m = ger.parse_res_file(path)
        self.assertEqual(m, {})

    def test_parse_both_metrics(self):
        path = self._write_res(
            "I | Mid throughput is 500.0\n"
            "I | All-original-path-attempts       statistics   "
            "count    1000   0pct    10.0  50pct    20.0  90pct    30.0  "
            "99pct   40.0    ave    25.0\n"
        )
        m = ger.parse_res_file(path)
        self.assertAlmostEqual(m["throughput"], 500.0)
        self.assertAlmostEqual(m["p50"], 20.0)
        self.assertAlmostEqual(m["ave"], 25.0)


class TestCollectData(unittest.TestCase):
    """Test data collection from result directories."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_report_")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_res_files(self, protocol, conc, mode, throughputs, latencies=None):
        for i, tp in enumerate(throughputs):
            fname = f"{protocol}-{SITE}-rw_1000000-{conc}-{mode}-YCSB_A-zoo{i}.res"
            path = os.path.join(self.tmpdir, fname)
            lat = latencies[i] if latencies else (50.0, 70.0, 100.0, 60.0)
            p50, p90, p99, ave = lat
            with open(path, "w") as f:
                f.write(f"I | Mid throughput is {tp}\n")
                f.write(
                    f"I | All-original-path-attempts       statistics   "
                    f"count    1000   0pct    10.0  50pct    {p50}  90pct    {p90}  "
                    f"99pct   {p99}    ave    {ave}\n"
                )

    def test_collect_single_protocol(self):
        self._write_res_files("none_raft", "concurrent_10", "0",
                              [100, 100, 100, 100, 100])
        data = ger.collect_data(self.tmpdir)
        self.assertIn("none_raft", data)
        self.assertIn("0", data["none_raft"])
        self.assertAlmostEqual(
            data["none_raft"]["0"]["concurrent_10"]["throughput"], 500.0
        )

    def test_collect_latency_averaging(self):
        lats = [(40, 60, 80, 50), (50, 70, 90, 60), (60, 80, 100, 70),
                (50, 70, 90, 60), (50, 70, 90, 60)]
        self._write_res_files("none_raft", "concurrent_10", "0",
                              [100] * 5, lats)
        data = ger.collect_data(self.tmpdir)
        metrics = data["none_raft"]["0"]["concurrent_10"]
        self.assertAlmostEqual(metrics["p50"], 50.0)  # avg of 40,50,60,50,50
        self.assertAlmostEqual(metrics["p90"], 70.0)  # avg of 60,70,80,70,70

    def test_collect_incomplete_servers_skipped(self):
        # Only 3 of 5 servers
        for i in range(3):
            fname = f"none_raft-{SITE}-rw_1000000-concurrent_10-0-YCSB_A-zoo{i}.res"
            path = os.path.join(self.tmpdir, fname)
            with open(path, "w") as f:
                f.write("I | Mid throughput is 100\n")
        data = ger.collect_data(self.tmpdir)
        # Should not have aggregated data
        self.assertNotIn("concurrent_10", data.get("none_raft", {}).get("0", {}))

    def test_collect_multiple_modes(self):
        self._write_res_files("none_raft", "concurrent_10", "0",
                              [100] * 5)
        self._write_res_files("none_raft", "concurrent_10", "101",
                              [90] * 5)
        data = ger.collect_data(self.tmpdir)
        self.assertAlmostEqual(
            data["none_raft"]["0"]["concurrent_10"]["throughput"], 500.0
        )
        self.assertAlmostEqual(
            data["none_raft"]["101"]["concurrent_10"]["throughput"], 450.0
        )

    def test_collect_multiple_concurrencies(self):
        self._write_res_files("none_raft", "concurrent_10", "0", [100] * 5)
        self._write_res_files("none_raft", "concurrent_20", "0", [200] * 5)
        data = ger.collect_data(self.tmpdir)
        self.assertAlmostEqual(
            data["none_raft"]["0"]["concurrent_10"]["throughput"], 500.0
        )
        self.assertAlmostEqual(
            data["none_raft"]["0"]["concurrent_20"]["throughput"], 1000.0
        )

    def test_collect_empty_dir(self):
        data = ger.collect_data(self.tmpdir)
        self.assertEqual(data, {})


class TestFindPeak(unittest.TestCase):
    """Test peak throughput finding."""

    def test_find_peak_simple(self):
        mode_data = {
            "concurrent_10": {"throughput": 500},
            "concurrent_20": {"throughput": 900},
            "concurrent_40": {"throughput": 800},
        }
        conc, tp = ger.find_peak(mode_data)
        self.assertEqual(conc, "concurrent_20")
        self.assertEqual(tp, 900)

    def test_find_peak_empty(self):
        conc, tp = ger.find_peak({})
        self.assertIsNone(conc)
        self.assertEqual(tp, 0)

    def test_find_peak_single(self):
        mode_data = {"concurrent_10": {"throughput": 500}}
        conc, tp = ger.find_peak(mode_data)
        self.assertEqual(conc, "concurrent_10")
        self.assertEqual(tp, 500)


class TestCheckArtifact(unittest.TestCase):
    """Test artifact checking."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_report_")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_missing_file(self):
        result = ger.check_artifact(self.tmpdir, "missing.md")
        self.assertEqual(result, "missing")

    def test_present_file(self):
        path = os.path.join(self.tmpdir, "test.md")
        with open(path, "w") as f:
            f.write("content")
        result = ger.check_artifact(self.tmpdir, "test.md")
        self.assertIn("present", result)
        self.assertIn("bytes", result)

    def test_present_dir(self):
        dirpath = os.path.join(self.tmpdir, "figs")
        os.makedirs(dirpath)
        with open(os.path.join(dirpath, "a.pdf"), "w") as f:
            f.write("pdf")
        result = ger.check_artifact(self.tmpdir, "figs")
        self.assertIn("present", result)
        self.assertIn("1 files", result)

    def test_empty_dir(self):
        dirpath = os.path.join(self.tmpdir, "tables")
        os.makedirs(dirpath)
        result = ger.check_artifact(self.tmpdir, "tables")
        self.assertIn("present", result)
        self.assertIn("0 files", result)


class TestGenerateReport(unittest.TestCase):
    """Test full report generation."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_report_")
        self.result_dir = os.path.join(self.tmpdir, "results",
                                       "2026-01-01-00:00:00-zoo-5machines")
        os.makedirs(self.result_dir)
        os.makedirs(os.path.join(self.result_dir, "figs"))
        os.makedirs(os.path.join(self.result_dir, "tables"))

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_res_files(self, protocol, conc, mode, throughputs):
        for i, tp in enumerate(throughputs):
            fname = f"{protocol}-{SITE}-rw_1000000-{conc}-{mode}-YCSB_A-zoo{i}.res"
            path = os.path.join(self.result_dir, fname)
            with open(path, "w") as f:
                f.write(f"I | Mid throughput is {tp}\n")
                f.write(
                    f"I | All-original-path-attempts       statistics   "
                    f"count    1000   0pct    10.0  50pct    50.0  90pct    70.0  "
                    f"99pct   100.0    ave    55.0\n"
                )

    def test_report_has_header(self):
        report = ger.generate_report(self.result_dir)
        self.assertIn("# Zoo 5-Machine Experiment Report", report)
        self.assertIn("Generated", report)

    def test_report_shows_no_data(self):
        report = ger.generate_report(self.result_dir)
        self.assertIn("No data available yet", report)
        self.assertIn("0 of 6", report)

    def test_report_shows_data(self):
        self._write_res_files("none_raft", "concurrent_10", "0", [100] * 5)
        report = ger.generate_report(self.result_dir)
        self.assertIn("raft", report.lower())
        self.assertIn("500 txn/s", report)
        self.assertIn("1 of 6", report)

    def test_report_artifacts_section(self):
        report = ger.generate_report(self.result_dir)
        self.assertIn("## Artifacts", report)
        self.assertIn("EXPERIMENT_REPORT.md", report)
        self.assertIn("SUMMARY.md", report)

    def test_report_references_section(self):
        report = ger.generate_report(self.result_dir)
        self.assertIn("## References", report)
        self.assertIn("sanity_checks.md", report)
        self.assertIn("run_evaluation.sh", report)

    def test_report_with_fixed_conc(self):
        # Write fixed_conc.json
        fc_path = os.path.join(self.tmpdir, "results", "fixed_conc.json")
        with open(fc_path, "w") as f:
            json.dump({"none_raft": "concurrent_10", "Raft": "concurrent_10"}, f)
        self._write_res_files("none_raft", "concurrent_10", "0", [100] * 5)
        report = ger.generate_report(self.result_dir)
        self.assertIn("Fixed Concurrency Map", report)
        self.assertIn("concurrent_10", report)

    def test_report_comparison_table(self):
        fc_path = os.path.join(self.tmpdir, "results", "fixed_conc.json")
        with open(fc_path, "w") as f:
            json.dump({"none_raft": "concurrent_10"}, f)
        self._write_res_files("none_raft", "concurrent_10", "0", [100] * 5)
        self._write_res_files("none_raft", "concurrent_10", "101", [90] * 5)
        report = ger.generate_report(self.result_dir)
        self.assertIn("Comparison at concurrent_10", report)
        self.assertIn("Original", report)
        self.assertIn("Adaptive", report)

    def test_report_multiple_protocols(self):
        self._write_res_files("none_raft", "concurrent_10", "0", [100] * 5)
        self._write_res_files("none_copilot", "concurrent_10", "0", [200] * 5)
        report = ger.generate_report(self.result_dir)
        self.assertIn("2 of 6", report)
        self.assertIn("### Raft", report)
        self.assertIn("### Copilot", report)


class TestWithRealData(unittest.TestCase):
    """Test with real Zoo result data if available."""

    RESULT_DIR = os.path.join(
        os.path.dirname(SCRIPT_DIR),
        "results", "2026-03-23-10:26:07-zoo-5machines"
    )

    def test_real_report_generation(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Zoo result directory not available")
        report = ger.generate_report(self.RESULT_DIR)
        self.assertIn("Zoo 5-Machine Experiment Report", report)
        self.assertIn("none_raft", report)

    def test_real_data_collection(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Zoo result directory not available")
        data = ger.collect_data(self.RESULT_DIR)
        self.assertIn("none_raft", data)
        # Should have mode 0 data
        self.assertIn("0", data["none_raft"])

    def test_real_latency_nonzero(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Zoo result directory not available")
        data = ger.collect_data(self.RESULT_DIR)
        # At least one concurrency should have nonzero p50
        for conc, metrics in data.get("none_raft", {}).get("0", {}).items():
            if metrics["p50"] > 0:
                return
        self.fail("No nonzero p50 latency found in real data")


if __name__ == "__main__":
    unittest.main(verbosity=2)
