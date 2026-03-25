#!/usr/bin/env python3
"""Tests for mencius_cpu_audit.py"""

import json
import os
import pytest

from mencius_cpu_audit import (
    extract_mencius_cpu_data,
    scan_mencius_runs,
    build_audit_report,
    export_report,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_mencius_res(directory, protocol, conc, mode, server,
                       cpu_values=None, throughput=None,
                       fp_count=None, orig_count=None,
                       site="30c1s5r5p-zoo", workload="rw_1000000",
                       ycsb="YCSB_A"):
    """Write a Mencius .res file with controlled content."""
    fname = (f"{protocol}-{site}-{workload}-concurrent_{conc}-"
             f"{mode}-{ycsb}-{server}.res")
    path = os.path.join(directory, fname)
    with open(path, "w") as f:
        f.write("I [s_main.cc:432] 2026-03-23 10:00:00.000 | PWD : /home/user\n")

        if cpu_values:
            for cv in cpu_values:
                if cv == 0.0:
                    f.write(f"I | [CPU-MENC] Let go fastpath due to leader CPU {cv:.2f}, "
                            f"max_leader_avg - 60.0 {cv - 60.0:.2f} <= rand=15.00\n")
                else:
                    f.write(f"I | [CPU-MENC] Disabling fastpath due to leader CPU {cv:.2f}, "
                            f"max_leader_avg - 60.0 {cv - 60.0:.2f} > rand=5.00\n")

        if fp_count is not None:
            f.write(f"I | All-fast-path-attempts           statistics   "
                    f"count     {fp_count}   0pct    10.00  50pct    15.00  "
                    f"90pct    20.00  99pct    30.00    ave    16.00\n")
        if orig_count is not None:
            f.write(f"I | All-original-path-attempts       statistics   "
                    f"count     {orig_count}   0pct    10.00  50pct    15.00  "
                    f"90pct    20.00  99pct    30.00    ave    16.00\n")
        if throughput is not None:
            f.write(f"Mid throughput is {throughput}\n")
        f.write("I | server_shutdown\n")
    return path


# ---------------------------------------------------------------------------
# TestExtractMenciusCpuData
# ---------------------------------------------------------------------------

class TestExtractMenciusCpuData:
    def test_all_zero_cpu(self, tmp_path):
        d = str(tmp_path)
        path = _write_mencius_res(d, "rule_mencius", 25, "101", "zoo0",
                                   cpu_values=[0.0] * 100, throughput=3.2)
        result = extract_mencius_cpu_data(path)
        assert result["total_cpu_lines"] == 100
        assert result["cpu_zero_count"] == 100
        assert result["cpu_nonzero_count"] == 0
        assert result["unique_cpu_values"] == [0.0]

    def test_mixed_cpu_values(self, tmp_path):
        d = str(tmp_path)
        path = _write_mencius_res(d, "rule_mencius", 25, "101", "zoo0",
                                   cpu_values=[0.0, 45.5, 0.0, 72.3],
                                   throughput=100.0)
        result = extract_mencius_cpu_data(path)
        assert result["total_cpu_lines"] == 4
        assert result["cpu_zero_count"] == 2
        assert result["cpu_nonzero_count"] == 2
        assert 45.5 in result["unique_cpu_values"]
        assert 72.3 in result["unique_cpu_values"]

    def test_no_cpu_lines(self, tmp_path):
        d = str(tmp_path)
        path = _write_mencius_res(d, "none_mencius", 25, "0", "zoo0",
                                   throughput=146.5)
        result = extract_mencius_cpu_data(path)
        assert result["total_cpu_lines"] == 0

    def test_throughput_extraction(self, tmp_path):
        d = str(tmp_path)
        path = _write_mencius_res(d, "rule_mencius", 25, "101", "zoo0",
                                   cpu_values=[0.0], throughput=145.4)
        result = extract_mencius_cpu_data(path)
        assert result["throughput"] == pytest.approx(145.4)

    def test_path_counts(self, tmp_path):
        d = str(tmp_path)
        path = _write_mencius_res(d, "rule_mencius", 25, "101", "zoo0",
                                   fp_count=500, orig_count=200,
                                   throughput=50.0)
        result = extract_mencius_cpu_data(path)
        assert result["fp_count"] == 500
        assert result["orig_count"] == 200

    def test_missing_file(self, tmp_path):
        result = extract_mencius_cpu_data(str(tmp_path / "nonexistent.res"))
        assert result["total_cpu_lines"] == 0
        assert result["throughput"] is None


# ---------------------------------------------------------------------------
# TestScanMenciusRuns
# ---------------------------------------------------------------------------

class TestScanMenciusRuns:
    def test_finds_mencius_files(self, tmp_path):
        d = str(tmp_path)
        _write_mencius_res(d, "rule_mencius", 25, "101", "zoo0",
                           cpu_values=[0.0], throughput=3.2)
        _write_mencius_res(d, "none_mencius", 25, "0", "zoo0",
                           throughput=146.5)
        results = scan_mencius_runs(d)
        assert len(results) == 2
        protos = {r["protocol"] for r in results}
        assert "rule_mencius" in protos
        assert "none_mencius" in protos

    def test_ignores_non_mencius(self, tmp_path):
        d = str(tmp_path)
        # Write a raft file — should be ignored
        fname = "rule_raft-30c1s5r5p-zoo-rw_1000000-concurrent_100-101-YCSB_A-zoo0.res"
        with open(os.path.join(d, fname), "w") as f:
            f.write("Mid throughput is 1500.0\n")
        _write_mencius_res(d, "rule_mencius", 25, "101", "zoo0",
                           throughput=3.2)
        results = scan_mencius_runs(d)
        assert len(results) == 1
        assert results[0]["protocol"] == "rule_mencius"

    def test_empty_directory(self, tmp_path):
        results = scan_mencius_runs(str(tmp_path))
        assert results == []


# ---------------------------------------------------------------------------
# TestBuildAuditReport
# ---------------------------------------------------------------------------

class TestBuildAuditReport:
    def _make_runs(self, tmp_path):
        d = str(tmp_path)
        for conc in [10, 25]:
            _write_mencius_res(d, "none_mencius", conc, "0", "zoo0",
                               throughput=150.0 * conc / 25)
            _write_mencius_res(d, "rule_mencius", conc, "0", "zoo0",
                               throughput=148.0 * conc / 25)
            _write_mencius_res(d, "rule_mencius", conc, "100", "zoo0",
                               throughput=0.0 if conc > 12 else 145.0,
                               fp_count=100)
            _write_mencius_res(d, "rule_mencius", conc, "101", "zoo0",
                               cpu_values=[0.0] * 50,
                               throughput=3.2 if conc > 12 else 140.0,
                               fp_count=80, orig_count=20)
        return scan_mencius_runs(d)

    def test_report_structure(self, tmp_path):
        runs = self._make_runs(tmp_path)
        report = build_audit_report(runs)
        assert "summary" in report
        assert "root_cause" in report
        assert "throughput_comparison" in report

    def test_100pct_zero_cpu(self, tmp_path):
        runs = self._make_runs(tmp_path)
        report = build_audit_report(runs)
        assert report["summary"]["pct_zero"] == 100.0

    def test_root_cause_documented(self, tmp_path):
        runs = self._make_runs(tmp_path)
        report = build_audit_report(runs)
        assert report["root_cause"]["bug"] == "leader_cpu_always_zero"
        assert "source_files" in report["root_cause"]
        assert "cpu_sampling" in report["root_cause"]["source_files"]

    def test_throughput_comparison(self, tmp_path):
        runs = self._make_runs(tmp_path)
        report = build_audit_report(runs)
        tc = report["throughput_comparison"]
        assert len(tc) > 0
        # Check that concurrency 25 adaptive has low throughput
        conc25 = [t for t in tc if t["concurrency"] == 25]
        assert len(conc25) == 1
        assert conc25[0]["mode_101_avg_tp"] < 10

    def test_empty_runs(self):
        report = build_audit_report([])
        assert report["summary"]["total_adaptive_cpu_lines"] == 0


# ---------------------------------------------------------------------------
# TestExportReport
# ---------------------------------------------------------------------------

class TestExportReport:
    def test_creates_json(self, tmp_path):
        report = {"summary": {"total": 0}}
        path = str(tmp_path / "audit.json")
        export_report(report, path)
        assert os.path.isfile(path)
        with open(path) as f:
            loaded = json.load(f)
        assert loaded["summary"]["total"] == 0


# ---------------------------------------------------------------------------
# TestWithRealData
# ---------------------------------------------------------------------------

ZOO_RESULT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "results", "2026-03-23-10:26:07-zoo-5machines"
)


@pytest.mark.skipif(
    not os.path.isdir(ZOO_RESULT_DIR),
    reason="Zoo result directory not found"
)
class TestWithRealData:
    def test_finds_mencius_runs(self):
        runs = scan_mencius_runs(ZOO_RESULT_DIR)
        assert len(runs) > 100

    def test_cpu_always_zero(self):
        runs = scan_mencius_runs(ZOO_RESULT_DIR)
        report = build_audit_report(runs)
        assert report["summary"]["pct_zero"] == 100.0

    def test_adaptive_broken_at_high_conc(self):
        runs = scan_mencius_runs(ZOO_RESULT_DIR)
        report = build_audit_report(runs)
        # At concurrent_25, adaptive should have near-zero throughput
        tc = report["throughput_comparison"]
        conc25 = [t for t in tc if t["concurrency"] == 25]
        if conc25:
            assert conc25[0]["mode_101_avg_tp"] is not None
            # Adaptive is broken — very low throughput
            assert conc25[0]["mode_101_avg_tp"] < 50

    def test_mode100_also_broken(self):
        """Fast path (mode=100) itself collapses at high concurrency."""
        runs = scan_mencius_runs(ZOO_RESULT_DIR)
        report = build_audit_report(runs)
        tc = report["throughput_comparison"]
        conc25 = [t for t in tc if t["concurrency"] == 25]
        if conc25 and conc25[0]["mode_100_avg_tp"] is not None:
            # mode 100 should also be broken or very low
            assert conc25[0]["mode_100_avg_tp"] < conc25[0].get("none_mencius_avg_tp", 999)
