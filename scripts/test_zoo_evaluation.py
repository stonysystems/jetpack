#!/usr/bin/env python3
"""
Tests for Zoo 5-machine evaluation infrastructure:
- derive_fixed_conc.py correctness
- evaluation.ipynb structural integrity (protocols, sites, server names)
- Result file pattern matching
"""

import json
import os
import re
import sys
import ast
import tempfile
import shutil
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

# Import derive_fixed_conc module
sys.path.insert(0, SCRIPT_DIR)
import derive_fixed_conc


class TestDeriveFixedConc(unittest.TestCase):
    """Test the fixed-concurrency derivation logic."""

    def setUp(self):
        """Create a temporary result directory with synthetic .res files."""
        self.tmpdir = tempfile.mkdtemp(prefix="test_zoo_eval_")
        self.servers = [f"zoo{i}" for i in range(5)]
        self.site = "30c1s5r5p-zoo"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_res(self, protocol, conc, mode, ycsb, server, throughput):
        """Write a synthetic .res file with a Mid throughput line."""
        fname = f"{protocol}-{self.site}-rw_1000000-{conc}-{mode}-{ycsb}-{server}.res"
        path = os.path.join(self.tmpdir, fname)
        with open(path, 'w') as f:
            f.write(f"I [s_main.cc:921] 2026-01-01 00:00:00.000 | Mid throughput is {throughput}\n")

    def _write_full_conc(self, protocol, conc, mode, ycsb, throughputs):
        """Write .res files for all 5 servers with given per-server throughputs."""
        for i, tp in enumerate(throughputs):
            self._write_res(protocol, conc, mode, ycsb, f"zoo{i}", tp)

    def test_parse_mid_throughput(self):
        """parse_mid_throughput extracts the correct value."""
        path = os.path.join(self.tmpdir, "test.res")
        with open(path, 'w') as f:
            f.write("some log line\n")
            f.write("I [s_main.cc:921] 2026-01-01 | Mid throughput is 1234.56\n")
            f.write("more log\n")
        self.assertAlmostEqual(derive_fixed_conc.parse_mid_throughput(path), 1234.56)

    def test_parse_missing_file(self):
        """parse_mid_throughput returns None for missing file."""
        self.assertIsNone(derive_fixed_conc.parse_mid_throughput("/nonexistent/file.res"))

    def test_parse_no_throughput_line(self):
        """parse_mid_throughput returns None when no throughput line exists."""
        path = os.path.join(self.tmpdir, "empty.res")
        with open(path, 'w') as f:
            f.write("no throughput here\n")
        self.assertIsNone(derive_fixed_conc.parse_mid_throughput(path))

    def test_collect_throughputs_single_protocol(self):
        """collect_throughputs sums per-server throughputs correctly."""
        # Each server reports 100 txn/s at concurrent_10
        self._write_full_conc("none_raft", "concurrent_10", "0", "YCSB_A",
                              [100, 100, 100, 100, 100])
        data = derive_fixed_conc.collect_throughputs(self.tmpdir, self.site, self.servers)
        self.assertIn("none_raft", data)
        self.assertAlmostEqual(data["none_raft"]["concurrent_10"]["0"], 500.0)

    def test_collect_throughputs_incomplete_servers(self):
        """collect_throughputs skips entries with missing servers."""
        # Only 3 of 5 servers
        for i in range(3):
            self._write_res("none_raft", "concurrent_10", "0", "YCSB_A",
                           f"zoo{i}", 100)
        data = derive_fixed_conc.collect_throughputs(self.tmpdir, self.site, self.servers)
        # Should have no data (incomplete)
        self.assertEqual(len(data.get("none_raft", {}).get("concurrent_10", {})), 0)

    def test_find_max_throughput_conc(self):
        """find_max_throughput_conc picks the highest throughput concurrency."""
        protocol_data = {
            "concurrent_10": {"0": 500},
            "concurrent_20": {"0": 900},
            "concurrent_40": {"0": 800},  # saturated, drops
        }
        best_conc, best_tp, all_results = derive_fixed_conc.find_max_throughput_conc(
            protocol_data, mode="0"
        )
        self.assertEqual(best_conc, "concurrent_20")
        self.assertAlmostEqual(best_tp, 900)
        self.assertEqual(len(all_results), 3)

    def test_end_to_end_derivation(self):
        """Full end-to-end: create synthetic results, derive fixed conc, verify output."""
        # Raft: peaks at concurrent_20
        self._write_full_conc("none_raft", "concurrent_10", "0", "YCSB_A",
                              [50, 50, 50, 50, 50])
        self._write_full_conc("none_raft", "concurrent_20", "0", "YCSB_A",
                              [100, 100, 100, 100, 100])
        self._write_full_conc("none_raft", "concurrent_40", "0", "YCSB_A",
                              [90, 90, 90, 90, 90])

        # MongoDB: peaks at concurrent_10
        self._write_full_conc("none_mongodb", "concurrent_10", "0", "YCSB_A",
                              [200, 200, 200, 200, 200])
        self._write_full_conc("none_mongodb", "concurrent_20", "0", "YCSB_A",
                              [180, 180, 180, 180, 180])

        data = derive_fixed_conc.collect_throughputs(self.tmpdir, self.site, self.servers)

        # Check Raft
        best_conc, best_tp, _ = derive_fixed_conc.find_max_throughput_conc(
            data["none_raft"], mode="0"
        )
        self.assertEqual(best_conc, "concurrent_20")
        self.assertAlmostEqual(best_tp, 500.0)

        # Check MongoDB
        best_conc, best_tp, _ = derive_fixed_conc.find_max_throughput_conc(
            data["none_mongodb"], mode="0"
        )
        self.assertEqual(best_conc, "concurrent_10")
        self.assertAlmostEqual(best_tp, 1000.0)

    def test_multiple_modes(self):
        """collect_throughputs correctly separates data by mode."""
        self._write_full_conc("none_raft", "concurrent_10", "0", "YCSB_A",
                              [100, 100, 100, 100, 100])
        self._write_full_conc("none_raft", "concurrent_10", "100", "YCSB_A",
                              [80, 80, 80, 80, 80])
        self._write_full_conc("none_raft", "concurrent_10", "101", "YCSB_A",
                              [90, 90, 90, 90, 90])

        data = derive_fixed_conc.collect_throughputs(self.tmpdir, self.site, self.servers)
        self.assertAlmostEqual(data["none_raft"]["concurrent_10"]["0"], 500.0)
        self.assertAlmostEqual(data["none_raft"]["concurrent_10"]["100"], 400.0)
        self.assertAlmostEqual(data["none_raft"]["concurrent_10"]["101"], 450.0)


class TestNotebookIntegrity(unittest.TestCase):
    """Verify evaluation.ipynb structural integrity for Zoo 5-machine runs."""

    @classmethod
    def setUpClass(cls):
        nb_path = os.path.join(SCRIPT_DIR, "evaluation.ipynb")
        with open(nb_path) as f:
            cls.nb = json.load(f)
        cls.all_src = []
        for cell in cls.nb['cells']:
            cls.all_src.append(''.join(cell['source']))

    def test_all_cells_parse(self):
        """Every code cell must be valid Python."""
        for i, cell in enumerate(self.nb['cells']):
            if cell['cell_type'] == 'code':
                src = ''.join(cell['source'])
                try:
                    ast.parse(src)
                except SyntaxError as e:
                    self.fail(f"Cell {i} has syntax error: {e}")

    def test_no_fpga_raft_references(self):
        """No cell should reference fpga_raft."""
        for i, src in enumerate(self.all_src):
            self.assertNotIn('fpga_raft', src, f"Cell {i} still references fpga_raft")

    def test_no_60c1s5r10p_in_active_code(self):
        """No active code should reference the old 60c1s5r10p site."""
        for i, src in enumerate(self.all_src):
            for line in src.split('\n'):
                if '60c1s5r10p' in line and not line.strip().startswith('#'):
                    self.fail(f"Cell {i} has active 60c1s5r10p reference: {line.strip()[:80]}")

    def test_no_hard_coded_4_column_subplots(self):
        """No cell should have hard-coded ncols=4 or subplots(1, 4."""
        for i, src in enumerate(self.all_src):
            self.assertNotIn('ncols=4', src, f"Cell {i} has hard-coded ncols=4")
            self.assertNotIn('subplots(1, 4,', src, f"Cell {i} has hard-coded subplots(1, 4)")

    def test_protocols_include_etcd_zookeeper(self):
        """Cell 2 (constants) must define 6 protocol families."""
        src2 = self.all_src[2]
        self.assertIn('rule_etcd', src2, "Cell 2 missing rule_etcd")
        self.assertIn('rule_zookeeper', src2, "Cell 2 missing rule_zookeeper")
        self.assertIn('none_etcd', src2, "Cell 2 missing none_etcd")
        self.assertIn('none_zookeeper', src2, "Cell 2 missing none_zookeeper")

    def test_sites_is_zoo(self):
        """Cell 2 must set sites to the Zoo config."""
        src2 = self.all_src[2]
        self.assertIn('30c1s5r5p-zoo', src2, "Cell 2 missing Zoo site config")

    def test_server_names_are_zoo(self):
        """Cell 3 must use zoo0..zoo4, not server0..server9."""
        src3 = self.all_src[3]
        self.assertIn('zoo', src3, "Cell 3 missing zoo server names")
        self.assertNotIn('range(10)', src3, "Cell 3 still has range(10) for 10 servers")

    def test_no_hard_coded_protocol_title_lists(self):
        """No cell should have ["Raft", "Copilot", "Mencius", "MongoDB"] without etcd/ZK."""
        for i, src in enumerate(self.all_src):
            if '"MongoDB"]' in src and '"Raft"' in src:
                for line in src.split('\n'):
                    if ('"Raft"' in line and '"MongoDB"' in line
                            and 'etcd' not in line and 'ZooKeeper' not in line
                            and not line.strip().startswith('#')
                            and 'protocol_name' not in line):
                        self.fail(f"Cell {i} has hard-coded 4-protocol list: {line.strip()[:80]}")

    def test_target_folder_uses_result_root(self):
        """target_folder must point to result root, not 'figs/'."""
        src2 = self.all_src[2]
        self.assertIn('directory_path', src2, "target_folder should reference directory_path")
        self.assertNotIn("target_folder = \"figs/\"", src2, "target_folder should not be hard-coded")

    def test_fixed_conc_json_loading(self):
        """Cell 2 must auto-load fixed_conc.json."""
        src2 = self.all_src[2]
        self.assertIn('fixed_conc.json', src2, "Cell 2 missing fixed_conc.json loading")


class TestResultFilePatterns(unittest.TestCase):
    """Verify result file naming matches what the notebook expects."""

    def test_zoo_result_file_pattern(self):
        """Zoo result files match the expected naming pattern."""
        result_dir = os.path.join(REPO_ROOT, "results", "2026-03-23-10:26:07-zoo-5machines")
        if not os.path.isdir(result_dir):
            self.skipTest("Zoo result directory not available")

        pattern = re.compile(
            r'^(.+?)-30c1s5r5p-zoo-rw_\d+(-rw_zipf_[\d.]+)?-concurrent_\d+-\d+-YCSB_[A-Z]-zoo\d\.res$'
        )
        res_files = [f for f in os.listdir(result_dir) if f.endswith('.res')]
        self.assertGreater(len(res_files), 0, "No .res files found")

        for fname in res_files[:10]:  # spot check first 10
            self.assertRegex(fname, pattern, f"File {fname} doesn't match expected pattern")

    def test_zoo_result_has_throughput(self):
        """At least one Zoo result file contains a Mid throughput line."""
        result_dir = os.path.join(REPO_ROOT, "results", "2026-03-23-10:26:07-zoo-5machines")
        if not os.path.isdir(result_dir):
            self.skipTest("Zoo result directory not available")

        res_files = [f for f in os.listdir(result_dir) if f.endswith('.res')]
        found_throughput = False
        for fname in res_files[:5]:
            tp = derive_fixed_conc.parse_mid_throughput(os.path.join(result_dir, fname))
            if tp is not None and tp > 0:
                found_throughput = True
                break
        self.assertTrue(found_throughput, "No result file has a positive throughput")


if __name__ == '__main__':
    unittest.main(verbosity=2)
