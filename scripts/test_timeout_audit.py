#!/usr/bin/env python3
"""Tests for timeout_audit.py"""

import json
import os
import pytest
from datetime import datetime, timedelta

from timeout_audit import (
    extract_wall_time,
    collect_durations,
    classify_timeout_risk,
    build_audit_report,
    export_report,
    DEFAULT_TIMEOUT,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_res(directory, fname, first_ts, last_ts, include_mid_tp=True,
               include_dump=False, extra_lines=None):
    """Write a .res file with controlled timestamps and content."""
    path = os.path.join(directory, fname)
    lines = []
    lines.append(f"I [s_main.cc:432] {first_ts} | PWD : /home/user")
    if extra_lines:
        lines.extend(extra_lines)
    if include_mid_tp:
        lines.append(f"Mid throughput is 1500.0")
        lines.append(f"I | All-efficient-attempts           statistics   count     5000   "
                     f"0pct    10.00  50pct    15.00  90pct    20.00  99pct    30.00    ave    16.00")
    if include_dump:
        lines.append(f"Dumped to /tmp/test.csv with 5000 lines")
    lines.append(f"I [server.cc:100] {last_ts} | server_shutdown")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


def _make_run(directory, protocol, conc, mode, server, duration_s,
              completed=True, dump=False, site="30c1s5r5p-zoo",
              workload="rw_1000000", ycsb="YCSB_A"):
    """Create a .res file for one run with specified duration."""
    t0 = datetime(2026, 3, 23, 10, 0, 0)
    t1 = t0 + timedelta(seconds=duration_s)
    ts0 = t0.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    ts1 = t1.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    fname = (f"{protocol}-{site}-{workload}-concurrent_{conc}-"
             f"{mode}-{ycsb}-{server}.res")
    _write_res(directory, fname, ts0, ts1, include_mid_tp=completed,
               include_dump=dump)
    return fname


# ---------------------------------------------------------------------------
# TestExtractWallTime
# ---------------------------------------------------------------------------

class TestExtractWallTime:
    def test_completed_run(self, tmp_path):
        path = _write_res(str(tmp_path), "test.res",
                          "2026-03-23 10:00:00.000", "2026-03-23 10:01:15.000",
                          include_mid_tp=True)
        result = extract_wall_time(path)
        assert result["completed"] is True
        assert result["wall_time_s"] == pytest.approx(75.0)

    def test_incomplete_run(self, tmp_path):
        path = _write_res(str(tmp_path), "test.res",
                          "2026-03-23 10:00:00.000", "2026-03-23 10:00:05.000",
                          include_mid_tp=False)
        result = extract_wall_time(path)
        assert result["completed"] is False
        assert result["wall_time_s"] == pytest.approx(5.0)

    def test_missing_file(self, tmp_path):
        result = extract_wall_time(str(tmp_path / "nonexistent.res"))
        assert result["wall_time_s"] is None
        assert result["completed"] is False

    def test_empty_file(self, tmp_path):
        path = str(tmp_path / "empty.res")
        with open(path, "w") as f:
            pass
        result = extract_wall_time(path)
        assert result["wall_time_s"] is None

    def test_with_csv_dump(self, tmp_path):
        path = _write_res(str(tmp_path), "test.res",
                          "2026-03-23 10:00:00.000", "2026-03-23 10:01:00.000",
                          include_mid_tp=True, include_dump=True)
        result = extract_wall_time(path)
        assert result["has_csv_dump"] is True
        assert result["completed"] is True

    def test_long_run(self, tmp_path):
        path = _write_res(str(tmp_path), "test.res",
                          "2026-03-23 10:00:00.000", "2026-03-23 10:02:59.000",
                          include_mid_tp=True)
        result = extract_wall_time(path)
        assert result["wall_time_s"] == pytest.approx(179.0)


# ---------------------------------------------------------------------------
# TestCollectDurations
# ---------------------------------------------------------------------------

class TestCollectDurations:
    def test_collects_multiple_runs(self, tmp_path):
        d = str(tmp_path)
        _make_run(d, "none_raft", 100, "0", "zoo0", 70)
        _make_run(d, "none_raft", 100, "0", "zoo1", 72)
        _make_run(d, "none_raft", 200, "0", "zoo0", 74)
        results = collect_durations(d)
        assert len(results) == 3

    def test_extracts_protocol_and_concurrency(self, tmp_path):
        d = str(tmp_path)
        _make_run(d, "rule_mongodb", 40, "100", "zoo0", 80)
        results = collect_durations(d)
        assert len(results) == 1
        assert results[0]["protocol"] == "rule_mongodb"
        assert results[0]["concurrency"] == 40
        assert results[0]["mode"] == "100"

    def test_empty_directory(self, tmp_path):
        results = collect_durations(str(tmp_path))
        assert results == []

    def test_ignores_non_res_files(self, tmp_path):
        d = str(tmp_path)
        _make_run(d, "none_raft", 100, "0", "zoo0", 70)
        # Write a CSV file that shouldn't be collected
        with open(os.path.join(d, "none_raft-30c1s5r5p-zoo-rw_1000000-concurrent_100-0-YCSB_A-zoo0.csv"), "w") as f:
            f.write("ts,latency\n")
        results = collect_durations(d)
        assert len(results) == 1


# ---------------------------------------------------------------------------
# TestClassifyTimeoutRisk
# ---------------------------------------------------------------------------

class TestClassifyTimeoutRisk:
    def test_all_completed_well_under_timeout(self):
        durations = [
            {"wall_time_s": 70, "completed": True, "protocol": "none_raft",
             "concurrency": 100, "file_size": 30000},
            {"wall_time_s": 75, "completed": True, "protocol": "rule_mongodb",
             "concurrency": 40, "file_size": 35000},
        ]
        result = classify_timeout_risk(durations, 180)
        assert result["completed_runs"] == 2
        assert result["incomplete_runs"] == 0
        assert result["genuine_timeouts"] == 0
        assert result["at_risk_runs"] == 0
        assert "SUFFICIENT" in result["recommendation"]

    def test_genuine_timeout_detected(self):
        durations = [
            {"wall_time_s": 175, "completed": False, "protocol": "none_mongodb",
             "concurrency": 400, "file_size": 50000},
        ]
        result = classify_timeout_risk(durations, 180)
        assert result["genuine_timeouts"] == 1
        assert "INCREASE" in result["recommendation"]

    def test_startup_failure_not_counted_as_timeout(self):
        durations = [
            {"wall_time_s": 2, "completed": False, "protocol": "none_zookeeper",
             "concurrency": 400, "file_size": 4000},
        ]
        result = classify_timeout_risk(durations, 180)
        assert result["genuine_timeouts"] == 0
        assert result["startup_failures"] == 1

    def test_at_risk_detection(self):
        durations = [
            {"wall_time_s": 150, "completed": True, "protocol": "rule_mongodb",
             "concurrency": 100, "file_size": 40000},
        ]
        result = classify_timeout_risk(durations, 180)
        assert result["at_risk_runs"] == 1

    def test_per_protocol_max(self):
        durations = [
            {"wall_time_s": 70, "completed": True, "protocol": "none_raft",
             "concurrency": 100, "file_size": 30000},
            {"wall_time_s": 82, "completed": True, "protocol": "rule_mongodb",
             "concurrency": 40, "file_size": 35000},
            {"wall_time_s": 78, "completed": True, "protocol": "rule_mongodb",
             "concurrency": 100, "file_size": 35000},
        ]
        result = classify_timeout_risk(durations, 180)
        assert result["per_protocol_max_wall_time"]["rule_mongodb"] == 82.0
        assert result["per_protocol_max_wall_time"]["none_raft"] == 70.0

    def test_borderline_recommendation(self):
        durations = [
            {"wall_time_s": 160, "completed": True, "protocol": "none_raft",
             "concurrency": 2000, "file_size": 40000},
        ]
        result = classify_timeout_risk(durations, 180)
        assert "BORDERLINE" in result["recommendation"]

    def test_empty_durations(self):
        result = classify_timeout_risk([], 180)
        assert result["total_runs"] == 0
        assert result["completed_runs"] == 0
        assert "SUFFICIENT" in result["recommendation"]


# ---------------------------------------------------------------------------
# TestBuildAuditReport
# ---------------------------------------------------------------------------

class TestBuildAuditReport:
    def test_report_structure(self, tmp_path):
        d = str(tmp_path)
        _make_run(d, "none_raft", 100, "0", "zoo0", 70)
        _make_run(d, "none_raft", 100, "0", "zoo1", 72, completed=False)
        durations = collect_durations(d)
        report = build_audit_report(durations, 180)
        assert "timeout_sec" in report
        assert "classification" in report
        assert "incomplete_run_details" in report

    def test_incomplete_details_populated(self, tmp_path):
        d = str(tmp_path)
        _make_run(d, "none_zookeeper", 400, "0", "zoo0", 3, completed=False)
        durations = collect_durations(d)
        report = build_audit_report(durations, 180)
        assert len(report["incomplete_run_details"]) == 1
        detail = report["incomplete_run_details"][0]
        assert detail["protocol"] == "none_zookeeper"
        assert detail["likely_cause"] == "startup_failure"


# ---------------------------------------------------------------------------
# TestExportReport
# ---------------------------------------------------------------------------

class TestExportReport:
    def test_creates_json(self, tmp_path):
        report = {"timeout_sec": 180, "classification": {}, "incomplete_run_details": []}
        path = str(tmp_path / "timeout_audit.json")
        export_report(report, path)
        assert os.path.isfile(path)
        with open(path) as f:
            loaded = json.load(f)
        assert loaded["timeout_sec"] == 180

    def test_creates_parent_dirs(self, tmp_path):
        path = str(tmp_path / "subdir" / "audit.json")
        report = {"timeout_sec": 180}
        export_report(report, path)
        assert os.path.isfile(path)


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
    def test_collects_durations(self):
        durations = collect_durations(ZOO_RESULT_DIR)
        assert len(durations) > 2000

    def test_no_genuine_timeouts(self):
        durations = collect_durations(ZOO_RESULT_DIR)
        result = classify_timeout_risk(durations, 180)
        assert result["genuine_timeouts"] == 0

    def test_max_wall_time_under_timeout(self):
        durations = collect_durations(ZOO_RESULT_DIR)
        result = classify_timeout_risk(durations, 180)
        assert result["max_completed_wall_time_s"] < 180

    def test_sufficient_recommendation(self):
        durations = collect_durations(ZOO_RESULT_DIR)
        result = classify_timeout_risk(durations, 180)
        assert "SUFFICIENT" in result["recommendation"]

    def test_headroom_above_50_pct(self):
        durations = collect_durations(ZOO_RESULT_DIR)
        result = classify_timeout_risk(durations, 180)
        assert result["headroom_pct"] > 50
