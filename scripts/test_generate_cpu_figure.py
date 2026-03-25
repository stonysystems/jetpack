#!/usr/bin/env python3
"""Tests for generate_cpu_figure.py"""

import csv
import os
import pytest

from generate_cpu_figure import (
    parse_cpu_median,
    collect_cpu_data,
    build_plot_data,
    export_csv,
    generate_figure,
    PROTOCOL_FAMILIES,
    MODE_CONFIGS,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_res(directory, protocol, conc, mode, server, cpu_median,
               site="30c1s5r5p-zoo", workload="rw_1000000", ycsb="YCSB_A"):
    """Create a minimal .res file with a CPU median line."""
    fname = f"{protocol}-{site}-{workload}-{conc}-{mode}-{ycsb}-{server}.res"
    path = os.path.join(directory, fname)
    with open(path, "w") as f:
        f.write(f"I [s_main.cc:843] | server median : {cpu_median}\n")
        f.write(f"Mid throughput is 100.0\n")
    return path


def _make_experiment(directory, protocol, conc, mode, cpu_values, **kw):
    """Create .res files for all 5 servers."""
    servers = [f"zoo{i}" for i in range(5)]
    for server, cpu in zip(servers, cpu_values):
        _write_res(directory, protocol, conc, mode, server, cpu, **kw)


# ---------------------------------------------------------------------------
# TestParseCpuMedian
# ---------------------------------------------------------------------------

class TestParseCpuMedian:
    def test_basic(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("I [s_main.cc:843] | server median : 42.50\n")
        assert parse_cpu_median(str(p)) == pytest.approx(42.50)

    def test_missing_file(self):
        assert parse_cpu_median("/nonexistent/file.res") is None

    def test_no_cpu_line(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("Mid throughput is 1000\n")
        assert parse_cpu_median(str(p)) is None

    def test_zero_cpu(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("I | server median : 0.00\n")
        assert parse_cpu_median(str(p)) == pytest.approx(0.0)

    def test_high_cpu(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("I | server median : 98.765\n")
        assert parse_cpu_median(str(p)) == pytest.approx(98.765)


# ---------------------------------------------------------------------------
# TestCollectCpuData
# ---------------------------------------------------------------------------

class TestCollectCpuData:
    def test_single_experiment(self, tmp_path):
        _make_experiment(str(tmp_path), "none_raft",
                         "concurrent_100", "0", [20, 22, 21, 23, 24])
        data = collect_cpu_data(str(tmp_path))
        assert "none_raft" in data
        assert data["none_raft"]["concurrent_100"]["0"] == pytest.approx(22.0)

    def test_incomplete_servers_excluded(self, tmp_path):
        """Only 4 of 5 servers — should be excluded."""
        for i in range(4):
            _write_res(str(tmp_path), "none_raft", "concurrent_100", "0",
                       f"zoo{i}", 20.0)
        data = collect_cpu_data(str(tmp_path))
        assert len(data) == 0 or "concurrent_100" not in data.get("none_raft", {})

    def test_multiple_concurrencies(self, tmp_path):
        _make_experiment(str(tmp_path), "none_raft",
                         "concurrent_10", "0", [5]*5)
        _make_experiment(str(tmp_path), "none_raft",
                         "concurrent_100", "0", [20]*5)
        _make_experiment(str(tmp_path), "none_raft",
                         "concurrent_400", "0", [35]*5)
        data = collect_cpu_data(str(tmp_path))
        assert len(data["none_raft"]) == 3
        assert data["none_raft"]["concurrent_10"]["0"] == pytest.approx(5.0)
        assert data["none_raft"]["concurrent_400"]["0"] == pytest.approx(35.0)

    def test_multiple_modes(self, tmp_path):
        _make_experiment(str(tmp_path), "none_raft",
                         "concurrent_100", "0", [20]*5)
        _make_experiment(str(tmp_path), "rule_raft",
                         "concurrent_100", "0", [18]*5)
        _make_experiment(str(tmp_path), "rule_raft",
                         "concurrent_100", "100", [25]*5)
        data = collect_cpu_data(str(tmp_path))
        assert data["none_raft"]["concurrent_100"]["0"] == pytest.approx(20.0)
        assert data["rule_raft"]["concurrent_100"]["0"] == pytest.approx(18.0)
        assert data["rule_raft"]["concurrent_100"]["100"] == pytest.approx(25.0)

    def test_empty_directory(self, tmp_path):
        data = collect_cpu_data(str(tmp_path))
        assert len(data) == 0


# ---------------------------------------------------------------------------
# TestBuildPlotData
# ---------------------------------------------------------------------------

class TestBuildPlotData:
    def test_basic(self, tmp_path):
        _make_experiment(str(tmp_path), "none_raft",
                         "concurrent_100", "0", [20]*5)
        _make_experiment(str(tmp_path), "rule_raft",
                         "concurrent_100", "0", [18]*5)
        _make_experiment(str(tmp_path), "rule_raft",
                         "concurrent_100", "100", [25]*5)
        _make_experiment(str(tmp_path), "rule_raft",
                         "concurrent_100", "101", [22]*5)
        data = collect_cpu_data(str(tmp_path))
        rows = build_plot_data(data)
        assert len(rows) == 4
        raft_rows = [r for r in rows if r["protocol"] == "Raft"]
        assert len(raft_rows) == 4
        modes = {r["mode_label"] for r in raft_rows}
        assert modes == {"Original", "0%", "Adaptive", "100%"}

    def test_concurrency_num_extracted(self, tmp_path):
        _make_experiment(str(tmp_path), "none_raft",
                         "concurrent_200", "0", [30]*5)
        data = collect_cpu_data(str(tmp_path))
        rows = build_plot_data(data)
        assert rows[0]["concurrency"] == 200

    def test_empty_data(self):
        rows = build_plot_data({})
        assert rows == []


# ---------------------------------------------------------------------------
# TestExportCsv
# ---------------------------------------------------------------------------

class TestExportCsv:
    def test_creates_file(self, tmp_path):
        rows = [{"protocol": "Raft", "mode_label": "Original",
                 "concurrency": 100, "avg_cpu": 20.5}]
        csv_path = str(tmp_path / "tables" / "cpu_vs_conc.csv")
        export_csv(rows, csv_path)
        assert os.path.isfile(csv_path)

    def test_correct_content(self, tmp_path):
        rows = [
            {"protocol": "Raft", "mode_label": "Original",
             "concurrency": 100, "avg_cpu": 20.5},
            {"protocol": "Raft", "mode_label": "100%",
             "concurrency": 100, "avg_cpu": 25.0},
        ]
        csv_path = str(tmp_path / "tables" / "cpu_vs_conc.csv")
        export_csv(rows, csv_path)
        with open(csv_path) as f:
            reader = csv.reader(f)
            header = next(reader)
            assert header == ["protocol", "mode", "concurrency", "avg_cpu_pct"]
            data = list(reader)
            assert len(data) == 2

    def test_sorted_output(self, tmp_path):
        rows = [
            {"protocol": "etcd", "mode_label": "Original",
             "concurrency": 200, "avg_cpu": 30.0},
            {"protocol": "Copilot", "mode_label": "Original",
             "concurrency": 100, "avg_cpu": 20.0},
        ]
        csv_path = str(tmp_path / "tables" / "test.csv")
        export_csv(rows, csv_path)
        with open(csv_path) as f:
            reader = csv.reader(f)
            next(reader)  # skip header
            data = list(reader)
            # Copilot comes before etcd alphabetically
            assert data[0][0] == "Copilot"
            assert data[1][0] == "etcd"


# ---------------------------------------------------------------------------
# TestGenerateFigure
# ---------------------------------------------------------------------------

class TestGenerateFigure:
    def test_creates_pdf(self, tmp_path):
        rows = [
            {"protocol": "Raft", "mode_label": "Original",
             "concurrency": c, "avg_cpu": c * 0.03}
            for c in [10, 100, 200, 400]
        ]
        pdf_path = str(tmp_path / "figs" / "test_cpu.pdf")
        generate_figure(rows, pdf_path)
        assert os.path.isfile(pdf_path)
        assert os.path.getsize(pdf_path) > 0

    def test_no_crash_empty_data(self, tmp_path):
        """Should not crash with empty data."""
        pdf_path = str(tmp_path / "figs" / "empty.pdf")
        generate_figure([], pdf_path)
        assert os.path.isfile(pdf_path)


# ---------------------------------------------------------------------------
# TestProtocolConfig
# ---------------------------------------------------------------------------

class TestProtocolConfig:
    def test_six_protocol_families(self):
        assert len(PROTOCOL_FAMILIES) == 6

    def test_four_modes(self):
        assert len(MODE_CONFIGS) == 4

    def test_protocol_names(self):
        names = [p[0] for p in PROTOCOL_FAMILIES]
        assert names == ["Raft", "Copilot", "Mencius", "MongoDB", "etcd", "ZooKeeper"]


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
    def test_collects_data(self):
        data = collect_cpu_data(ZOO_RESULT_DIR)
        assert len(data) > 0

    def test_raft_has_cpu_data(self):
        data = collect_cpu_data(ZOO_RESULT_DIR)
        assert "none_raft" in data
        assert len(data["none_raft"]) > 5  # multiple concurrencies

    def test_cpu_values_reasonable(self):
        data = collect_cpu_data(ZOO_RESULT_DIR)
        for proto, conc_data in data.items():
            for conc, mode_data in conc_data.items():
                for mode, cpu in mode_data.items():
                    assert 0 <= cpu <= 100, \
                        f"{proto} {conc} mode={mode} has cpu={cpu}"

    def test_build_plot_data_nonempty(self):
        data = collect_cpu_data(ZOO_RESULT_DIR)
        rows = build_plot_data(data)
        assert len(rows) > 50  # should have hundreds of data points

    def test_csv_export(self):
        data = collect_cpu_data(ZOO_RESULT_DIR)
        rows = build_plot_data(data)
        csv_path = os.path.join(ZOO_RESULT_DIR, "tables", "cpu_vs_conc.csv")
        if os.path.isfile(csv_path):
            with open(csv_path) as f:
                reader = csv.reader(f)
                header = next(reader)
                assert "protocol" in header
                assert "avg_cpu_pct" in header
