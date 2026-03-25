#!/usr/bin/env python3
"""Tests for csv_audit.py"""

import json
import os
import pytest

from csv_audit import (
    classify_server,
    scan_prefixes,
    build_audit_report,
    export_report,
    _read_head_tail,
    DEFAULT_SERVERS,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_res(directory, prefix, server, content):
    """Write a .res file with given content."""
    path = os.path.join(directory, f"{prefix}-{server}.res")
    with open(path, "w") as f:
        f.write(content)
    return path


def _write_csv(directory, prefix, server, content="header\n1,2,3\n"):
    """Write a .csv file."""
    path = os.path.join(directory, f"{prefix}-{server}.csv")
    with open(path, "w") as f:
        f.write(content)
    return path


def _make_complete_res(mid_tp=100.0, csv_lines=5000, cpu=15.0):
    """Return .res content for a successful run with all summary lines."""
    return (
        f"I | server median : {cpu}\n"
        f"I | All-efficient-attempts           statistics   count    {csv_lines}"
        f"   0pct    42.00  50pct    43.00  90pct    44.00  99pct    45.00    ave    43.00\n"
        f"I | Mid throughput is {mid_tp}\n"
        f"I | Dumped to results/recent_csv/test-zoo0.csv with {csv_lines} lines data\n"
        f"I | server_shutdown\n"
    )


def _make_crash_res():
    """Return .res content for a crashed server."""
    return (
        "I | starting poll thread\n"
        "F [../src/rrr/rpc/server.cpp:548] cannot bind to: 0.0.0.0:38004\n"
    )


def _make_timeout_res():
    """Return .res content for a server killed early (no statistics/dump)."""
    return (
        "I | starting poll thread\n"
        "I | server_shutdown\n"
    )


def _make_never_dumped_res():
    """Return .res content with statistics but no CSV dump."""
    return (
        "I | All-efficient-attempts           statistics   count    5000"
        "   0pct    42.00  50pct    43.00  90pct    44.00  99pct    45.00    ave    43.00\n"
        "I | Mid throughput is 100.0\n"
        "I | server_shutdown\n"
    )


# ---------------------------------------------------------------------------
# TestReadHeadTail
# ---------------------------------------------------------------------------

class TestReadHeadTail:
    def test_small_file(self, tmp_path):
        p = tmp_path / "small.res"
        p.write_text("line1\nline2\nline3\n")
        head, tail, size = _read_head_tail(str(p))
        assert "line1" in head
        assert "line3" in tail
        assert size == len(p.read_bytes())

    def test_large_file(self, tmp_path):
        p = tmp_path / "large.res"
        # Write 200KB file
        content = "x" * 100_000 + "\nMARKER_HEAD\n" + "y" * 50_000 + "\nMARKER_TAIL\n" + "z" * 50_000
        p.write_text(content)
        head, tail, size = _read_head_tail(str(p), head_bytes=65536, tail_bytes=65536)
        # Head should contain beginning, tail should contain end
        assert size == len(content.encode())
        assert len(head) <= 65536
        assert len(tail) <= 65536


# ---------------------------------------------------------------------------
# TestClassifyServer
# ---------------------------------------------------------------------------

class TestClassifyServer:
    def test_complete_with_csv(self, tmp_path):
        prefix = "test_prefix"
        _write_res(str(tmp_path), prefix, "zoo0", _make_complete_res())
        _write_csv(str(tmp_path), prefix, "zoo0")
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=True)
        assert result["classification"] == "complete"
        assert result["has_csv"] is True
        assert result["has_res"] is True

    def test_missing_res(self, tmp_path):
        result = classify_server(str(tmp_path / "nonexistent.res"), has_csv=False)
        assert result["classification"] == "missing_res"
        assert result["has_res"] is False

    def test_scp_pull_gap(self, tmp_path):
        prefix = "test_prefix"
        _write_res(str(tmp_path), prefix, "zoo0", _make_complete_res())
        # No CSV file written
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "scp_pull_gap"
        assert "Dumped to" in result["evidence"]

    def test_crash_abort(self, tmp_path):
        prefix = "test_prefix"
        _write_res(str(tmp_path), prefix, "zoo0", _make_crash_res())
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "crash_abort"
        assert "cannot bind" in result["evidence"]

    def test_crash_generic_server_error(self, tmp_path):
        prefix = "test_prefix"
        content = "I | starting\nI | generic server error at commit phase\n"
        _write_res(str(tmp_path), prefix, "zoo0", content)
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "crash_abort"

    def test_crash_fatal_log(self, tmp_path):
        prefix = "test_prefix"
        content = "F [file.cc:42] fatal error occurred\n"
        _write_res(str(tmp_path), prefix, "zoo0", content)
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "crash_abort"

    def test_timeout(self, tmp_path):
        prefix = "test_prefix"
        _write_res(str(tmp_path), prefix, "zoo0", _make_timeout_res())
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "timeout"

    def test_timeout_short_file(self, tmp_path):
        prefix = "test_prefix"
        _write_res(str(tmp_path), prefix, "zoo0", "I | started\n")
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "timeout"

    def test_never_dumped(self, tmp_path):
        prefix = "test_prefix"
        _write_res(str(tmp_path), prefix, "zoo0", _make_never_dumped_res())
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "never_dumped"
        assert "statistics but no CSV dump" in result["evidence"]

    def test_zero_throughput(self, tmp_path):
        prefix = "test_prefix"
        content = (
            "I | All-efficient-attempts           statistics   count    0"
            "   0pct    -1.00  50pct    -1.00  90pct    -1.00  99pct    -1.00    ave    -1.00\n"
            "I | Mid throughput is 0.00\n"
            "I | server_shutdown\n"
        )
        _write_res(str(tmp_path), prefix, "zoo0", content)
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "zero_throughput"

    def test_never_dumped_content_no_stats(self, tmp_path):
        """Large file with content but no statistics or dump lines."""
        prefix = "test_prefix"
        # Write enough content to exceed the 5000-byte short-file threshold
        content = "\n".join([f"I | log line {i} with some padding text here" for i in range(300)])
        _write_res(str(tmp_path), prefix, "zoo0", content)
        res_path = str(tmp_path / f"{prefix}-zoo0.res")
        result = classify_server(res_path, has_csv=False)
        assert result["classification"] == "never_dumped"


# ---------------------------------------------------------------------------
# TestScanPrefixes
# ---------------------------------------------------------------------------

class TestScanPrefixes:
    def test_finds_prefixes(self, tmp_path):
        d = str(tmp_path)
        prefix = "none_raft-30c1s5r5p-zoo-rw_1000000-concurrent_100-0-YCSB_A"
        for i in range(5):
            _write_res(d, prefix, f"zoo{i}", _make_complete_res())
            _write_csv(d, prefix, f"zoo{i}")
        results = scan_prefixes(d)
        assert prefix in results
        assert all(results[prefix][f"zoo{i}"]["classification"] == "complete"
                   for i in range(5))

    def test_mixed_complete_and_incomplete(self, tmp_path):
        d = str(tmp_path)
        # Complete prefix
        p1 = "none_raft-complete"
        for i in range(5):
            _write_res(d, p1, f"zoo{i}", _make_complete_res())
            _write_csv(d, p1, f"zoo{i}")
        # Incomplete prefix (missing CSVs)
        p2 = "none_raft-incomplete"
        for i in range(5):
            _write_res(d, p2, f"zoo{i}", _make_complete_res())
        results = scan_prefixes(d)
        assert len(results) == 2
        assert all(results[p1][f"zoo{i}"]["has_csv"] for i in range(5))
        assert not any(results[p2][f"zoo{i}"]["has_csv"] for i in range(5))

    def test_empty_directory(self, tmp_path):
        results = scan_prefixes(str(tmp_path))
        assert results == {}

    def test_ignores_non_matching_files(self, tmp_path):
        d = str(tmp_path)
        # Write a file that doesn't match the pattern
        with open(os.path.join(d, "random_file.txt"), "w") as f:
            f.write("not a result file")
        results = scan_prefixes(d)
        assert results == {}

    def test_partial_servers(self, tmp_path):
        d = str(tmp_path)
        prefix = "none_raft-partial"
        # Only 3 of 5 servers have .res files
        for i in range(3):
            _write_res(d, prefix, f"zoo{i}", _make_complete_res())
            _write_csv(d, prefix, f"zoo{i}")
        results = scan_prefixes(d)
        assert prefix in results
        # zoo3 and zoo4 should be missing_res
        assert results[prefix]["zoo3"]["classification"] == "missing_res"
        assert results[prefix]["zoo4"]["classification"] == "missing_res"


# ---------------------------------------------------------------------------
# TestBuildAuditReport
# ---------------------------------------------------------------------------

class TestBuildAuditReport:
    def _make_scan_results(self, tmp_path):
        d = str(tmp_path)
        # Complete
        p1 = "complete_prefix"
        for i in range(5):
            _write_res(d, p1, f"zoo{i}", _make_complete_res())
            _write_csv(d, p1, f"zoo{i}")
        # scp_pull_gap (all 5 missing CSVs)
        p2 = "scp_gap_prefix"
        for i in range(5):
            _write_res(d, p2, f"zoo{i}", _make_complete_res())
        # crash (1 server crashed, 4 ok)
        p3 = "crash_prefix"
        for i in range(4):
            _write_res(d, p3, f"zoo{i}", _make_complete_res())
            _write_csv(d, p3, f"zoo{i}")
        _write_res(d, p3, "zoo4", _make_crash_res())
        return scan_prefixes(d)

    def test_summary_counts(self, tmp_path):
        scan = self._make_scan_results(tmp_path)
        report = build_audit_report(scan)
        assert report["summary"]["total_prefixes"] == 3
        assert report["summary"]["complete"] == 1
        assert report["summary"]["incomplete"] == 2

    def test_by_cause(self, tmp_path):
        scan = self._make_scan_results(tmp_path)
        report = build_audit_report(scan)
        causes = report["summary"]["by_cause"]
        assert causes.get("scp_pull_gap", 0) == 5
        assert causes.get("crash_abort", 0) == 1

    def test_incomplete_prefix_structure(self, tmp_path):
        scan = self._make_scan_results(tmp_path)
        report = build_audit_report(scan)
        inc = report["incomplete_prefixes"]
        assert len(inc) == 2

        # Check scp_gap_prefix
        scp = [e for e in inc if e["prefix"] == "scp_gap_prefix"][0]
        assert scp["csv_count"] == 0
        assert scp["expected"] == 5
        assert scp["dominant_cause"] == "scp_pull_gap"
        assert len(scp["missing_servers"]) == 5

    def test_dominant_cause(self, tmp_path):
        scan = self._make_scan_results(tmp_path)
        report = build_audit_report(scan)
        inc = report["incomplete_prefixes"]
        crash = [e for e in inc if e["prefix"] == "crash_prefix"][0]
        assert crash["dominant_cause"] == "crash_abort"
        assert crash["csv_count"] == 4

    def test_empty_scan(self):
        report = build_audit_report({})
        assert report["summary"]["total_prefixes"] == 0
        assert report["summary"]["complete"] == 0
        assert report["summary"]["incomplete"] == 0
        assert report["incomplete_prefixes"] == []


# ---------------------------------------------------------------------------
# TestExportReport
# ---------------------------------------------------------------------------

class TestExportReport:
    def test_creates_json(self, tmp_path):
        report = {"summary": {"total": 1}, "incomplete_prefixes": []}
        path = str(tmp_path / "audit.json")
        export_report(report, path)
        assert os.path.isfile(path)
        with open(path) as f:
            loaded = json.load(f)
        assert loaded == report

    def test_creates_parent_dirs(self, tmp_path):
        path = str(tmp_path / "subdir" / "audit.json")
        export_report({"summary": {}}, path)
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
    def test_finds_prefixes(self):
        results = scan_prefixes(ZOO_RESULT_DIR)
        assert len(results) > 100

    def test_has_complete_prefixes(self):
        results = scan_prefixes(ZOO_RESULT_DIR)
        report = build_audit_report(results)
        assert report["summary"]["complete"] > 100

    def test_has_incomplete_prefixes(self):
        results = scan_prefixes(ZOO_RESULT_DIR)
        report = build_audit_report(results)
        assert report["summary"]["incomplete"] > 0

    def test_scp_pull_gap_is_dominant(self):
        """The dominant missing-CSV cause should be scp_pull_gap."""
        results = scan_prefixes(ZOO_RESULT_DIR)
        report = build_audit_report(results)
        causes = report["summary"]["by_cause"]
        if causes:
            dominant = max(causes, key=causes.get)
            assert dominant == "scp_pull_gap"

    def test_known_incomplete_prefixes(self):
        """Verify known incomplete prefixes from TODO.md."""
        results = scan_prefixes(ZOO_RESULT_DIR)
        report = build_audit_report(results)
        prefixes = {e["prefix"] for e in report["incomplete_prefixes"]}
        # These were documented as incomplete in TODO.md
        known = [
            "rule_mencius-30c1s5r5p-zoo-rw_1000000-concurrent_25-101-YCSB_A",
            "none_mongodb-30c1s5r5p-zoo-rw_1000000-concurrent_120-0-YCSB_A",
            "rule_mongodb-30c1s5r5p-zoo-rw_1000000-concurrent_30-100-YCSB_A",
        ]
        for p in known:
            if p in {r for r in results}:
                # Only check if the prefix exists in results
                assert p in prefixes, f"Expected {p} to be incomplete"
