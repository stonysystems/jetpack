#!/usr/bin/env python3
"""Tests for scripts/run_evaluation.sh pipeline integration."""

import os
import sys
import tempfile
import shutil
import subprocess
import unittest

SCRIPT_DIR = os.path.dirname(__file__)
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
SITE = "30c1s5r5p-zoo"
SERVERS = [f"zoo{i}" for i in range(5)]


def make_res_content(mid_throughput=100.0, wan_delay=True):
    """Generate minimal .res file content."""
    lines = [
        'I [s_main.cc:775] 2026-03-23 06:00:00.000 | starting process 12345',
    ]
    if wan_delay:
        lines.append(
            'I [s_main.cc:793] 2026-03-23 06:00:00.000 | WAN delay enabled via WAN_DELAY_MS=20 (20000 us)'
        )
    lines.append(
        f'I [s_main.cc:859] 2026-03-23 06:01:00.000 | Total throughtput is {mid_throughput * 1.2:.2f}'
    )
    lines.append(
        f'I [s_main.cc:905] 2026-03-23 06:01:00.000 | '
        f'All-fast-path-attempts           statistics   count        0   '
        f'0pct    -1.00  50pct    -1.00  90pct    -1.00  99pct    -1.00    ave    -1.00'
    )
    lines.append(
        f'I [s_main.cc:908] 2026-03-23 06:01:00.000 | '
        f'All-original-path-attempts       statistics   count     1000   '
        f'0pct    60.00  50pct    75.00  90pct    85.00  99pct    90.00    ave    76.00'
    )
    lines.append(
        f'I [s_main.cc:910] 2026-03-23 06:01:00.000 | '
        f'All-efficient-attempts           statistics   count        0   '
        f'0pct    -1.00  50pct    -1.00  90pct    -1.00  99pct    -1.00    ave    -1.00'
    )
    lines.append(
        f'I [s_main.cc:921] 2026-03-23 06:01:00.000 | Mid throughput is {mid_throughput:.2f}'
    )
    return "\n".join(lines)


def write_synthetic_data(result_dir, protocol, conc, mode, tp=100.0):
    """Write synthetic .res files for all servers."""
    for srv in SERVERS:
        fname = f"{protocol}-{SITE}-rw_1000000-{conc}-{mode}-YCSB_A-{srv}.res"
        with open(os.path.join(result_dir, fname), 'w') as f:
            f.write(make_res_content(mid_throughput=tp))


class TestRunEvaluationScript(unittest.TestCase):
    """Test the run_evaluation.sh script structure."""

    def test_script_exists(self):
        path = os.path.join(SCRIPT_DIR, "run_evaluation.sh")
        self.assertTrue(os.path.isfile(path))

    def test_script_has_shebang(self):
        with open(os.path.join(SCRIPT_DIR, "run_evaluation.sh")) as f:
            first_line = f.readline()
        self.assertTrue(first_line.startswith("#!/bin/bash"))

    def test_script_references_all_steps(self):
        with open(os.path.join(SCRIPT_DIR, "run_evaluation.sh")) as f:
            content = f.read()
        self.assertIn("derive_fixed_conc.py", content)
        self.assertIn("sanity_check.py", content)
        self.assertIn("generate_summary.py", content)
        self.assertIn("evaluation.ipynb", content)

    def test_script_has_usage_check(self):
        with open(os.path.join(SCRIPT_DIR, "run_evaluation.sh")) as f:
            content = f.read()
        self.assertIn("Usage:", content)
        self.assertIn("$# -lt 1", content)

    def test_script_creates_output_dirs(self):
        with open(os.path.join(SCRIPT_DIR, "run_evaluation.sh")) as f:
            content = f.read()
        self.assertIn("mkdir -p", content)
        self.assertIn("figs", content)
        self.assertIn("tables", content)

    def test_script_sets_zoo_exptime(self):
        with open(os.path.join(SCRIPT_DIR, "run_evaluation.sh")) as f:
            content = f.read()
        self.assertIn("ZOO_EXPTIME", content)


class TestPipelineComponents(unittest.TestCase):
    """Test that each pipeline component works independently."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        # Write some synthetic Raft data
        write_synthetic_data(self.tmpdir, "none_raft", "concurrent_100", "0", tp=200.0)
        write_synthetic_data(self.tmpdir, "none_raft", "concurrent_200", "0", tp=400.0)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_derive_fixed_conc(self):
        """derive_fixed_conc.py produces output files."""
        result = subprocess.run(
            [sys.executable, os.path.join(SCRIPT_DIR, "derive_fixed_conc.py"), self.tmpdir],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "fixed_conc_selection.md")))

    def test_sanity_check(self):
        """sanity_check.py produces sanity_checks.md."""
        result = subprocess.run(
            [sys.executable, os.path.join(SCRIPT_DIR, "sanity_check.py"), self.tmpdir],
            capture_output=True, text=True
        )
        # May exit 1 (failures for missing protocols) but should still produce output
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "sanity_checks.md")))

    def test_generate_summary(self):
        """generate_summary.py produces SUMMARY.md."""
        result = subprocess.run(
            [sys.executable, os.path.join(SCRIPT_DIR, "generate_summary.py"), self.tmpdir],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "SUMMARY.md")))

    def test_pipeline_components_in_sequence(self):
        """All three components run in sequence without conflicts."""
        for script in ["derive_fixed_conc.py", "sanity_check.py", "generate_summary.py"]:
            result = subprocess.run(
                [sys.executable, os.path.join(SCRIPT_DIR, script), self.tmpdir],
                capture_output=True, text=True
            )
            # derive_fixed_conc and generate_summary should exit 0
            # sanity_check may exit 1 due to missing protocols
            if script != "sanity_check.py":
                self.assertEqual(result.returncode, 0,
                                 f"{script} failed: {result.stderr}")

        # All artifacts should exist
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "fixed_conc_selection.md")))
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "sanity_checks.md")))
        self.assertTrue(os.path.isfile(os.path.join(self.tmpdir, "SUMMARY.md")))

    def test_summary_reflects_sanity_check(self):
        """SUMMARY.md should show sanity_checks.md as present after generation."""
        subprocess.run(
            [sys.executable, os.path.join(SCRIPT_DIR, "sanity_check.py"), self.tmpdir],
            capture_output=True, text=True
        )
        subprocess.run(
            [sys.executable, os.path.join(SCRIPT_DIR, "generate_summary.py"), self.tmpdir],
            capture_output=True, text=True
        )
        with open(os.path.join(self.tmpdir, "SUMMARY.md")) as f:
            content = f.read()
        self.assertIn("sanity_checks.md", content)
        self.assertIn("present", content)


class TestScriptErrorHandling(unittest.TestCase):
    """Test error cases."""

    def test_missing_result_dir(self):
        result = subprocess.run(
            ["bash", os.path.join(SCRIPT_DIR, "run_evaluation.sh")],
            capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage", result.stderr + result.stdout)

    def test_nonexistent_dir(self):
        result = subprocess.run(
            ["bash", os.path.join(SCRIPT_DIR, "run_evaluation.sh"), "/nonexistent/dir"],
            capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a directory", result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
