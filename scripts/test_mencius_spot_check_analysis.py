#!/usr/bin/env python3
"""Tests for mencius_spot_check_analysis.py"""

import json
import os
import pytest

from mencius_spot_check_analysis import (
    parse_res_file,
    collect_spot_check_data,
    build_comparison_table,
    assess_sanity,
    export_report,
    SPOT_CHECK_CONCS,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_res(directory, protocol, conc, mode, server,
               throughput=None, fp_count=None, orig_count=None,
               eff_count=None, cpu_log_format="none", cpu_log_count=0):
    """Write a Mencius .res file."""
    fname = (f"{protocol}-30c1s5r5p-zoo-rw_1000000-concurrent_{conc}-"
             f"{mode}-YCSB_A-{server}.res")
    path = os.path.join(directory, fname)
    with open(path, "w") as f:
        f.write("I [s_main.cc:432] 2026-03-25 12:00:00.000 | PWD : /home/user\n")
        if cpu_log_format == "new":
            for i in range(cpu_log_count):
                f.write(f"I | [CPU-MENC] avg_all=0.00 avg_leaders=0.00 "
                        f"max_leader=0.00 threshold=-60.00 rand=15.00 "
                        f"cpu_disabled=0 go_fp=1 fp_cnt={i * 500}\n")
        elif cpu_log_format == "old":
            for i in range(cpu_log_count):
                f.write(f"I | [CPU-MENC] Let go fastpath due to leader CPU 0.00, "
                        f"max_leader_avg - 60.0 -60.00 <= rand=15.00\n")
        if fp_count is not None:
            f.write(f"I | All-fast-path-attempts           statistics   "
                    f"count     {fp_count}   0pct    10.00  50pct    15.00  "
                    f"90pct    20.00  99pct    30.00    ave    16.00\n")
        if orig_count is not None:
            f.write(f"I | All-original-path-attempts       statistics   "
                    f"count     {orig_count}   0pct    10.00  50pct    15.00  "
                    f"90pct    20.00  99pct    30.00    ave    16.00\n")
        if eff_count is not None:
            f.write(f"I | All-efficient-attempts           statistics   "
                    f"count     {eff_count}   0pct    10.00  50pct    15.00  "
                    f"90pct    20.00  99pct    30.00    ave    16.00\n")
        if throughput is not None:
            f.write(f"Mid throughput is {throughput}\n")
        f.write("I | server_shutdown\n")
    return path


def _make_full_conc(d, conc, none_tp, rule0_tp, rule100_tp, rule101_tp,
                    cpu_fmt="new"):
    """Create all mode .res files for a concurrency level, 5 servers each."""
    for i in range(5):
        srv = f"zoo{i}"
        _write_res(d, "none_mencius", conc, "0", srv,
                   throughput=none_tp, orig_count=1000)
        _write_res(d, "rule_mencius", conc, "0", srv,
                   throughput=rule0_tp, orig_count=1000)
        _write_res(d, "rule_mencius", conc, "100", srv,
                   throughput=rule100_tp, fp_count=800, orig_count=200)
        _write_res(d, "rule_mencius", conc, "101", srv,
                   throughput=rule101_tp, fp_count=600, orig_count=400,
                   cpu_log_format=cpu_fmt, cpu_log_count=5)


# ---------------------------------------------------------------------------
# TestParseResFile
# ---------------------------------------------------------------------------

class TestParseResFile:
    def test_basic_metrics(self, tmp_path):
        d = str(tmp_path)
        path = _write_res(d, "rule_mencius", 25, "101", "zoo0",
                          throughput=145.0, fp_count=500, orig_count=200)
        result = parse_res_file(path)
        assert result["throughput"] == pytest.approx(145.0)
        assert result["fp_count"] == 500
        assert result["orig_count"] == 200

    def test_new_cpu_format(self, tmp_path):
        d = str(tmp_path)
        path = _write_res(d, "rule_mencius", 25, "101", "zoo0",
                          throughput=100.0, cpu_log_format="new", cpu_log_count=3)
        result = parse_res_file(path)
        assert result["cpu_log_format"] == "new"
        assert result["cpu_log_count"] == 3

    def test_old_cpu_format(self, tmp_path):
        d = str(tmp_path)
        path = _write_res(d, "rule_mencius", 25, "101", "zoo0",
                          throughput=100.0, cpu_log_format="old", cpu_log_count=10)
        result = parse_res_file(path)
        assert result["cpu_log_format"] == "old"
        assert result["cpu_log_count"] == 10

    def test_missing_file(self, tmp_path):
        result = parse_res_file(str(tmp_path / "nonexistent.res"))
        assert result["throughput"] is None

    def test_no_cpu_logs(self, tmp_path):
        d = str(tmp_path)
        path = _write_res(d, "none_mencius", 25, "0", "zoo0", throughput=150.0)
        result = parse_res_file(path)
        assert result["cpu_log_format"] == "none"


# ---------------------------------------------------------------------------
# TestCollectSpotCheckData
# ---------------------------------------------------------------------------

class TestCollectSpotCheckData:
    def test_collects_data(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 150, 148, 145, 3)
        data = collect_spot_check_data(d, concs=[25])
        assert len(data) == 4  # none_0, rule_0, rule_100, rule_101

    def test_correct_server_count(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 150, 148, 145, 3)
        data = collect_spot_check_data(d, concs=[25])
        for key, server_data in data.items():
            assert len(server_data) == 5

    def test_empty_directory(self, tmp_path):
        data = collect_spot_check_data(str(tmp_path))
        assert len(data) == 0


# ---------------------------------------------------------------------------
# TestBuildComparisonTable
# ---------------------------------------------------------------------------

class TestBuildComparisonTable:
    def test_builds_rows(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 150, 148, 0, 3)
        data = collect_spot_check_data(d, concs=[25])
        rows = build_comparison_table(data)
        assert len(rows) == 4

    def test_throughput_aggregation(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 30, 29, 28, 1)
        data = collect_spot_check_data(d, concs=[25])
        rows = build_comparison_table(data)
        none_0 = [r for r in rows if r["protocol"] == "none_mencius" and r["mode"] == "0"]
        assert len(none_0) == 1
        assert none_0[0]["total_throughput"] == pytest.approx(150.0)  # 30*5


# ---------------------------------------------------------------------------
# TestAssessSanity
# ---------------------------------------------------------------------------

class TestAssessSanity:
    def test_broken_fast_path(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 150, 148, 0, 3)
        data = collect_spot_check_data(d, concs=[25])
        rows = build_comparison_table(data)
        findings = assess_sanity(rows)
        warn_msgs = [m for s, m in findings if s == "WARN"]
        assert any("fast path broken" in m for m in warn_msgs)

    def test_healthy_adaptive(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 150, 148, 145, 140)
        data = collect_spot_check_data(d, concs=[25])
        rows = build_comparison_table(data)
        findings = assess_sanity(rows)
        ok_msgs = [m for s, m in findings if s == "OK"]
        assert any("mode=101" in m and ">50%" in m for m in ok_msgs)

    def test_new_log_format_detected(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 150, 148, 145, 140, cpu_fmt="new")
        data = collect_spot_check_data(d, concs=[25])
        rows = build_comparison_table(data)
        findings = assess_sanity(rows)
        ok_msgs = [m for s, m in findings if s == "OK"]
        assert any("new [CPU-MENC] format" in m for m in ok_msgs)

    def test_old_log_format_warned(self, tmp_path):
        d = str(tmp_path)
        _make_full_conc(d, 25, 150, 148, 145, 140, cpu_fmt="old")
        data = collect_spot_check_data(d, concs=[25])
        rows = build_comparison_table(data)
        findings = assess_sanity(rows)
        warn_msgs = [m for s, m in findings if s == "WARN"]
        assert any("OLD" in m for m in warn_msgs)


# ---------------------------------------------------------------------------
# TestExportReport
# ---------------------------------------------------------------------------

class TestExportReport:
    def test_creates_json(self, tmp_path):
        report = {"comparison_table": [], "findings": []}
        path = str(tmp_path / "report.json")
        export_report(report, path)
        assert os.path.isfile(path)
        with open(path) as f:
            loaded = json.load(f)
        assert loaded == report


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
    def test_collects_mencius_data(self):
        data = collect_spot_check_data(ZOO_RESULT_DIR)
        assert len(data) > 0

    def test_builds_table(self):
        data = collect_spot_check_data(ZOO_RESULT_DIR)
        rows = build_comparison_table(data)
        assert len(rows) > 0
