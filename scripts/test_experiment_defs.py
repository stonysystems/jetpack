#!/usr/bin/env python3
"""Tests for experiment_defs.sh — validates the bash experiment definitions.

Tests cover:
  - Protocol array completeness and consistency
  - Mode flag values
  - Concurrency array coverage
  - Zoo matrix generation (concurrency_sweep produces expected count)
  - Result prefix format
  - Helper functions (mode_flag_for, concs_array_for, build_result_prefix)
  - Syntax validity
"""

import json
import os
import subprocess
import tempfile
import pytest

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
DEFS_PATH = os.path.join(SCRIPTS_DIR, "experiment_defs.sh")


def bash_eval(script_fragment, timeout=10):
    """Source experiment_defs.sh and evaluate a bash fragment, return stdout."""
    full = f'source "{DEFS_PATH}" && {script_fragment}'
    result = subprocess.run(
        ["bash", "-c", full],
        capture_output=True, text=True, timeout=timeout,
        cwd=os.path.dirname(SCRIPTS_DIR),
    )
    return result.stdout.strip(), result.stderr.strip(), result.returncode


def bash_array(array_name):
    """Return a python list from a bash array variable."""
    stdout, _, _ = bash_eval(f'echo "${{#{array_name}[@]}}" && printf "%s\\n" "${{{array_name}[@]}}"')
    lines = stdout.split("\n")
    count = int(lines[0])
    values = lines[1:] if count > 0 else []
    return values


# ---------------------------------------------------------------------------
# Syntax
# ---------------------------------------------------------------------------

class TestSyntax:
    def test_bash_syntax_valid(self):
        result = subprocess.run(
            ["bash", "-n", DEFS_PATH],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"Syntax error: {result.stderr}"

    def test_can_source(self):
        stdout, stderr, rc = bash_eval("echo ok")
        assert rc == 0, f"Failed to source: {stderr}"
        assert stdout == "ok"


# ---------------------------------------------------------------------------
# Protocol arrays
# ---------------------------------------------------------------------------

class TestProtocolArrays:
    def test_zoo_jetpack_has_5_protocols(self):
        # Mencius excluded due to heap corruption (glibc 2.35 binary on 2.41 host)
        vals = bash_array("ZOO_JETPACK_PROTOCOLS")
        assert len(vals) == 5

    def test_zoo_origin_has_5_protocols(self):
        # Mencius excluded due to heap corruption (glibc 2.35 binary on 2.41 host)
        vals = bash_array("ZOO_ORIGIN_PROTOCOLS")
        assert len(vals) == 5

    def test_zoo_jetpack_uses_rule_raft_not_fpga(self):
        vals = bash_array("ZOO_JETPACK_PROTOCOLS")
        assert "rule_raft" in vals
        assert "rule_fpga_raft" not in vals

    def test_zoo_protocols_match_pairwise(self):
        """Each ZOO_ORIGIN_PROTOCOLS[i] should correspond to ZOO_JETPACK_PROTOCOLS[i]."""
        origins = bash_array("ZOO_ORIGIN_PROTOCOLS")
        jetpacks = bash_array("ZOO_JETPACK_PROTOCOLS")
        assert len(origins) == len(jetpacks)
        for o, j in zip(origins, jetpacks):
            family = o.replace("none_", "")
            assert j == f"rule_{family}", f"{o} should pair with rule_{family}, got {j}"

    def test_zoo_origin_protocols_expected(self):
        # Mencius excluded due to heap corruption
        vals = bash_array("ZOO_ORIGIN_PROTOCOLS")
        expected = {"none_raft", "none_copilot",
                    "none_mongodb", "none_etcd", "none_zookeeper"}
        assert set(vals) == expected

    def test_zoo_jetpack_protocols_expected(self):
        # Mencius excluded due to heap corruption
        vals = bash_array("ZOO_JETPACK_PROTOCOLS")
        expected = {"rule_raft", "rule_copilot",
                    "rule_mongodb", "rule_etcd", "rule_zookeeper"}
        assert set(vals) == expected

    def test_legacy_jetpack_uses_fpga_raft(self):
        vals = bash_array("LEGACY_JETPACK_PROTOCOLS")
        assert "rule_fpga_raft" in vals

    def test_legacy_has_4_families(self):
        vals = bash_array("LEGACY_ORIGIN_PROTOCOLS")
        assert len(vals) == 4

    def test_zoo_concs_arrays_has_5_entries(self):
        # Mencius excluded due to heap corruption
        vals = bash_array("ZOO_CONCS_ARRAYS")
        assert len(vals) == 5


# ---------------------------------------------------------------------------
# Mode definitions
# ---------------------------------------------------------------------------

class TestModes:
    def test_mode_original(self):
        stdout, _, _ = bash_eval('echo $MODE_ORIGINAL')
        assert stdout == "0"

    def test_mode_fastpath100(self):
        stdout, _, _ = bash_eval('echo $MODE_FASTPATH100')
        assert stdout == "100"

    def test_mode_adaptive(self):
        stdout, _, _ = bash_eval('echo $MODE_ADAPTIVE')
        assert stdout == "101"

    def test_all_fastpath_modes_count(self):
        vals = bash_array("ALL_FASTPATH_MODES")
        assert len(vals) == 3
        assert set(vals) == {"0", "100", "101"}

    def test_mode_flag_for_original(self):
        stdout, _, _ = bash_eval('mode_flag_for original')
        assert stdout == "0"

    def test_mode_flag_for_adaptive(self):
        stdout, _, _ = bash_eval('mode_flag_for adaptive')
        assert stdout == "101"

    def test_mode_flag_for_passthrough(self):
        stdout, _, _ = bash_eval('mode_flag_for 42')
        assert stdout == "42"


# ---------------------------------------------------------------------------
# Concurrency arrays
# ---------------------------------------------------------------------------

class TestConcurrencyArrays:
    def test_raft_concs_non_empty(self):
        vals = bash_array("RAFT_CONCS")
        assert len(vals) >= 10

    def test_copilot_concs_non_empty(self):
        vals = bash_array("COPILOT_CONCS")
        assert len(vals) >= 10

    def test_mencius_concs_non_empty(self):
        vals = bash_array("MENCIUS_CONCS")
        assert len(vals) >= 10

    def test_mongodb_concs_non_empty(self):
        vals = bash_array("MONGODB_CONCS")
        assert len(vals) >= 10

    def test_etcd_concs_non_empty(self):
        vals = bash_array("ETCD_CONCS")
        assert len(vals) >= 10

    def test_zookeeper_concs_non_empty(self):
        vals = bash_array("ZOOKEEPER_CONCS")
        assert len(vals) >= 10

    def test_all_concs_start_with_concurrent(self):
        for arr in ["RAFT_CONCS", "COPILOT_CONCS", "MENCIUS_CONCS",
                     "MONGODB_CONCS", "ETCD_CONCS", "ZOOKEEPER_CONCS"]:
            vals = bash_array(arr)
            for v in vals:
                assert v.startswith("concurrent_"), f"{arr}: {v} doesn't start with concurrent_"

    def test_all_concs_start_at_1(self):
        """Every concurrency array should start with concurrent_1."""
        for arr in ["RAFT_CONCS", "COPILOT_CONCS", "MENCIUS_CONCS",
                     "MONGODB_CONCS", "ETCD_CONCS", "ZOOKEEPER_CONCS"]:
            vals = bash_array(arr)
            assert vals[0] == "concurrent_1", f"{arr} should start with concurrent_1, got {vals[0]}"

    def test_concs_array_for_raft(self):
        stdout, _, _ = bash_eval('concs_array_for "none_raft"')
        assert stdout == "RAFT_CONCS"

    def test_concs_array_for_rule_raft(self):
        stdout, _, _ = bash_eval('concs_array_for "rule_raft"')
        assert stdout == "RAFT_CONCS"

    def test_concs_array_for_copilot(self):
        stdout, _, _ = bash_eval('concs_array_for "rule_copilot"')
        assert stdout == "COPILOT_CONCS"

    def test_concs_array_for_etcd(self):
        stdout, _, _ = bash_eval('concs_array_for "none_etcd"')
        assert stdout == "ETCD_CONCS"

    def test_concs_array_for_zookeeper(self):
        stdout, _, _ = bash_eval('concs_array_for "rule_zookeeper"')
        assert stdout == "ZOOKEEPER_CONCS"

    def test_concs_array_for_unknown_falls_back(self):
        stdout, _, _ = bash_eval('concs_array_for "some_unknown"')
        assert stdout == "DOCKER_SWEEP_CONCS"


# ---------------------------------------------------------------------------
# Site configs
# ---------------------------------------------------------------------------

class TestSiteConfigs:
    def test_zoo_site(self):
        stdout, _, _ = bash_eval('echo $SITE_ZOO_SWEEP')
        assert stdout == "30c1s5r5p-zoo"

    def test_aws_site(self):
        stdout, _, _ = bash_eval('echo $SITE_AWS_SWEEP')
        assert stdout == "60c1s5r10p"


# ---------------------------------------------------------------------------
# Command generation helpers
# ---------------------------------------------------------------------------

class TestBuildResultPrefix:
    def test_basic_prefix(self):
        stdout, _, _ = bash_eval(
            'build_result_prefix "rule_raft" "30c1s5r5p-zoo" "rw_1000000" "concurrent_100" "101" "YCSB_A"'
        )
        assert stdout == "rule_raft-30c1s5r5p-zoo-rw_1000000-concurrent_100-101-YCSB_A"

    def test_default_ycsb(self):
        stdout, _, _ = bash_eval(
            'build_result_prefix "none_copilot" "30c1s5r5p-zoo" "rw_1000000" "concurrent_50" "0"'
        )
        assert stdout == "none_copilot-30c1s5r5p-zoo-rw_1000000-concurrent_50-0-YCSB_A"


class TestBuildDeptranCmd:
    def test_basic_command(self):
        stdout, _, _ = bash_eval(
            'build_deptran_cmd "/home/users/ztang/janus" "rule_raft" "30c1s5r5p-zoo" '
            '"rw_1000000" "concurrent_100" "101" "30" "YCSB_A" "false"'
        )
        assert "build/deptran_server" in stdout
        assert "-f config/rule_raft.yml" in stdout
        assert "-f config/30c1s5r5p-zoo.yml" in stdout
        assert "-f config/rw_1000000.yml" in stdout
        assert "-f config/concurrent_100.yml" in stdout
        assert "-f config/YCSB_A.yml" in stdout
        assert "-m 101" in stdout
        assert "-d 30" in stdout
        assert "failover" not in stdout

    def test_with_failover(self):
        stdout, _, _ = bash_eval(
            'build_deptran_cmd "/home/users/ztang/janus" "rule_raft" "30c1s5r5p-zoo" '
            '"rw_1000000" "concurrent_100" "101" "30" "YCSB_A" "true"'
        )
        assert "-f config/failover.yml" in stdout


# ---------------------------------------------------------------------------
# Zoo matrix generation
# ---------------------------------------------------------------------------

class TestZooMatrixGeneration:
    def test_concurrency_sweep_count(self):
        """Zoo concurrency sweep should produce the expected experiment count.

        Formula: sum over 6 families of (1 original + 3 jetpack modes) * len(concs_array)
        = sum(4 * len(concs_i))
        """
        stdout, _, rc = bash_eval(
            'generate_zoo_matrix "concurrency_sweep" "30c1s5r5p-zoo" && echo ${#GENERATED_CONFIGS[@]}'
        )
        assert rc == 0
        count = int(stdout)
        # Raft: 4*24=96, Copilot: 4*22=88, (Mencius excluded: heap corruption)
        # MongoDB: 4*14=56, etcd: 4*22=88, ZK: 4*22=88
        assert count == 416, f"Expected 416 experiments, got {count}"

    def test_concurrency_sweep_format(self):
        """Each config line should have the right comma-separated format."""
        stdout, _, _ = bash_eval(
            'generate_zoo_matrix "concurrency_sweep" "30c1s5r5p-zoo" && '
            'echo "${GENERATED_CONFIGS[0]}"'
        )
        parts = stdout.split(",")
        assert len(parts) == 6
        assert parts[0] == "30c1s5r5p-zoo"
        assert parts[2] == "rw_1000000"
        assert parts[4] in ("0", "100", "101")
        assert parts[5] == "YCSB_A"

    def test_concurrency_sweep_has_all_protocols(self):
        stdout, _, _ = bash_eval(
            'generate_zoo_matrix "concurrency_sweep" "30c1s5r5p-zoo" && '
            'printf "%s\\n" "${GENERATED_CONFIGS[@]}"'
        )
        lines = stdout.split("\n")
        protocols_seen = set()
        for line in lines:
            parts = line.split(",")
            protocols_seen.add(parts[1])
        # Mencius excluded due to heap corruption
        expected = {"none_raft", "rule_raft", "none_copilot", "rule_copilot",
                    "none_mongodb", "rule_mongodb",
                    "none_etcd", "rule_etcd", "none_zookeeper", "rule_zookeeper"}
        assert protocols_seen == expected

    def test_zipf_sweep_needs_fixed_concs(self):
        """Zipf sweep should fail if ZOO_FIXED_CONCS not set."""
        _, stderr, rc = bash_eval(
            'generate_zoo_matrix "zipf_sweep" "30c1s5r5p-zoo"'
        )
        assert rc != 0
        assert "ZOO_FIXED_CONCS not set" in stderr

    def test_keyrange_sweep_needs_fixed_concs(self):
        _, stderr, rc = bash_eval(
            'generate_zoo_matrix "keyrange_sweep" "30c1s5r5p-zoo"'
        )
        assert rc != 0
        assert "ZOO_FIXED_CONCS not set" in stderr

    def test_zipf_sweep_with_fixed_concs(self):
        """Zipf sweep with mock fixed concs should produce expected count."""
        # 6 families * 6 zipf workloads * 4 modes = 144
        stdout, stderr, rc = bash_eval(
            'ZOO_FIXED_CONCS=("concurrent_400" "concurrent_160" "concurrent_30" '
            '"concurrent_60" "concurrent_50" "concurrent_50") && '
            'generate_zoo_matrix "zipf_sweep" "30c1s5r5p-zoo" && '
            'echo ${#GENERATED_CONFIGS[@]}'
        )
        assert rc == 0, f"stderr: {stderr}"
        count = int(stdout)
        # 5 families (Mencius excluded) * 6 zipf * 4 modes = 120
        assert count == 120, f"Expected 120, got {count}"

    def test_keyrange_sweep_with_fixed_concs(self):
        """Keyrange sweep with mock fixed concs should produce expected count."""
        # 5 families (Mencius excluded) * 7 key_range workloads * 4 modes = 140
        stdout, stderr, rc = bash_eval(
            'ZOO_FIXED_CONCS=("concurrent_400" "concurrent_160" "concurrent_30" '
            '"concurrent_60" "concurrent_50" "concurrent_50") && '
            'generate_zoo_matrix "keyrange_sweep" "30c1s5r5p-zoo" && '
            'echo ${#GENERATED_CONFIGS[@]}'
        )
        assert rc == 0, f"stderr: {stderr}"
        count = int(stdout)
        assert count == 140, f"Expected 140, got {count}"


# ---------------------------------------------------------------------------
# Load fixed concs
# ---------------------------------------------------------------------------

class TestLoadZooFixedConcs:
    def test_load_from_json(self, tmp_path):
        fc = {
            "raft": "concurrent_400",
            "copilot": "concurrent_160",
            "mencius": "concurrent_30",
            "mongodb": "concurrent_60",
            "etcd": "concurrent_50",
            "zookeeper": "concurrent_50",
        }
        json_path = tmp_path / "fixed_conc.json"
        json_path.write_text(json.dumps(fc))

        stdout, _, rc = bash_eval(
            f'load_zoo_fixed_concs "{json_path}" && '
            f'echo "${{#ZOO_FIXED_CONCS[@]}}" && '
            f'printf "%s\\n" "${{ZOO_FIXED_CONCS[@]}}"'
        )
        assert rc == 0
        lines = stdout.split("\n")
        # 5 protocols (Mencius excluded)
        assert lines[0] == "5"
        assert "concurrent_400" in lines  # raft
        assert "concurrent_160" in lines  # copilot

    def test_missing_file_warns(self, tmp_path):
        _, stderr, rc = bash_eval(
            f'load_zoo_fixed_concs "{tmp_path}/nonexistent.json"'
        )
        assert rc != 0
        assert "not found" in stderr

    def test_missing_protocol_uses_default(self, tmp_path):
        """If a protocol is missing from JSON, it should use concurrent_50 default."""
        fc = {"raft": "concurrent_400"}  # only raft
        json_path = tmp_path / "fixed_conc.json"
        json_path.write_text(json.dumps(fc))

        stdout, stderr, rc = bash_eval(
            f'load_zoo_fixed_concs "{json_path}" && '
            f'echo "${{#ZOO_FIXED_CONCS[@]}}" && '
            f'printf "%s\\n" "${{ZOO_FIXED_CONCS[@]}}"'
        )
        assert rc == 0
        lines = stdout.split("\n")
        # 5 protocols (Mencius excluded)
        assert lines[0] == "5"
        # raft should be concurrent_400, others concurrent_50 (default)
        assert lines[1] == "concurrent_400"
        assert "WARNING" in stderr


# ---------------------------------------------------------------------------
# Extended sweep ranges (Track 8B)
# ---------------------------------------------------------------------------

class TestExtendedSweepRanges:
    """Verify concurrency arrays extend beyond the 2026-03-23 baseline ranges."""

    def test_raft_extends_beyond_1000(self):
        vals = bash_array("RAFT_CONCS")
        nums = [int(v.replace("concurrent_", "")) for v in vals]
        assert max(nums) >= 1500, f"Raft max conc {max(nums)} should be >= 1500"

    def test_etcd_extends_beyond_120(self):
        vals = bash_array("ETCD_CONCS")
        nums = [int(v.replace("concurrent_", "")) for v in vals]
        assert max(nums) >= 400, f"etcd max conc {max(nums)} should be >= 400"

    def test_zookeeper_extends_beyond_120(self):
        vals = bash_array("ZOOKEEPER_CONCS")
        nums = [int(v.replace("concurrent_", "")) for v in vals]
        assert max(nums) >= 400, f"ZooKeeper max conc {max(nums)} should be >= 400"

    def test_etcd_has_dense_coverage_200_400(self):
        """etcd should have points in the expected turning-point region."""
        vals = bash_array("ETCD_CONCS")
        nums = sorted(int(v.replace("concurrent_", "")) for v in vals)
        region = [n for n in nums if 200 <= n <= 400]
        assert len(region) >= 3, f"etcd needs >= 3 points in [200,400], got {region}"

    def test_zookeeper_has_dense_coverage_200_400(self):
        """ZooKeeper should have points in the expected turning-point region."""
        vals = bash_array("ZOOKEEPER_CONCS")
        nums = sorted(int(v.replace("concurrent_", "")) for v in vals)
        region = [n for n in nums if 200 <= n <= 400]
        assert len(region) >= 3, f"ZooKeeper needs >= 3 points in [200,400], got {region}"

    def test_etcd_and_zookeeper_ranges_match(self):
        """etcd and ZooKeeper should have the same sweep range (similar protocols)."""
        etcd = bash_array("ETCD_CONCS")
        zk = bash_array("ZOOKEEPER_CONCS")
        assert etcd == zk, "etcd and ZooKeeper should have matching concurrency ranges"


# ---------------------------------------------------------------------------
# Spot-check script (scripts/run_spot_check.sh)
# ---------------------------------------------------------------------------

SPOT_CHECK_PATH = os.path.join(SCRIPTS_DIR, "run_spot_check.sh")


class TestSpotCheckScript:
    """Tests for run_spot_check.sh — validates syntax, arg parsing, config generation."""

    def test_bash_syntax_valid(self):
        result = subprocess.run(
            ["bash", "-n", SPOT_CHECK_PATH],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, f"Syntax error: {result.stderr}"

    def test_help_flag(self):
        result = subprocess.run(
            ["bash", SPOT_CHECK_PATH, "--help"],
            capture_output=True, text=True, timeout=5,
        )
        assert result.returncode == 0
        assert "--exp-dir" in result.stdout

    def test_missing_exp_dir_errors(self):
        result = subprocess.run(
            ["bash", SPOT_CHECK_PATH, "--protocol", "etcd", "--concs", "concurrent_100"],
            capture_output=True, text=True, timeout=5,
        )
        assert result.returncode != 0
        assert "--exp-dir is required" in result.stdout

    def test_missing_config_source_errors(self, tmp_path):
        exp_dir = tmp_path / "exp"
        exp_dir.mkdir()
        result = subprocess.run(
            ["bash", SPOT_CHECK_PATH, "--exp-dir", str(exp_dir)],
            capture_output=True, text=True, timeout=5,
        )
        assert result.returncode != 0
        assert "specify either" in result.stdout

    def test_dry_run_with_config_file(self, tmp_path):
        exp_dir = tmp_path / "exp"
        exp_dir.mkdir()
        cfg = tmp_path / "configs.txt"
        cfg.write_text(
            "# comment\n"
            "30c1s5r5p-zoo,none_etcd,rw_1000000,concurrent_200,0,YCSB_A\n"
            "30c1s5r5p-zoo,rule_etcd,rw_1000000,concurrent_200,100,YCSB_A\n"
        )
        # Dry run doesn't need setup.json (it exits before reading it)
        # but the script sources experiment_defs.sh and reads setup.json early.
        # Create a minimal setup.json so the script can proceed to dry-run.
        setup = tmp_path / "setup.json"
        setup.write_text(json.dumps({
            "server_username": "test",
            "n_server": 1,
            "environment": "zoo",
            "zoo_directory": "/tmp/test",
            "servers": [{"server_0_ip": "127.0.0.1"}],
        }))
        # Symlink experiment_defs.sh into tmp_path so the script can source it
        # Actually, the script derives SCRIPT_DIR from its own location, so we
        # need to create a wrapper that overrides SCRIPT_DIR.
        wrapper = tmp_path / "run_dry.sh"
        wrapper.write_text(
            f'#!/bin/bash\n'
            f'export SCRIPT_DIR_OVERRIDE="{tmp_path}"\n'
            f'# Copy experiment_defs.sh to tmp so the script can source it\n'
            f'cp "{SCRIPTS_DIR}/experiment_defs.sh" "{tmp_path}/experiment_defs.sh"\n'
            f'cp "{SPOT_CHECK_PATH}" "{tmp_path}/run_spot_check.sh"\n'
            f'bash "{tmp_path}/run_spot_check.sh" '
            f'--exp-dir "{exp_dir}" --configs "{cfg}" --dry-run\n'
        )
        result = subprocess.run(
            ["bash", str(wrapper)],
            capture_output=True, text=True, timeout=10,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"
        assert "DRY RUN" in result.stdout
        assert "Configs:  2" in result.stdout

    def test_dry_run_protocol_mode(self, tmp_path):
        """--protocol + --concs generates 4 configs per concurrency (orig + 3 jetpack modes)."""
        exp_dir = tmp_path / "exp"
        exp_dir.mkdir()
        setup = tmp_path / "setup.json"
        setup.write_text(json.dumps({
            "server_username": "test",
            "n_server": 1,
            "environment": "zoo",
            "zoo_directory": "/tmp/test",
            "servers": [{"server_0_ip": "127.0.0.1"}],
        }))
        # Copy scripts into tmp_path
        import shutil
        shutil.copy(os.path.join(SCRIPTS_DIR, "experiment_defs.sh"), tmp_path / "experiment_defs.sh")
        shutil.copy(SPOT_CHECK_PATH, tmp_path / "run_spot_check.sh")

        result = subprocess.run(
            ["bash", str(tmp_path / "run_spot_check.sh"),
             "--exp-dir", str(exp_dir),
             "--protocol", "etcd",
             "--concs", "concurrent_200,concurrent_300",
             "--dry-run"],
            capture_output=True, text=True, timeout=10,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0, f"stderr: {result.stderr}\nstdout: {result.stdout}"
        assert "DRY RUN" in result.stdout
        # 2 concurrencies × 4 modes = 8 configs
        assert "Configs:  8" in result.stdout
