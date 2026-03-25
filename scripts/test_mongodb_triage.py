#!/usr/bin/env python3
"""Tests for mongodb_triage.py"""

import os
import json
import pytest

from mongodb_triage import (
    parse_res_metrics,
    collect_mongodb_data,
    aggregate_servers,
    classify_bottleneck,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_mongodb_res(directory, protocol, conc, mode, server,
                       mid_tp=None, total_tp=None,
                       orig_count=0, orig_p50=-1.0,
                       fp_count=0, fp_p50=-1.0,
                       cpu=10.0,
                       site="30c1s5r5p-zoo", workload="rw_1000000",
                       ycsb="YCSB_A"):
    """Write a MongoDB .res file with specified metrics."""
    fname = f"{protocol}-{site}-{workload}-{conc}-{mode}-{ycsb}-{server}.res"
    path = os.path.join(directory, fname)
    with open(path, "w") as f:
        f.write(f"I | server median : {cpu}\n")
        # Fast path
        if fp_count > 0 and fp_p50 > 0:
            f.write(f"I | All-fast-path-attempts           statistics   "
                    f"count     {fp_count}   0pct    {fp_p50:.2f}  "
                    f"50pct    {fp_p50:.2f}  90pct    {fp_p50*1.02:.2f}  "
                    f"99pct    {fp_p50*1.05:.2f}    ave    {fp_p50:.2f}\n")
        else:
            f.write(f"I | All-fast-path-attempts           statistics   "
                    f"count        0   0pct    -1.00  50pct    -1.00  "
                    f"90pct    -1.00  99pct    -1.00    ave    -1.00\n")
        # Original path
        if orig_count > 0 and orig_p50 > 0:
            f.write(f"I | All-original-path-attempts       statistics   "
                    f"count     {orig_count}   0pct    {orig_p50:.2f}  "
                    f"50pct    {orig_p50:.2f}  90pct    {orig_p50*1.1:.2f}  "
                    f"99pct    {orig_p50*1.2:.2f}    ave    {orig_p50:.2f}\n")
        else:
            f.write(f"I | All-original-path-attempts       statistics   "
                    f"count        0   0pct    -1.00  50pct    -1.00  "
                    f"90pct    -1.00  99pct    -1.00    ave    -1.00\n")
        # Efficient (combines both)
        eff_count = orig_count + fp_count
        eff_p50 = fp_p50 if fp_count > orig_count and fp_p50 > 0 else orig_p50
        if eff_count > 0 and eff_p50 > 0:
            f.write(f"I | All-efficient-attempts           statistics   "
                    f"count     {eff_count}   0pct    {eff_p50:.2f}  "
                    f"50pct    {eff_p50:.2f}  90pct    {eff_p50*1.02:.2f}  "
                    f"99pct    {eff_p50*1.05:.2f}    ave    {eff_p50:.2f}\n")
        else:
            f.write(f"I | All-efficient-attempts           statistics   "
                    f"count        0   0pct    -1.00  50pct    -1.00  "
                    f"90pct    -1.00  99pct    -1.00    ave    -1.00\n")

        if mid_tp is not None:
            f.write(f"Mid throughput is {mid_tp}\n")
        if total_tp is not None:
            f.write(f"Total throughtput is {total_tp}\n")
    return path


def _make_mongodb_experiment(directory, protocol, conc, mode, **kwargs):
    """Create .res files for all 5 servers."""
    for i in range(5):
        _write_mongodb_res(directory, protocol, conc, mode, f"zoo{i}", **kwargs)


# ---------------------------------------------------------------------------
# TestParseResMetrics
# ---------------------------------------------------------------------------

class TestParseResMetrics:
    def test_full_metrics(self, tmp_path):
        p = _write_mongodb_res(str(tmp_path), "none_mongodb",
                               "concurrent_10", "0", "zoo0",
                               mid_tp=56.4, orig_count=564,
                               orig_p50=10350.63, cpu=64.9)
        m = parse_res_metrics(p)
        assert m['mid_throughput'] == pytest.approx(56.4)
        assert m['orig_count'] == 564
        assert m['orig_p50'] == pytest.approx(10350.63)
        assert m['cpu_median'] == pytest.approx(64.9)

    def test_fast_path_metrics(self, tmp_path):
        p = _write_mongodb_res(str(tmp_path), "rule_mongodb",
                               "concurrent_1", "100", "zoo0",
                               mid_tp=4.1, fp_count=41, fp_p50=43.71)
        m = parse_res_metrics(p)
        assert m['fp_count'] == 41
        assert m['fp_p50'] == pytest.approx(43.71)
        assert m.get('orig_count', 0) == 0

    def test_missing_file(self):
        m = parse_res_metrics("/nonexistent.res")
        assert m == {}

    def test_empty_file(self, tmp_path):
        p = tmp_path / "empty.res"
        p.write_text("")
        m = parse_res_metrics(str(p))
        assert m == {}


# ---------------------------------------------------------------------------
# TestCollectMongodbData
# ---------------------------------------------------------------------------

class TestCollectMongodbData:
    def test_collects_mongodb_only(self, tmp_path):
        _make_mongodb_experiment(str(tmp_path), "none_mongodb",
                                 "concurrent_10", "0", mid_tp=56.0,
                                 orig_count=500, orig_p50=10000.0)
        # Also create a raft file (should be ignored)
        _write_mongodb_res(str(tmp_path), "none_raft",
                           "concurrent_10", "0", "zoo0", mid_tp=100.0)
        data = collect_mongodb_data(str(tmp_path))
        assert ("none_mongodb", "concurrent_10", "0") in data
        # none_raft doesn't contain "mongodb" so should be excluded
        assert not any("raft" in k[0] for k in data.keys())

    def test_both_variants(self, tmp_path):
        _make_mongodb_experiment(str(tmp_path), "none_mongodb",
                                 "concurrent_10", "0", mid_tp=56.0,
                                 orig_count=500, orig_p50=10000.0)
        _make_mongodb_experiment(str(tmp_path), "rule_mongodb",
                                 "concurrent_10", "100", mid_tp=56.0,
                                 fp_count=500, fp_p50=43.0)
        data = collect_mongodb_data(str(tmp_path))
        assert ("none_mongodb", "concurrent_10", "0") in data
        assert ("rule_mongodb", "concurrent_10", "100") in data

    def test_empty_dir(self, tmp_path):
        data = collect_mongodb_data(str(tmp_path))
        assert len(data) == 0


# ---------------------------------------------------------------------------
# TestAggregateServers
# ---------------------------------------------------------------------------

class TestAggregateServers:
    def test_basic_aggregation(self, tmp_path):
        _make_mongodb_experiment(str(tmp_path), "none_mongodb",
                                 "concurrent_10", "0", mid_tp=56.0,
                                 orig_count=100, orig_p50=10000.0, cpu=50.0)
        data = collect_mongodb_data(str(tmp_path))
        key = ("none_mongodb", "concurrent_10", "0")
        agg = aggregate_servers(data[key])
        assert agg is not None
        assert agg['total_throughput'] == pytest.approx(280.0)  # 56*5
        assert agg['orig_avg_p50'] == pytest.approx(10000.0)
        assert agg['orig_total_count'] == 500  # 100*5
        assert agg['avg_cpu'] == pytest.approx(50.0)

    def test_incomplete_servers(self):
        # Only 3 servers
        server_data = {f"zoo{i}": {"mid_throughput": 50.0} for i in range(3)}
        agg = aggregate_servers(server_data, n_servers=5)
        assert agg is None


# ---------------------------------------------------------------------------
# TestClassifyBottleneck
# ---------------------------------------------------------------------------

class TestClassifyBottleneck:
    def test_real_protocol_bottleneck(self):
        data = {
            ("none_mongodb", "concurrent_10", "0"): {
                "total_throughput": 280.0,
                "orig_avg_p50": 10000.0,
                "orig_total_count": 2800,
                "fp_avg_p50": None,
                "fp_total_count": 0,
            },
        }
        result = classify_bottleneck(data)
        assert "real_protocol_bottleneck" in result["root_causes"]

    def test_latency_metric_mismatch(self):
        data = {
            ("none_mongodb", "concurrent_10", "0"): {
                "total_throughput": 280.0,
                "orig_avg_p50": 10000.0,
                "orig_total_count": 2800,
                "fp_avg_p50": None,
                "fp_total_count": 0,
            },
            ("rule_mongodb", "concurrent_10", "100"): {
                "total_throughput": 285.0,
                "orig_avg_p50": None,
                "orig_total_count": 0,
                "fp_avg_p50": 43.0,
                "fp_total_count": 2850,
            },
        }
        result = classify_bottleneck(data)
        assert "latency_metric_mismatch" in result["root_causes"]

    def test_throughput_improvement(self):
        data = {
            ("none_mongodb", "concurrent_100", "0"): {
                "total_throughput": 250.0,
                "orig_avg_p50": 13000.0,
                "orig_total_count": 2500,
                "fp_avg_p50": None,
                "fp_total_count": 0,
            },
            ("rule_mongodb", "concurrent_100", "100"): {
                "total_throughput": 2500.0,
                "orig_avg_p50": None,
                "orig_total_count": 0,
                "fp_avg_p50": 42.0,
                "fp_total_count": 25000,
            },
        }
        result = classify_bottleneck(data)
        assert "throughput_improvement" in result["root_causes"]

    def test_all_three_causes(self):
        data = {
            ("none_mongodb", "concurrent_10", "0"): {
                "total_throughput": 280.0,
                "orig_avg_p50": 10000.0,
                "orig_total_count": 2800,
                "fp_avg_p50": None,
                "fp_total_count": 0,
            },
            ("rule_mongodb", "concurrent_10", "100"): {
                "total_throughput": 285.0,
                "orig_avg_p50": None,
                "orig_total_count": 0,
                "fp_avg_p50": 43.0,
                "fp_total_count": 2850,
            },
            ("rule_mongodb", "concurrent_100", "100"): {
                "total_throughput": 2500.0,
                "orig_avg_p50": None,
                "orig_total_count": 0,
                "fp_avg_p50": 42.0,
                "fp_total_count": 25000,
            },
        }
        result = classify_bottleneck(data)
        assert len(result["root_causes"]) == 3
        assert "latency_metric_rule" in result

    def test_empty_data(self):
        result = classify_bottleneck({})
        assert "unknown" in result["root_causes"]


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
    def test_finds_mongodb_data(self):
        data = collect_mongodb_data(ZOO_RESULT_DIR)
        assert len(data) > 10

    def test_real_classification(self):
        data = collect_mongodb_data(ZOO_RESULT_DIR)
        aggregated = {}
        for key, server_data in data.items():
            aggregated[key] = aggregate_servers(server_data)
        valid = {k: v for k, v in aggregated.items() if v is not None}
        result = classify_bottleneck(valid)
        assert "real_protocol_bottleneck" in result["root_causes"]
        assert "latency_metric_mismatch" in result["root_causes"]

    def test_original_latency_is_seconds(self):
        """Original MongoDB p50 should be in seconds (>1000ms)."""
        data = collect_mongodb_data(ZOO_RESULT_DIR)
        key = ("none_mongodb", "concurrent_10", "0")
        if key not in data:
            pytest.skip("concurrent_10 data not available")
        agg = aggregate_servers(data[key])
        assert agg is not None
        assert agg['orig_avg_p50'] > 1000  # At least 1 second

    def test_jetpack_fast_path_is_fast(self):
        """Jetpack 100% fast-path p50 should be < 100ms."""
        data = collect_mongodb_data(ZOO_RESULT_DIR)
        key = ("rule_mongodb", "concurrent_10", "100")
        if key not in data:
            pytest.skip("Jetpack 100% concurrent_10 not available")
        agg = aggregate_servers(data[key])
        if agg is None:
            pytest.skip("Incomplete server data")
        if agg.get('fp_avg_p50') and agg['fp_avg_p50'] > 0:
            assert agg['fp_avg_p50'] < 100
