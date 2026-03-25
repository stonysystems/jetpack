#!/usr/bin/env python3
"""Tests for generate_mongodb_companion_figure.py"""

import csv
import os
import pytest

from generate_mongodb_companion_figure import (
    build_mongodb_plot_data,
    export_csv,
    generate_figure,
    MODE_CONFIGS,
)
from mongodb_triage import collect_mongodb_data, aggregate_servers


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_mongodb_res(directory, protocol, conc, mode, server,
                       mid_tp=None,
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
    return path


def _make_mongodb_experiment(directory, protocol, conc, mode, **kwargs):
    """Create .res files for all 5 servers."""
    for i in range(5):
        _write_mongodb_res(directory, protocol, conc, mode, f"zoo{i}", **kwargs)


def _create_full_mongodb_dataset(tmp_path):
    """Create a realistic MongoDB dataset with all 4 modes at multiple concs."""
    d = str(tmp_path)
    # Original (none_mongodb, mode=0): high latency, low throughput
    for conc, tp, lat in [(10, 56, 10350), (100, 250, 13000), (400, 200, 18000)]:
        _make_mongodb_experiment(d, "none_mongodb", f"concurrent_{conc}", "0",
                                 mid_tp=tp, orig_count=tp*10, orig_p50=lat, cpu=15.0)
    # 0% (rule_mongodb, mode=0): same as original
    for conc, tp, lat in [(10, 55, 10200), (100, 248, 12800)]:
        _make_mongodb_experiment(d, "rule_mongodb", f"concurrent_{conc}", "0",
                                 mid_tp=tp, orig_count=tp*10, orig_p50=lat, cpu=14.0)
    # Adaptive (rule_mongodb, mode=101): mixed path
    for conc, tp, fp_lat in [(10, 58, 45.0), (100, 500, 48.0)]:
        _make_mongodb_experiment(d, "rule_mongodb", f"concurrent_{conc}", "101",
                                 mid_tp=tp, fp_count=tp*8, fp_p50=fp_lat,
                                 orig_count=tp*2, orig_p50=10000.0, cpu=20.0)
    # 100% (rule_mongodb, mode=100): fast path only
    for conc, tp, fp_lat in [(10, 60, 42.0), (100, 2500, 43.0), (400, 2200, 55.0)]:
        _make_mongodb_experiment(d, "rule_mongodb", f"concurrent_{conc}", "100",
                                 mid_tp=tp, fp_count=tp*10, fp_p50=fp_lat, cpu=25.0)
    return d


# ---------------------------------------------------------------------------
# TestBuildMongodbPlotData
# ---------------------------------------------------------------------------

class TestBuildMongodbPlotData:
    def test_returns_all_modes(self, tmp_path):
        d = _create_full_mongodb_dataset(tmp_path)
        raw = collect_mongodb_data(d)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        modes = {r["mode_label"] for r in rows}
        assert "Original" in modes
        assert "100%" in modes

    def test_correct_throughput(self, tmp_path):
        d = _create_full_mongodb_dataset(tmp_path)
        raw = collect_mongodb_data(d)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        # Original concurrent_10: 56*5 = 280
        orig_10 = [r for r in rows if r["mode_label"] == "Original"
                   and r["concurrency"] == 10]
        assert len(orig_10) == 1
        assert orig_10[0]["throughput"] == pytest.approx(280.0)

    def test_eff_p50_uses_efficient_metric(self, tmp_path):
        d = _create_full_mongodb_dataset(tmp_path)
        raw = collect_mongodb_data(d)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        # 100% mode should have eff_p50 near fp_p50 (~42ms)
        jp100_10 = [r for r in rows if r["mode_label"] == "100%"
                    and r["concurrency"] == 10]
        assert len(jp100_10) == 1
        assert jp100_10[0]["eff_p50"] is not None
        assert jp100_10[0]["eff_p50"] < 100  # fast path

    def test_empty_data(self):
        rows = build_mongodb_plot_data({})
        assert rows == []

    def test_concurrency_extracted(self, tmp_path):
        d = _create_full_mongodb_dataset(tmp_path)
        raw = collect_mongodb_data(d)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        concs = {r["concurrency"] for r in rows}
        assert 10 in concs
        assert 100 in concs


# ---------------------------------------------------------------------------
# TestExportCsv
# ---------------------------------------------------------------------------

class TestExportCsv:
    def test_creates_file(self, tmp_path):
        rows = [{"mode_label": "Original", "concurrency": 10,
                 "throughput": 280.0, "eff_p50": 10350.0,
                 "orig_p50": 10350.0, "fp_p50": None, "avg_cpu": 15.0}]
        csv_path = str(tmp_path / "tables" / "mongodb_companion.csv")
        export_csv(rows, csv_path)
        assert os.path.isfile(csv_path)

    def test_correct_header(self, tmp_path):
        rows = [{"mode_label": "Original", "concurrency": 10,
                 "throughput": 280.0, "eff_p50": 10350.0,
                 "orig_p50": 10350.0, "fp_p50": None, "avg_cpu": 15.0}]
        csv_path = str(tmp_path / "tables" / "test.csv")
        export_csv(rows, csv_path)
        with open(csv_path) as f:
            reader = csv.reader(f)
            header = next(reader)
            assert header == ["mode", "concurrency", "throughput_txn_s",
                              "eff_p50_ms", "orig_p50_ms", "fp_p50_ms", "avg_cpu_pct"]

    def test_multiple_rows(self, tmp_path):
        rows = [
            {"mode_label": "Original", "concurrency": 10,
             "throughput": 280.0, "eff_p50": 10350.0,
             "orig_p50": 10350.0, "fp_p50": None, "avg_cpu": 15.0},
            {"mode_label": "100%", "concurrency": 10,
             "throughput": 300.0, "eff_p50": 42.0,
             "orig_p50": None, "fp_p50": 42.0, "avg_cpu": 25.0},
        ]
        csv_path = str(tmp_path / "tables" / "test.csv")
        export_csv(rows, csv_path)
        with open(csv_path) as f:
            reader = csv.reader(f)
            next(reader)  # header
            data = list(reader)
            assert len(data) == 2

    def test_sorted_output(self, tmp_path):
        rows = [
            {"mode_label": "Original", "concurrency": 100,
             "throughput": 1250.0, "eff_p50": 13000.0,
             "orig_p50": 13000.0, "fp_p50": None, "avg_cpu": 15.0},
            {"mode_label": "100%", "concurrency": 10,
             "throughput": 300.0, "eff_p50": 42.0,
             "orig_p50": None, "fp_p50": 42.0, "avg_cpu": 25.0},
        ]
        csv_path = str(tmp_path / "tables" / "test.csv")
        export_csv(rows, csv_path)
        with open(csv_path) as f:
            reader = csv.reader(f)
            next(reader)
            data = list(reader)
            # 100% comes before Original alphabetically
            assert data[0][0] == "100%"
            assert data[1][0] == "Original"


# ---------------------------------------------------------------------------
# TestGenerateFigure
# ---------------------------------------------------------------------------

class TestGenerateFigure:
    def test_creates_pdf(self, tmp_path):
        rows = [
            {"mode_label": "Original", "concurrency": c,
             "throughput": 250 + c * 0.1, "eff_p50": 10000 + c * 10,
             "orig_p50": 10000 + c * 10, "fp_p50": None, "avg_cpu": 15.0}
            for c in [10, 100, 400]
        ] + [
            {"mode_label": "100%", "concurrency": c,
             "throughput": 60 + c * 5, "eff_p50": 42 + c * 0.03,
             "orig_p50": None, "fp_p50": 42 + c * 0.03, "avg_cpu": 25.0}
            for c in [10, 100, 400]
        ]
        pdf_path = str(tmp_path / "figs" / "test_mongodb.pdf")
        generate_figure(rows, pdf_path)
        assert os.path.isfile(pdf_path)
        assert os.path.getsize(pdf_path) > 0

    def test_no_crash_empty_data(self, tmp_path):
        pdf_path = str(tmp_path / "figs" / "empty.pdf")
        generate_figure([], pdf_path)
        assert os.path.isfile(pdf_path)

    def test_single_mode(self, tmp_path):
        rows = [
            {"mode_label": "Original", "concurrency": 10,
             "throughput": 280.0, "eff_p50": 10350.0,
             "orig_p50": 10350.0, "fp_p50": None, "avg_cpu": 15.0}
        ]
        pdf_path = str(tmp_path / "figs" / "single.pdf")
        generate_figure(rows, pdf_path)
        assert os.path.isfile(pdf_path)


# ---------------------------------------------------------------------------
# TestModeConfigs
# ---------------------------------------------------------------------------

class TestModeConfigs:
    def test_four_modes(self):
        assert len(MODE_CONFIGS) == 4

    def test_mode_labels(self):
        labels = [m[0] for m in MODE_CONFIGS]
        assert labels == ["Original", "0%", "Adaptive", "100%"]

    def test_protocols(self):
        protos = {m[1] for m in MODE_CONFIGS}
        assert protos == {"none_mongodb", "rule_mongodb"}


# ---------------------------------------------------------------------------
# TestEndToEnd
# ---------------------------------------------------------------------------

class TestEndToEnd:
    def test_full_pipeline(self, tmp_path):
        d = _create_full_mongodb_dataset(tmp_path)
        raw = collect_mongodb_data(d)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        assert len(rows) > 0

        csv_path = str(tmp_path / "tables" / "mongodb_companion.csv")
        export_csv(rows, csv_path)
        assert os.path.isfile(csv_path)

        pdf_path = str(tmp_path / "figs" / "test.pdf")
        generate_figure(rows, pdf_path)
        assert os.path.isfile(pdf_path)

    def test_original_has_high_latency(self, tmp_path):
        """Original MongoDB eff_p50 should be >1000ms (real 2PC overhead)."""
        d = _create_full_mongodb_dataset(tmp_path)
        raw = collect_mongodb_data(d)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        orig_rows = [r for r in rows if r["mode_label"] == "Original"]
        assert all(r["eff_p50"] > 1000 for r in orig_rows if r.get("eff_p50"))

    def test_jetpack_has_low_latency(self, tmp_path):
        """100% fast-path eff_p50 should be <100ms."""
        d = _create_full_mongodb_dataset(tmp_path)
        raw = collect_mongodb_data(d)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        jp100_rows = [r for r in rows if r["mode_label"] == "100%"]
        assert all(r["eff_p50"] < 100 for r in jp100_rows if r.get("eff_p50"))


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
    def test_builds_plot_data(self):
        raw = collect_mongodb_data(ZOO_RESULT_DIR)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        assert len(rows) > 5

    def test_original_latency_visible(self):
        """Original MongoDB should have high latency that's visible on the companion figure."""
        raw = collect_mongodb_data(ZOO_RESULT_DIR)
        aggregated = {k: aggregate_servers(v) for k, v in raw.items()}
        valid = {k: v for k, v in aggregated.items() if v is not None}
        rows = build_mongodb_plot_data(valid)
        orig_rows = [r for r in rows if r["mode_label"] == "Original"
                     and r.get("eff_p50") and r["eff_p50"] > 0]
        assert len(orig_rows) > 0
        # All original points should be >200ms (the cap that hides them)
        assert all(r["eff_p50"] > 200 for r in orig_rows)
