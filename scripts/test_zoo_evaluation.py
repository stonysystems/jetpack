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


class TestNotebookDataGuards(unittest.TestCase):
    """Verify that notebook cells have proper guards for missing data."""

    @classmethod
    def setUpClass(cls):
        nb_path = os.path.join(SCRIPT_DIR, "evaluation.ipynb")
        with open(nb_path) as f:
            cls.nb = json.load(f)
        cls.code_cells = []
        for i, cell in enumerate(cls.nb['cells']):
            src = ''.join(cell['source'])
            cls.code_cells.append((i, cell.get('cell_type', ''), cell.get('id', ''), src))

    def _get_code_cell(self, index):
        """Get source of a code cell by notebook index."""
        _, ctype, cid, src = self.code_cells[index]
        return src

    def test_cell15_uses_dynamic_n_servers(self):
        """Cell 15 must use dynamic server count, not hardcoded 10."""
        src = self._get_code_cell(15)
        self.assertNotIn('range(num_leader[proto], 10)', src,
                         "Cell 15 still has hardcoded 10-server range")
        self.assertIn('n_servers', src, "Cell 15 should use n_servers variable")

    def test_cell16_has_6_cpu_line_entries(self):
        """Cell 16 cpu_line_info must have entries for all 6 protocols."""
        src = self._get_code_cell(16)
        self.assertIn('etcd', src, "Cell 16 cpu_line_info missing etcd")
        self.assertIn('zookeeper', src, "Cell 16 cpu_line_info missing zookeeper")

    def test_cell18_guards_mode101_memory(self):
        """Cell 18 must guard against missing mode 101 memory_usage data."""
        src = self._get_code_cell(18)
        has_guard = ('try:' in src or '_mem_protocols_done' in src
                     or 'except' in src or '.get(' in src)
        self.assertTrue(has_guard,
                        "Cell 18 accesses mode 101 memory_usage without a guard")

    def test_cell18_handles_empty_protocol_data(self):
        """Cell 18 should not crash when no protocol has mode 101 data."""
        src = self._get_code_cell(18)
        # Should have a fallback message for when no data is available
        self.assertIn('not available', src.lower(),
                      "Cell 18 should print a message when mode 101 data is missing")

    def test_cell24_guards_copilot_property(self):
        """Cell 24 must guard copilot property experiment loading."""
        src = self._get_code_cell(24)
        has_guard = ('try:' in src or 'except' in src or '_copilot_property' in src)
        self.assertTrue(has_guard,
                        "Cell 24 loads copilot property data without a guard")

    def test_cell14_guards_mode_access(self):
        """Cell 14 draw_latency_line must handle missing mode data."""
        src = self._get_code_cell(14)
        has_guard = ('try:' in src or 'except' in src or '.get(' in src
                     or 'continue' in src)
        self.assertTrue(has_guard,
                        "Cell 14 accesses mode data in pcts loop without a guard")

    def test_zipf_cells_have_guards(self):
        """Cells referencing zipf data must have _has_zipf guard."""
        for i, ctype, cid, src in self.code_cells:
            if ctype != 'code':
                continue
            if 'rw_zipf' in src and '_has_zipf' not in src and not src.strip().startswith('#'):
                # Check it's not in a comment
                for line in src.split('\n'):
                    if 'rw_zipf' in line and not line.strip().startswith('#'):
                        self.fail(f"Cell {i} references zipf data without _has_zipf guard")

    def test_legacy_cells_are_raw(self):
        """Cells after 'Everything below is not used' marker must be raw."""
        found_marker = False
        for i, ctype, cid, src in self.code_cells:
            if 'Everything below is not used' in src:
                found_marker = True
                continue
            if found_marker and ctype == 'code' and src.strip():
                self.fail(f"Cell {i} is still executable code after legacy marker")

    def test_contention_cells_have_guards(self):
        """Cells referencing contention data must have _has_contention guard."""
        for i, ctype, cid, src in self.code_cells:
            if ctype != 'code':
                continue
            if 'contention_protocol_data' in src and 'for' in src:
                if '_has_contention' not in src:
                    self.fail(f"Cell {i} uses contention data without _has_contention guard")

    def test_key_range_cells_have_guards(self):
        """Cells that plot key range data must have _has_key_range guard."""
        for i, ctype, cid, src in self.code_cells:
            if ctype != 'code':
                continue
            # Only check cells that plot/iterate over key range data, not definitions
            if '_has_key_range' in src or 'key_range' not in src.lower():
                continue
            # Look for data access patterns like data[...]['rw_10'] or looping over key ranges
            if ('key_range' in src.lower() and ('plot' in src.lower() or 'axes' in src.lower()
                    or 'savefig' in src)):
                self.fail(f"Cell {i} plots key range data without _has_key_range guard")


class TestFigureLayout(unittest.TestCase):
    """Verify figure layout requirements for Zoo 5-machine evaluation."""

    @classmethod
    def setUpClass(cls):
        nb_path = os.path.join(SCRIPT_DIR, "evaluation.ipynb")
        with open(nb_path) as f:
            cls.nb = json.load(f)
        cls.code_cells = {}
        for i, cell in enumerate(cls.nb['cells']):
            src = ''.join(cell['source'])
            cls.code_cells[i] = (cell.get('cell_type', ''), src)

    def test_site_tag_defined(self):
        """Cell 2 must define site_tag variable for figure filenames."""
        _, src = self.code_cells[2]
        self.assertIn('site_tag', src, "Cell 2 missing site_tag definition")

    def test_savefig_includes_site_tag(self):
        """All savefig calls in active cells must include site_tag."""
        for i in range(33):  # active cells only
            ctype, src = self.code_cells[i]
            if ctype != 'code':
                continue
            for line in src.split('\n'):
                if 'savefig' in line and not line.strip().startswith('#'):
                    # If it saves to a variable (filename, save_path, etc.)
                    # the variable should have been constructed with site_tag
                    if 'target_folder' in line or '.pdf' in line:
                        self.assertIn('site_tag', line,
                                      f"Cell {i} savefig missing site_tag: {line.strip()[:80]}")

    def test_figure_variable_paths_include_site_tag(self):
        """Figure output path variables must include site_tag."""
        # Check known figure-path variable assignments
        path_vars = ['filename =', 'throughput_fig =', 'dispatch_fig =',
                     'overlay_fig =', 'save_path=']
        for i in range(33):
            ctype, src = self.code_cells[i]
            if ctype != 'code':
                continue
            for line in src.split('\n'):
                stripped = line.strip()
                if stripped.startswith('#'):
                    continue
                if any(pv in stripped for pv in path_vars) and '.pdf' in stripped:
                    self.assertIn('site_tag', stripped,
                                  f"Cell {i} figure path missing site_tag: {stripped[:80]}")

    def test_main_subplot_cells_use_n_proto(self):
        """Main figure cells must use dynamic n_proto for ncols."""
        for i in [11, 12, 13, 17]:
            _, src = self.code_cells[i]
            if 'subplots' in src:
                self.assertIn('n_proto', src,
                              f"Cell {i} subplots should use n_proto for ncols")
                self.assertNotIn('ncols=4', src,
                                 f"Cell {i} has hardcoded ncols=4")

    def test_cpu_cell_uses_dynamic_ncols(self):
        """Cell 16 must use dynamic ncols for workload count."""
        _, src = self.code_cells[16]
        self.assertNotIn('ncols=2,', src,
                         "Cell 16 has hardcoded ncols=2")
        self.assertIn('len(workloads)', src,
                      "Cell 16 should use len(workloads) for dynamic ncols")

    def test_protocol_ordering_consistent(self):
        """Protocol ordering in cpu_line_info must match protocol_name."""
        _, src2 = self.code_cells[2]
        _, src16 = self.code_cells[16]

        # Extract protocol_name order
        proto_names = []
        in_array = False
        for line in src2.split('\n'):
            if 'protocol_name = [' in line:
                in_array = True
                continue
            if in_array:
                if ']' in line:
                    break
                name = line.strip().strip('",')
                if name:
                    proto_names.append(name.lower())

        # Extract cpu_line_info order
        cpu_names = []
        in_array = False
        for line in src16.split('\n'):
            if 'cpu_line_info = [' in line:
                in_array = True
                continue
            if in_array:
                if line.strip() == ']':
                    break
                if '"' in line:
                    import re
                    m = re.search(r'"(\w+)"', line)
                    if m:
                        cpu_names.append(m.group(1).lower())

        self.assertEqual(proto_names, cpu_names,
                         "Protocol ordering mismatch between protocol_name and cpu_line_info")

    def test_latency_cumulative_uses_dynamic_ncols(self):
        """Cell 14 subplots must use dynamic column count."""
        _, src = self.code_cells[14]
        if 'subplots' in src:
            self.assertNotIn('ncols=4', src,
                             "Cell 14 has hardcoded ncols=4")


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
