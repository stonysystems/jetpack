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

    def test_project_root_derivation(self):
        """Cell 1 must derive project_root from cwd, not use cwd directly as base."""
        src1 = self.all_src[1]
        self.assertIn('project_root', src1,
                      "Cell 1 must define project_root for reliable path resolution")
        # directory_path should use project_root, not current_dir
        self.assertIn('project_root', src1,
                      "Cell 1 directory_path should use project_root")

    def test_fixed_conc_json_uses_project_root(self):
        """Cell 2 fixed_conc.json path must use project_root, not current_dir."""
        src2 = self.all_src[2]
        if 'fixed_conc_json' in src2:
            for line in src2.split('\n'):
                if 'fixed_conc_json' in line and '=' in line and 'os.path.join' in line:
                    self.assertIn('project_root', line,
                                  f"fixed_conc_json should use project_root: {line.strip()}")

    def test_throughput_latency_metrics_complete(self):
        """Cells 13 and 14 must have all 4 throughput-latency metrics enabled."""
        required_metrics = ['ae_ave', 'ae_50', 'ae_90', 'ae_99']
        for cell_idx in [13, 14]:
            src = self.all_src[cell_idx]
            # Find the throughput_latency_metrics definition
            in_metrics = False
            found_metrics = []
            for line in src.split('\n'):
                if 'throughput_latency_metrics' in line and '=' in line:
                    in_metrics = True
                    continue
                if in_metrics:
                    if ']' in line:
                        break
                    # Extract metric key from uncommented lines
                    stripped = line.strip()
                    if stripped.startswith('#'):
                        continue
                    for metric in required_metrics:
                        if f'"{metric}"' in stripped:
                            found_metrics.append(metric)
            for metric in required_metrics:
                self.assertIn(metric, found_metrics,
                              f"Cell {cell_idx} throughput_latency_metrics missing {metric}")


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

    def test_cell16_uses_dynamic_n_servers(self):
        """Cell 16 must use dynamic server count, not hardcoded 10."""
        src = self._get_code_cell(16)
        self.assertNotIn('range(num_leader[proto], 10)', src,
                         "Cell 16 still has hardcoded 10-server range")
        self.assertIn('n_servers', src, "Cell 16 should use n_servers variable")

    def test_cell17_has_6_cpu_line_entries(self):
        """Cell 17 cpu_line_info must have entries for all 6 protocols."""
        src = self._get_code_cell(17)
        self.assertIn('etcd', src, "Cell 17 cpu_line_info missing etcd")
        self.assertIn('zookeeper', src, "Cell 17 cpu_line_info missing zookeeper")

    def test_cell19_guards_mode101_memory(self):
        """Cell 19 must guard against missing mode 101 memory_usage data."""
        src = self._get_code_cell(19)
        has_guard = ('try:' in src or '_mem_protocols_done' in src
                     or 'except' in src or '.get(' in src)
        self.assertTrue(has_guard,
                        "Cell 19 accesses mode 101 memory_usage without a guard")

    def test_cell19_handles_empty_protocol_data(self):
        """Cell 19 should not crash when no protocol has mode 101 data."""
        src = self._get_code_cell(19)
        # Should have a fallback message for when no data is available
        self.assertIn('not available', src.lower(),
                      "Cell 19 should print a message when mode 101 data is missing")

    def test_cell25_guards_copilot_property(self):
        """Cell 25 must guard copilot property experiment loading."""
        src = self._get_code_cell(25)
        has_guard = ('try:' in src or 'except' in src or '_copilot_property' in src)
        self.assertTrue(has_guard,
                        "Cell 25 loads copilot property data without a guard")

    def test_cell15_guards_mode_access(self):
        """Cell 15 draw_latency_line must handle missing mode data."""
        src = self._get_code_cell(15)
        has_guard = ('try:' in src or 'except' in src or '.get(' in src
                     or 'continue' in src)
        self.assertTrue(has_guard,
                        "Cell 15 accesses mode data in pcts loop without a guard")

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
        for i in [12, 13, 14, 18]:
            _, src = self.code_cells[i]
            if 'subplots' in src:
                self.assertIn('n_proto', src,
                              f"Cell {i} subplots should use n_proto for ncols")
                self.assertNotIn('ncols=4', src,
                                 f"Cell {i} has hardcoded ncols=4")

    def test_cpu_cell_uses_dynamic_ncols(self):
        """Cell 17 must use dynamic ncols for CPU usage figure."""
        _, src = self.code_cells[17]
        self.assertNotIn('ncols=2,', src,
                         "Cell 17 has hardcoded ncols=2")
        # New layout uses n_proto for 6-subfigure per-protocol layout
        self.assertTrue('n_proto' in src or 'len(workloads)' in src,
                        "Cell 17 should use n_proto or len(workloads) for dynamic ncols")

    def test_protocol_ordering_consistent(self):
        """Protocol ordering in cpu_line_info must match protocol_name."""
        _, src2 = self.code_cells[2]
        _, src16 = self.code_cells[17]

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
        """Cell 15 subplots must use dynamic column count."""
        _, src = self.code_cells[15]
        if 'subplots' in src:
            self.assertNotIn('ncols=4', src,
                             "Cell 15 has hardcoded ncols=4")


class TestResultFilePatterns(unittest.TestCase):
    """Verify result file naming matches what the notebook expects."""

    def test_zoo_result_file_pattern(self):
        """Zoo result files match the expected naming pattern."""
        result_dir = os.path.join(REPO_ROOT, "results", "2026-03-23-10:26:07-zoo-5machines")
        if not os.path.isdir(result_dir):
            self.skipTest("Zoo result directory not available")

        pattern = re.compile(
            r'^(.+?)-30c1s5r5p-zoo-(rw_[\d._a-z]+)-concurrent_\d+-\d+-YCSB_[A-Z]-zoo\d\.res$'
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


class TestPipelineOutputs(unittest.TestCase):
    """Verify evaluation pipeline outputs are well-formed."""

    RESULT_DIR = os.path.join(REPO_ROOT, "results", "2026-03-23-10:26:07-zoo-5machines")

    def _skip_if_no_results(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Zoo result directory not available")

    def test_figure_input_sanity_json_exists(self):
        """figure_input_sanity.json must exist after pipeline run."""
        self._skip_if_no_results()
        path = os.path.join(self.RESULT_DIR, "figure_input_sanity.json")
        if not os.path.isfile(path):
            self.skipTest("figure_input_sanity.json not yet generated")
        with open(path) as f:
            data = json.load(f)
        self.assertIn("pass_count", data)
        self.assertIn("fail_count", data)
        self.assertIn("results", data)
        self.assertIsInstance(data["results"], list)
        self.assertGreater(len(data["results"]), 0,
                           "Sanity check should have at least one result entry")

    def test_figure_input_sanity_no_failures(self):
        """figure_input_sanity.json must have zero failures."""
        self._skip_if_no_results()
        path = os.path.join(self.RESULT_DIR, "figure_input_sanity.json")
        if not os.path.isfile(path):
            self.skipTest("figure_input_sanity.json not yet generated")
        with open(path) as f:
            data = json.load(f)
        self.assertEqual(data.get("fail_count", -1), 0,
                         "Figure-input sanity check has failures — PDFs are suspect")

    def test_figure_input_sanity_md_exists(self):
        """figure_input_sanity.md must exist alongside the JSON."""
        self._skip_if_no_results()
        path = os.path.join(self.RESULT_DIR, "figure_input_sanity.md")
        if not os.path.isfile(path):
            self.skipTest("figure_input_sanity.md not yet generated")
        with open(path) as f:
            content = f.read()
        self.assertIn("Figure-Input Sanity Check", content)
        self.assertIn("PASS", content)

    def test_experiment0_pdfs_exist(self):
        """All experiment-0 PDFs must be present in figs/."""
        self._skip_if_no_results()
        figs_dir = os.path.join(self.RESULT_DIR, "figs")
        if not os.path.isdir(figs_dir):
            self.skipTest("figs/ directory not yet created")
        expected_pdfs = [
            "30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_50.pdf",
            "30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_90.pdf",
            "30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_99.pdf",
            "30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_ave.pdf",
            "30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_cpu_usage.pdf",
            "30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_50.pdf",
            "30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_90.pdf",
            "30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_99.pdf",
            "30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_ave.pdf",
            "30c1s5r5p-zoo_cpu_usage_ave.pdf",
            "30c1s5r5p-zoo_latency_cumulative_rw_1000000_print.pdf",
            "30c1s5r5p-zoo_memory_usage_conc_30c1s5r5p-zoo.pdf",
        ]
        for pdf_name in expected_pdfs:
            pdf_path = os.path.join(figs_dir, pdf_name)
            self.assertTrue(os.path.isfile(pdf_path),
                            f"Missing expected PDF: {pdf_name}")
            size = os.path.getsize(pdf_path)
            self.assertGreater(size, 5000,
                               f"PDF too small ({size} bytes): {pdf_name}")

    def test_pdfs_have_site_tag_prefix(self):
        """All PDFs in figs/ must include the site tag in their filename."""
        self._skip_if_no_results()
        figs_dir = os.path.join(self.RESULT_DIR, "figs")
        if not os.path.isdir(figs_dir):
            self.skipTest("figs/ directory not yet created")
        pdfs = [f for f in os.listdir(figs_dir) if f.endswith('.pdf')]
        for pdf in pdfs:
            self.assertTrue(pdf.startswith("30c1s5r5p-zoo_"),
                            f"PDF missing site tag prefix: {pdf}")

    def test_experiment_report_includes_sanity_section(self):
        """EXPERIMENT_REPORT.md must include figure-input sanity section."""
        self._skip_if_no_results()
        report_path = os.path.join(self.RESULT_DIR, "EXPERIMENT_REPORT.md")
        if not os.path.isfile(report_path):
            self.skipTest("EXPERIMENT_REPORT.md not yet generated")
        with open(report_path) as f:
            content = f.read()
        self.assertIn("Figure-Input Sanity Check", content)
        self.assertIn("Plotting Decisions", content)

    def test_experiment_report_includes_plotting_decisions(self):
        """EXPERIMENT_REPORT.md must document plotting decisions."""
        self._skip_if_no_results()
        report_path = os.path.join(self.RESULT_DIR, "EXPERIMENT_REPORT.md")
        if not os.path.isfile(report_path):
            self.skipTest("EXPERIMENT_REPORT.md not yet generated")
        with open(report_path) as f:
            content = f.read()
        self.assertIn("200ms", content, "Report should document 200ms y-axis decision")
        self.assertIn("cumulative", content.lower(),
                      "Report should document CDF missing lines fix")
        self.assertIn("CPU", content,
                      "Report should document CPU layout change")

    def test_tables_directory_has_csvs(self):
        """tables/ must contain exported CSV files."""
        self._skip_if_no_results()
        tables_dir = os.path.join(self.RESULT_DIR, "tables")
        if not os.path.isdir(tables_dir):
            self.skipTest("tables/ directory not yet created")
        csvs = [f for f in os.listdir(tables_dir) if f.endswith('.csv')]
        self.assertGreaterEqual(len(csvs), 4,
                                f"Expected at least 4 CSV files, found {len(csvs)}")
        expected = ["fixed_conc_table.csv", "experiment0_summary.csv",
                    "throughput_vs_conc.csv", "latency_vs_conc.csv"]
        for name in expected:
            self.assertIn(name, csvs, f"Missing expected table: {name}")


class TestNotebookSanityCheckCell(unittest.TestCase):
    """Verify the figure-input sanity check cell is self-contained."""

    @classmethod
    def setUpClass(cls):
        nb_path = os.path.join(SCRIPT_DIR, "evaluation.ipynb")
        with open(nb_path) as f:
            cls.nb = json.load(f)
        cls.all_src = [''.join(cell['source']) for cell in cls.nb['cells']]

    def test_sanity_cell_exists_at_position_5(self):
        """Cell 5 must be the figure-input sanity check."""
        src = self.all_src[5]
        self.assertIn("Figure-input sanity check", src)
        self.assertIn("figure_input_sanity.json", src)
        self.assertIn("figure_input_sanity.md", src)

    def test_sanity_cell_no_forward_dependencies(self):
        """Cell 5 must not reference functions defined in later cells."""
        src = self.all_src[5]
        # These are defined in cells 12+ and must not appear in cell 5
        later_funcs = ["safe_latency_metric", "safe_cpu_usage_metric",
                       "draw_conc_latency", "draw_throughput_latency",
                       "draw_latency_line", "draw_cpu_usage"]
        for func in later_funcs:
            self.assertNotIn(func, src,
                             f"Cell 5 references '{func}' which is defined in a later cell")

    def test_sanity_cell_uses_inline_lookup(self):
        """Cell 5 must use inline dict lookup for latency data."""
        src = self.all_src[5]
        self.assertIn("data[sites[0]]", src)
        self.assertIn("ae_50", src)
        # Should have try/except for KeyError
        self.assertIn("except KeyError", src)

    def test_sanity_cell_checks_all_protocols(self):
        """Cell 5 must iterate over all protocols."""
        src = self.all_src[5]
        self.assertIn("for (jp, vp), name in zip(protocols, protocol_name)", src)
        # Must check original, jetpack_0pct, adaptive, jetpack_100pct
        for variant in ["original", "jetpack_0pct", "adaptive", "jetpack_100pct"]:
            self.assertIn(variant, src,
                          f"Cell 5 missing variant '{variant}'")


class TestFailureRecoveryScript(unittest.TestCase):
    """Verify run_failure_recovery.sh is well-formed."""

    @classmethod
    def setUpClass(cls):
        script_path = os.path.join(SCRIPT_DIR, "run_failure_recovery.sh")
        with open(script_path) as f:
            cls.src = f.read()

    def test_captures_stderr(self):
        """SSH command must redirect stderr alongside stdout."""
        self.assertIn('2>&1"', self.src,
                      "SSH command should capture stderr with 2>&1")

    def test_uses_pkill_9(self):
        """Kill command must use pkill -9 for guaranteed process death."""
        self.assertIn("pkill -9 deptran_server", self.src)

    def test_saves_kill_evidence(self):
        """Script must save kill_evidence.json."""
        self.assertIn("kill_evidence.json", self.src)
        self.assertIn("confirmed_dead", self.src)

    def test_generates_recovery_summary(self):
        """Script must generate RECOVERY_SUMMARY.md."""
        self.assertIn("RECOVERY_SUMMARY.md", self.src)

    def test_uses_wan_delay(self):
        """Script must set WAN_DELAY_MS=20."""
        self.assertIn("WAN_DELAY_MS=20", self.src)

    def test_uses_failover_yml(self):
        """Script must include failover.yml config."""
        self.assertIn("failover.yml", self.src)

    def test_uses_open_loop_client(self):
        """Script must use open-loop client config."""
        self.assertIn("client_open_failure_recovery.yml", self.src)

    def test_all_four_protocols(self):
        """Script must run all 4 failure recovery protocols."""
        for proto in ["rule_raft", "rule_mongodb", "rule_etcd", "rule_zookeeper"]:
            self.assertIn(proto, self.src,
                          f"Missing protocol: {proto}")

    def test_nfs_sync_before_scp(self):
        """Script must flush NFS cache before pulling CSV files."""
        sync_pos = self.src.find('"sync"')
        scp_pos = self.src.find("scp ")
        self.assertGreater(sync_pos, -1, "Missing NFS sync command")
        self.assertGreater(scp_pos, sync_pos,
                           "NFS sync must come before scp")

    def test_kill_delay_exceeds_client_init(self):
        """Kill delay must be >= 30s to allow client communicator init."""
        import re
        m = re.search(r'KILL_DELAY=(\d+)', self.src)
        self.assertIsNotNone(m, "KILL_DELAY not found")
        self.assertGreaterEqual(int(m.group(1)), 30,
                                "KILL_DELAY must be >= 30s for client init")

    def test_tail_based_throughput_check(self):
        """Throughput check must use tail for large .res files."""
        self.assertIn('tail -c 102400', self.src,
                      "Must use tail-based check for potentially large .res files")


class TestZooRecoveryPDFCell(unittest.TestCase):
    """Verify the Zoo per-protocol failure recovery PDF cell."""

    @classmethod
    def setUpClass(cls):
        nb_path = os.path.join(SCRIPT_DIR, "evaluation.ipynb")
        with open(nb_path) as f:
            cls.nb = json.load(f)
        cls.all_src = [''.join(cell['source']) for cell in cls.nb['cells']]

    def test_cell28_is_zoo_recovery_pdf(self):
        """Cell 28 must be the Zoo per-protocol recovery PDF generator."""
        src = self.all_src[28]
        self.assertIn("Zoo per-protocol failure recovery", src)
        self.assertIn("failure_recovery", src)

    def test_cell28_guards_data_availability(self):
        """Cell 28 must check for Zoo failure recovery data before plotting."""
        src = self.all_src[28]
        self.assertIn("_use_zoo_fr", src)
        self.assertIn("Skipping", src)

    def test_cell28_covers_all_protocols(self):
        """Cell 28 must handle all 4 failure recovery protocols."""
        src = self.all_src[28]
        for proto in ["rule_raft", "rule_mongodb", "rule_etcd", "rule_zookeeper"]:
            self.assertIn(proto, src, f"Cell 28 missing protocol display for {proto}")

    def test_cell28_uses_helper_functions(self):
        """Cell 28 must use make_time_grid and throughput_on_grid from cell 26."""
        src = self.all_src[28]
        self.assertIn("make_time_grid", src)
        self.assertIn("throughput_on_grid", src)

    def test_cell28_saves_pdfs_with_site_tag(self):
        """Cell 28 must save PDFs with site_tag prefix."""
        src = self.all_src[28]
        self.assertIn("site_tag", src)
        self.assertIn("savefig", src)
        self.assertIn(".pdf", src)

    def test_cell28_shows_failure_markers(self):
        """Cell 28 must plot failure, recovery start, and recovery done markers."""
        src = self.all_src[28]
        self.assertIn("Failure Trigger", src)
        self.assertIn("Recovery Start", src)
        self.assertIn("Recovery Done", src)
        self.assertIn("axvline", src)


class TestTriageClassification(unittest.TestCase):
    """Verify the 2026-03-23 run is classified as PARTIAL with triage docs."""

    RESULT_DIR = os.path.join(
        REPO_ROOT, "results", "2026-03-23-10:26:07-zoo-5machines"
    )

    def _skip_if_no_results(self):
        if not os.path.isdir(self.RESULT_DIR):
            self.skipTest("Result directory not present")

    def test_status_file_exists(self):
        """STATUS file must exist in the result root."""
        self._skip_if_no_results()
        status_path = os.path.join(self.RESULT_DIR, "STATUS")
        self.assertTrue(os.path.isfile(status_path), "STATUS file missing")

    def test_status_says_partial(self):
        """STATUS file must say PARTIAL, not PASS or COMPLETE."""
        self._skip_if_no_results()
        status_path = os.path.join(self.RESULT_DIR, "STATUS")
        if not os.path.isfile(status_path):
            self.skipTest("STATUS file not yet created")
        with open(status_path) as f:
            content = f.read()
        self.assertIn("PARTIAL", content)
        self.assertNotRegex(content, r'(?i)\bpass\b')
        self.assertNotRegex(content, r'(?i)\bcomplete\b')

    def test_triage_md_exists(self):
        """TRIAGE.md must exist in the result root."""
        self._skip_if_no_results()
        triage_path = os.path.join(self.RESULT_DIR, "TRIAGE.md")
        self.assertTrue(os.path.isfile(triage_path), "TRIAGE.md missing")

    def test_triage_covers_key_blockers(self):
        """TRIAGE.md must mention key open blockers."""
        self._skip_if_no_results()
        triage_path = os.path.join(self.RESULT_DIR, "TRIAGE.md")
        if not os.path.isfile(triage_path):
            self.skipTest("TRIAGE.md not yet created")
        with open(triage_path) as f:
            content = f.read()
        for keyword in [
            "3400", "1838",           # res/csv counts
            "rule_raft",              # recovery protocol
            "MongoDB",                # bottleneck
            "Mencius",                # adaptive broken
            "turning point",          # sweep range
        ]:
            self.assertIn(keyword, content,
                          f"TRIAGE.md missing blocker keyword: {keyword}")

    def test_summary_has_partial_banner(self):
        """SUMMARY.md must have a PARTIAL status banner."""
        self._skip_if_no_results()
        summary_path = os.path.join(self.RESULT_DIR, "SUMMARY.md")
        if not os.path.isfile(summary_path):
            self.skipTest("SUMMARY.md not present")
        with open(summary_path) as f:
            # Check first 500 chars for the banner
            head = f.read(500)
        self.assertIn("PARTIAL", head,
                       "SUMMARY.md missing PARTIAL status banner at top")

    def test_experiment_report_has_partial_banner(self):
        """EXPERIMENT_REPORT.md must have a PARTIAL status banner."""
        self._skip_if_no_results()
        report_path = os.path.join(self.RESULT_DIR, "EXPERIMENT_REPORT.md")
        if not os.path.isfile(report_path):
            self.skipTest("EXPERIMENT_REPORT.md not present")
        with open(report_path) as f:
            head = f.read(500)
        self.assertIn("PARTIAL", head,
                       "EXPERIMENT_REPORT.md missing PARTIAL status banner at top")


if __name__ == '__main__':
    unittest.main(verbosity=2)
