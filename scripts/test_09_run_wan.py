#!/usr/bin/env python3
"""
Tests for scripts/09-build_and_test_run_wan.sh
Validates CLI argument parsing and dry-run output via --dry-run mode.
"""

import os
import subprocess
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.join(SCRIPT_DIR, "09-build_and_test_run_wan.sh")
SETUP_JSON = os.path.join(SCRIPT_DIR, "setup.json")


def run_dry(extra_args=None):
    """Run the script in --dry-run mode and return stdout."""
    if not os.path.exists(SETUP_JSON):
        return None
    cmd = ["bash", SCRIPT_PATH, "--dry-run"] + (extra_args or [])
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=SCRIPT_DIR,
                            timeout=10)
    return result.stdout


class TestDryRunBasic(unittest.TestCase):
    """Test basic dry-run output."""

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(SETUP_JSON):
            raise unittest.SkipTest("setup.json not available")
        cls.output = run_dry()

    def test_dry_run_shows_environment(self):
        self.assertIn("Environment:", self.output)

    def test_dry_run_shows_servers(self):
        self.assertIn("Servers:", self.output)

    def test_default_result_dir_is_test_output(self):
        self.assertIn("Result dir:   test_output", self.output)

    def test_dry_run_has_run_commands(self):
        self.assertIn("[run]", self.output)

    def test_dry_run_has_pull_command(self):
        self.assertIn("[pull]", self.output)


class TestResultDirOption(unittest.TestCase):
    """Test --result-dir CLI option."""

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(SETUP_JSON):
            raise unittest.SkipTest("setup.json not available")

    def test_custom_result_dir(self):
        output = run_dry(["--result-dir", "/tmp/custom_results"])
        self.assertIn("Result dir:   /tmp/custom_results", output)

    def test_result_dir_in_output_paths(self):
        output = run_dry(["--result-dir", "/my/result/path",
                          "--filename", "test-run"])
        self.assertIn("/my/result/path/test-run-", output)

    def test_result_dir_with_kill_target(self):
        output = run_dry(["--result-dir", "/zoo/results",
                          "--kill-target", "0", "--filename", "recovery"])
        self.assertIn("Result dir:   /zoo/results", output)
        self.assertIn("Failover:     true", output)

    def test_result_dir_short_flag(self):
        output = run_dry(["-R", "/short/flag/path"])
        self.assertIn("Result dir:   /short/flag/path", output)


class TestKillTarget(unittest.TestCase):
    """Test --kill-target enables failover mode."""

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(SETUP_JSON):
            raise unittest.SkipTest("setup.json not available")

    def test_kill_target_enables_failover(self):
        output = run_dry(["--kill-target", "0"])
        self.assertIn("Failover:     true", output)
        self.assertIn("Duration:     70s", output)

    def test_no_failover_by_default(self):
        output = run_dry()
        self.assertIn("Failover:     false", output)
        self.assertIn("Duration:     30s", output)


class TestFilename(unittest.TestCase):
    """Test --filename option."""

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(SETUP_JSON):
            raise unittest.SkipTest("setup.json not available")

    def test_custom_filename_in_output(self):
        output = run_dry(["--filename", "my-custom-test"])
        self.assertIn("my-custom-test-", output)


class TestSyntax(unittest.TestCase):
    """Test script syntax is valid."""

    def test_bash_syntax_check(self):
        result = subprocess.run(
            ["bash", "-n", SCRIPT_PATH],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0,
                         f"Bash syntax error: {result.stderr}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
