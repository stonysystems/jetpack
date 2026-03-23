#!/usr/bin/env python3
"""Tests for generate_tables.py."""

import csv
import json
import os
import sys
import tempfile
import shutil
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)
import generate_tables as gt

SITE = "30c1s5r5p-zoo"


def write_res_file(tmpdir, protocol, conc, mode, server, throughput,
                   p50=50.0, p90=70.0, p99=100.0, ave=55.0,
                   fp_count=0, fp_p50=-1.0, fp_p90=-1.0, fp_p99=-1.0, fp_ave=-1.0,
                   workload="rw_1000000"):
    """Write a synthetic .res file."""
    fname = f"{protocol}-{SITE}-{workload}-{conc}-{mode}-YCSB_A-{server}.res"
    path = os.path.join(tmpdir, fname)
    with open(path, "w") as f:
        f.write(f"I | Mid throughput is {throughput}\n")
        f.write(
            f"I | All-fast-path-attempts           statistics   "
            f"count {fp_count:>8}   0pct {fp_p50:>8.2f}  50pct {fp_p50:>8.2f}  "
            f"90pct {fp_p90:>8.2f}  99pct {fp_p99:>8.2f}    ave {fp_ave:>8.2f}\n"
        )
        f.write(
            f"I | All-original-path-attempts       statistics   "
            f"count     1000   0pct    10.00  50pct {p50:>8.2f}  "
            f"90pct {p90:>8.2f}  99pct {p99:>8.2f}    ave {ave:>8.2f}\n"
        )


def write_full_conc(tmpdir, protocol, conc, mode, throughputs, **kwargs):
    """Write .res files for all 5 servers."""
    for i, tp in enumerate(throughputs):
        write_res_file(tmpdir, protocol, conc, mode, f"zoo{i}", tp, **kwargs)


class TestParseResFile(unittest.TestCase):
    """Test .res file parsing."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_parse_throughput(self):
        write_res_file(self.tmpdir, "none_raft", "concurrent_10", "0", "zoo0", 1234.5)
        path = os.path.join(self.tmpdir, os.listdir(self.tmpdir)[0])
        m = gt.parse_res_file(path)
        self.assertAlmostEqual(m["throughput"], 1234.5)

    def test_parse_latency(self):
        write_res_file(self.tmpdir, "none_raft", "concurrent_10", "0", "zoo0", 100,
                       p50=80.0, p90=90.0, p99=200.0, ave=85.0)
        path = os.path.join(self.tmpdir, os.listdir(self.tmpdir)[0])
        m = gt.parse_res_file(path)
        self.assertAlmostEqual(m["p50"], 80.0)
        self.assertAlmostEqual(m["p90"], 90.0)
        self.assertAlmostEqual(m["p99"], 200.0)
        self.assertAlmostEqual(m["ave"], 85.0)

    def test_parse_fast_path_stats(self):
        write_res_file(self.tmpdir, "rule_raft", "concurrent_10", "100", "zoo0", 100,
                       fp_count=500, fp_p50=20.0, fp_p90=30.0, fp_p99=40.0, fp_ave=25.0)
        path = os.path.join(self.tmpdir, os.listdir(self.tmpdir)[0])
        m = gt.parse_res_file(path)
        self.assertEqual(m["fp_count"], 500)
        self.assertAlmostEqual(m["fp_p50"], 20.0)

    def test_parse_missing_file(self):
        m = gt.parse_res_file("/nonexistent")
        self.assertEqual(m, {})


class TestCollectAllData(unittest.TestCase):
    """Test data collection."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_collect_single_experiment(self):
        write_full_conc(self.tmpdir, "none_raft", "concurrent_10", "0", [100] * 5)
        raw = gt.collect_all_data(self.tmpdir)
        key = ("none_raft", "rw_1000000", "0", "concurrent_10")
        self.assertIn(key, raw)
        self.assertEqual(len(raw[key]), 5)

    def test_collect_multiple_modes(self):
        write_full_conc(self.tmpdir, "none_raft", "concurrent_10", "0", [100] * 5)
        write_full_conc(self.tmpdir, "none_raft", "concurrent_10", "101", [90] * 5)
        raw = gt.collect_all_data(self.tmpdir)
        self.assertIn(("none_raft", "rw_1000000", "0", "concurrent_10"), raw)
        self.assertIn(("none_raft", "rw_1000000", "101", "concurrent_10"), raw)

    def test_collect_empty_dir(self):
        raw = gt.collect_all_data(self.tmpdir)
        self.assertEqual(len(raw), 0)

    def test_collect_zipf_workload(self):
        write_full_conc(self.tmpdir, "none_raft", "concurrent_100", "0", [100] * 5,
                        workload="rw_zipf_0.5")
        raw = gt.collect_all_data(self.tmpdir)
        key = ("none_raft", "rw_zipf_0.5", "0", "concurrent_100")
        self.assertIn(key, raw)


class TestAggregate(unittest.TestCase):
    """Test aggregation logic."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_aggregate_sums_throughput(self):
        write_full_conc(self.tmpdir, "none_raft", "concurrent_10", "0",
                        [100, 200, 150, 120, 130])
        raw = gt.collect_all_data(self.tmpdir)
        rows = gt.aggregate(raw)
        self.assertEqual(len(rows), 1)
        self.assertAlmostEqual(rows[0]["total_throughput"], 700.0)

    def test_aggregate_averages_latency(self):
        write_full_conc(self.tmpdir, "none_raft", "concurrent_10", "0",
                        [100] * 5, p50=80.0, p90=90.0, p99=200.0, ave=85.0)
        raw = gt.collect_all_data(self.tmpdir)
        rows = gt.aggregate(raw)
        self.assertAlmostEqual(rows[0]["avg_p50"], 80.0)
        self.assertAlmostEqual(rows[0]["avg_p90"], 90.0)

    def test_aggregate_skips_incomplete(self):
        # Only 3 of 5 servers
        for i in range(3):
            write_res_file(self.tmpdir, "none_raft", "concurrent_10", "0",
                           f"zoo{i}", 100)
        raw = gt.collect_all_data(self.tmpdir)
        rows = gt.aggregate(raw)
        self.assertEqual(len(rows), 0)

    def test_aggregate_mode_labels(self):
        write_full_conc(self.tmpdir, "none_raft", "concurrent_10", "0", [100] * 5)
        write_full_conc(self.tmpdir, "none_raft", "concurrent_10", "101", [90] * 5)
        raw = gt.collect_all_data(self.tmpdir)
        rows = gt.aggregate(raw)
        labels = {r["mode_label"] for r in rows}
        self.assertIn("original", labels)
        self.assertIn("adaptive", labels)

    def test_aggregate_empty(self):
        rows = gt.aggregate({})
        self.assertEqual(rows, [])


class TestGenerateFixedConcTable(unittest.TestCase):
    """Test fixed_conc_table.csv generation."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")
        self.result_dir = os.path.join(self.tmpdir, "results", "test-run")
        self.tables_dir = os.path.join(self.result_dir, "tables")
        os.makedirs(self.tables_dir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_generates_csv(self):
        fc_path = os.path.join(self.tmpdir, "results", "fixed_conc.json")
        with open(fc_path, "w") as f:
            json.dump({"none_raft": "concurrent_400", "Raft": "concurrent_400"}, f)
        path = gt.generate_fixed_conc_table(self.tables_dir, self.result_dir)
        self.assertIsNotNone(path)
        self.assertTrue(os.path.isfile(path))
        with open(path) as f:
            reader = csv.DictReader(f)
            rows = list(reader)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1]["fixed_concurrency"], "concurrent_400")

    def test_returns_none_when_missing(self):
        path = gt.generate_fixed_conc_table(self.tables_dir, self.result_dir)
        self.assertIsNone(path)


class TestGenerateExperiment0Summary(unittest.TestCase):
    """Test experiment0_summary.csv generation."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")
        self.result_dir = os.path.join(self.tmpdir, "results", "test-run")
        self.tables_dir = os.path.join(self.result_dir, "tables")
        os.makedirs(self.tables_dir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_generates_summary(self):
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [100] * 5, p50=50.0, p90=70.0, p99=100.0, ave=55.0)
        write_full_conc(self.result_dir, "none_raft", "concurrent_20", "0",
                        [200] * 5, p50=60.0, p90=80.0, p99=120.0, ave=65.0)
        raw = gt.collect_all_data(self.result_dir)
        rows = gt.aggregate(raw)
        path = gt.generate_experiment0_summary(self.tables_dir, rows)
        self.assertIsNotNone(path)
        with open(path) as f:
            reader = csv.DictReader(f)
            csv_rows = list(reader)
        # Should pick peak (concurrent_20 = 1000 total)
        self.assertEqual(len(csv_rows), 1)
        self.assertEqual(csv_rows[0]["peak_concurrency"], "concurrent_20")
        self.assertAlmostEqual(float(csv_rows[0]["peak_throughput"]), 1000.0)

    def test_returns_none_when_empty(self):
        path = gt.generate_experiment0_summary(self.tables_dir, [])
        self.assertIsNone(path)

    def test_filters_to_rw_1000000(self):
        # Write both rw_1000000 and rw_zipf_0.5
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [100] * 5)
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [200] * 5, workload="rw_zipf_0.5")
        raw = gt.collect_all_data(self.result_dir)
        rows = gt.aggregate(raw)
        path = gt.generate_experiment0_summary(self.tables_dir, rows)
        with open(path) as f:
            reader = csv.DictReader(f)
            csv_rows = list(reader)
        # Only rw_1000000 should appear
        self.assertEqual(len(csv_rows), 1)
        self.assertAlmostEqual(float(csv_rows[0]["peak_throughput"]), 500.0)


class TestGenerateThroughputVsConc(unittest.TestCase):
    """Test throughput_vs_conc.csv generation."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")
        self.result_dir = os.path.join(self.tmpdir, "results", "test-run")
        self.tables_dir = os.path.join(self.result_dir, "tables")
        os.makedirs(self.tables_dir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_generates_csv(self):
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [100] * 5)
        write_full_conc(self.result_dir, "none_raft", "concurrent_20", "0",
                        [200] * 5)
        raw = gt.collect_all_data(self.result_dir)
        rows = gt.aggregate(raw)
        path = gt.generate_throughput_vs_conc(self.tables_dir, rows)
        self.assertIsNotNone(path)
        with open(path) as f:
            reader = csv.DictReader(f)
            csv_rows = list(reader)
        self.assertEqual(len(csv_rows), 2)
        # Should be sorted by concurrency
        self.assertEqual(int(csv_rows[0]["concurrency"]), 10)
        self.assertEqual(int(csv_rows[1]["concurrency"]), 20)

    def test_includes_mode_label(self):
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "101",
                        [100] * 5)
        raw = gt.collect_all_data(self.result_dir)
        rows = gt.aggregate(raw)
        path = gt.generate_throughput_vs_conc(self.tables_dir, rows)
        with open(path) as f:
            reader = csv.DictReader(f)
            csv_rows = list(reader)
        self.assertEqual(csv_rows[0]["mode_label"], "adaptive")


class TestGenerateLatencyVsConc(unittest.TestCase):
    """Test latency_vs_conc.csv generation."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")
        self.result_dir = os.path.join(self.tmpdir, "results", "test-run")
        self.tables_dir = os.path.join(self.result_dir, "tables")
        os.makedirs(self.tables_dir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_generates_csv_with_all_fields(self):
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [100] * 5, p50=80.0, p90=90.0, p99=200.0, ave=85.0)
        raw = gt.collect_all_data(self.result_dir)
        rows = gt.aggregate(raw)
        path = gt.generate_latency_vs_conc(self.tables_dir, rows)
        self.assertIsNotNone(path)
        with open(path) as f:
            reader = csv.DictReader(f)
            csv_rows = list(reader)
        self.assertEqual(len(csv_rows), 1)
        row = csv_rows[0]
        self.assertAlmostEqual(float(row["p50"]), 80.0)
        self.assertAlmostEqual(float(row["p90"]), 90.0)
        self.assertAlmostEqual(float(row["p99"]), 200.0)
        self.assertIn("fp_p50", row)


class TestGenerateTables(unittest.TestCase):
    """Test the top-level generate_tables function."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="test_tables_")
        self.result_dir = os.path.join(self.tmpdir, "results", "test-run")
        os.makedirs(self.result_dir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_empty_dir_returns_empty(self):
        generated = gt.generate_tables(self.result_dir)
        self.assertEqual(generated, [])

    def test_with_data_generates_three_csvs(self):
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [100] * 5)
        generated = gt.generate_tables(self.result_dir)
        # No fixed_conc.json, so 3 tables (summary, throughput, latency)
        self.assertEqual(len(generated), 3)
        for path in generated:
            self.assertTrue(os.path.isfile(path))

    def test_with_fixed_conc_generates_four_csvs(self):
        fc_path = os.path.join(self.tmpdir, "results", "fixed_conc.json")
        with open(fc_path, "w") as f:
            json.dump({"none_raft": "concurrent_10"}, f)
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [100] * 5)
        generated = gt.generate_tables(self.result_dir)
        self.assertEqual(len(generated), 4)

    def test_creates_tables_dir(self):
        write_full_conc(self.result_dir, "none_raft", "concurrent_10", "0",
                        [100] * 5)
        tables_dir = os.path.join(self.result_dir, "tables")
        self.assertFalse(os.path.exists(tables_dir))
        gt.generate_tables(self.result_dir)
        self.assertTrue(os.path.isdir(tables_dir))


class TestWithRealData(unittest.TestCase):
    """Test with real Zoo result data if available."""

    RESULT_DIR = os.path.join(REPO_ROOT, "results", "2026-03-23-10:26:07-zoo-5machines")

    def test_real_table_generation(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Zoo result directory not available")
        tables_dir = os.path.join(self.RESULT_DIR, "tables")
        generated = gt.generate_tables(self.RESULT_DIR)
        self.assertGreater(len(generated), 0)

    def test_real_data_has_latency(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Zoo result directory not available")
        raw = gt.collect_all_data(self.RESULT_DIR)
        rows = gt.aggregate(raw)
        # At least one row should have nonzero p50
        has_nonzero = any(r["avg_p50"] > 0 for r in rows)
        self.assertTrue(has_nonzero, "No nonzero p50 latency in real data")

    def test_real_experiment0_summary(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Zoo result directory not available")
        raw = gt.collect_all_data(self.RESULT_DIR)
        rows = gt.aggregate(raw)
        tables_dir = os.path.join(self.RESULT_DIR, "tables")
        os.makedirs(tables_dir, exist_ok=True)
        path = gt.generate_experiment0_summary(tables_dir, rows)
        self.assertIsNotNone(path)
        with open(path) as f:
            reader = csv.DictReader(f)
            csv_rows = list(reader)
        self.assertGreater(len(csv_rows), 0)
        # Peak throughput should be positive
        for row in csv_rows:
            self.assertGreater(float(row["peak_throughput"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
