#!/usr/bin/env python3
"""Tests for scp_race_audit.py"""

import json
import os
import pytest

from scp_race_audit import (
    analyze_server_run,
    scan_all_runs,
    build_race_report,
    export_report,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_res(directory, fname, has_stats=True, has_dump=True,
               dump_lines=5000, has_mid_tp=True, has_shutdown=True):
    """Write a .res file with controlled content."""
    path = os.path.join(directory, fname)
    lines = ["I [s_main.cc:432] 2026-03-23 10:00:00.000 | PWD : /home/user"]
    if has_stats:
        lines.append("I | All-efficient-attempts           statistics   count     5000   "
                      "0pct    10.00  50pct    15.00  90pct    20.00  99pct    30.00    ave    16.00")
    if has_mid_tp:
        lines.append("Mid throughput is 1500.0")
    if has_dump:
        lines.append(f"Dumped to results/recent_csv/test.csv with {dump_lines} lines")
    if has_shutdown:
        lines.append("I [server.cc:100] 2026-03-23 10:01:15.000 | server_shutdown")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


def _write_csv(directory, fname, n_lines=5000):
    """Write a CSV file with specified number of data lines (plus header)."""
    path = os.path.join(directory, fname)
    with open(path, "w") as f:
        f.write("col1,col2\n")
        for i in range(n_lines):
            f.write(f"{i},{i*2}\n")
    return path


# ---------------------------------------------------------------------------
# TestAnalyzeServerRun
# ---------------------------------------------------------------------------

class TestAnalyzeServerRun:
    def test_clean_run(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "test-zoo0.res", dump_lines=100)
        _write_csv(d, "test-zoo0.csv", n_lines=100)
        result = analyze_server_run(
            os.path.join(d, "test-zoo0.res"),
            os.path.join(d, "test-zoo0.csv"))
        assert result["race_mode"] == "none"
        assert result["has_csv"]
        assert result["has_dump_line"]

    def test_nfs_cache_lag(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "test-zoo0.res", dump_lines=5000)
        # No CSV file — simulates NFS lag
        result = analyze_server_run(
            os.path.join(d, "test-zoo0.res"),
            os.path.join(d, "test-zoo0.csv"))
        assert result["race_mode"] == "nfs_cache_lag"
        assert "Dumped to" in result["evidence"]

    def test_pkill_before_dump(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "test-zoo0.res", has_dump=False)
        result = analyze_server_run(
            os.path.join(d, "test-zoo0.res"),
            os.path.join(d, "test-zoo0.csv"))
        assert result["race_mode"] == "pkill_before_dump"

    def test_partial_csv(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "test-zoo0.res", dump_lines=5000)
        _write_csv(d, "test-zoo0.csv", n_lines=100)  # Much fewer than 5000
        result = analyze_server_run(
            os.path.join(d, "test-zoo0.res"),
            os.path.join(d, "test-zoo0.csv"))
        assert result["race_mode"] == "partial_csv"
        assert "5000" in result["evidence"]
        assert "100" in result["evidence"]

    def test_no_res_file(self, tmp_path):
        d = str(tmp_path)
        result = analyze_server_run(
            os.path.join(d, "nonexistent.res"),
            os.path.join(d, "nonexistent.csv"))
        assert result["race_mode"] == "no_res"

    def test_csv_with_enough_lines(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "test-zoo0.res", dump_lines=100)
        # 95 lines = 95% of expected = above 90% threshold
        _write_csv(d, "test-zoo0.csv", n_lines=95)
        result = analyze_server_run(
            os.path.join(d, "test-zoo0.res"),
            os.path.join(d, "test-zoo0.csv"))
        assert result["race_mode"] == "none"

    def test_stats_but_no_dump_no_mid_tp(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "test-zoo0.res", has_dump=False, has_mid_tp=False)
        result = analyze_server_run(
            os.path.join(d, "test-zoo0.res"),
            os.path.join(d, "test-zoo0.csv"))
        assert result["race_mode"] == "pkill_before_dump"


# ---------------------------------------------------------------------------
# TestScanAllRuns
# ---------------------------------------------------------------------------

class TestScanAllRuns:
    def test_scans_multiple_files(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "proto-zoo0.res")
        _write_csv(d, "proto-zoo0.csv")
        _write_res(d, "proto-zoo1.res")
        _write_csv(d, "proto-zoo1.csv")
        results = scan_all_runs(d)
        assert len(results) == 2

    def test_ignores_non_matching_files(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "proto-zoo0.res")
        _write_res(d, "random_file.res")  # no server suffix
        results = scan_all_runs(d)
        assert len(results) == 1

    def test_empty_directory(self, tmp_path):
        results = scan_all_runs(str(tmp_path))
        assert results == []

    def test_populates_prefix_and_server(self, tmp_path):
        d = str(tmp_path)
        _write_res(d, "none_raft-30c1s5r5p-zoo-rw_1000000-concurrent_100-0-YCSB_A-zoo0.res")
        results = scan_all_runs(d)
        assert len(results) == 1
        assert results[0]["prefix"] == "none_raft-30c1s5r5p-zoo-rw_1000000-concurrent_100-0-YCSB_A"
        assert results[0]["server"] == "zoo0"


# ---------------------------------------------------------------------------
# TestBuildRaceReport
# ---------------------------------------------------------------------------

class TestBuildRaceReport:
    def test_counts_modes(self):
        analyses = [
            {"race_mode": "none", "prefix": "a", "server": "zoo0", "evidence": ""},
            {"race_mode": "nfs_cache_lag", "prefix": "b", "server": "zoo0",
             "evidence": "test"},
            {"race_mode": "nfs_cache_lag", "prefix": "b", "server": "zoo1",
             "evidence": "test"},
            {"race_mode": "pkill_before_dump", "prefix": "c", "server": "zoo0",
             "evidence": "test"},
        ]
        report = build_race_report(analyses)
        assert report["summary"]["clean_runs"] == 1
        assert report["summary"]["race_affected"] == 3
        assert report["summary"]["by_race_mode"]["nfs_cache_lag"] == 2
        assert report["summary"]["by_race_mode"]["pkill_before_dump"] == 1

    def test_script_analysis_present(self):
        report = build_race_report([])
        assert "script_analysis" in report
        assert "recommended_fixes" in report["script_analysis"]
        assert len(report["script_analysis"]["recommended_fixes"]) >= 3

    def test_affected_details_capped(self):
        # Create 30 entries for one mode — should be capped at 20
        analyses = [
            {"race_mode": "nfs_cache_lag", "prefix": f"p{i}", "server": "zoo0",
             "evidence": "test"}
            for i in range(30)
        ]
        report = build_race_report(analyses)
        assert len(report["affected_details"]["nfs_cache_lag"]) == 20
        assert report["affected_counts_by_mode"]["nfs_cache_lag"] == 30

    def test_empty_analyses(self):
        report = build_race_report([])
        assert report["summary"]["total_server_runs"] == 0
        assert report["summary"]["race_affected"] == 0


# ---------------------------------------------------------------------------
# TestExportReport
# ---------------------------------------------------------------------------

class TestExportReport:
    def test_creates_json(self, tmp_path):
        report = {"summary": {"total": 0}}
        path = str(tmp_path / "test.json")
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
    def test_finds_race_evidence(self):
        analyses = scan_all_runs(ZOO_RESULT_DIR)
        report = build_race_report(analyses)
        assert report["summary"]["race_affected"] > 0

    def test_nfs_cache_lag_is_dominant(self):
        analyses = scan_all_runs(ZOO_RESULT_DIR)
        report = build_race_report(analyses)
        modes = report["summary"]["by_race_mode"]
        nfs = modes.get("nfs_cache_lag", 0)
        pkill = modes.get("pkill_before_dump", 0)
        assert nfs > pkill, "NFS cache lag should be the dominant race mode"

    def test_significant_race_fraction(self):
        analyses = scan_all_runs(ZOO_RESULT_DIR)
        report = build_race_report(analyses)
        s = report["summary"]
        race_pct = s["race_affected"] / s["total_server_runs"] * 100
        assert race_pct > 20, f"Expected >20% race-affected, got {race_pct:.1f}%"

    def test_recommendations_present(self):
        analyses = scan_all_runs(ZOO_RESULT_DIR)
        report = build_race_report(analyses)
        fixes = report["script_analysis"]["recommended_fixes"]
        assert any("sync" in f.lower() for f in fixes)
