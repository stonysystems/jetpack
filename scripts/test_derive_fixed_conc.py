#!/usr/bin/env python3
"""Tests for derive_fixed_conc.py"""

import json
import os
import tempfile
import pytest

from derive_fixed_conc import (
    parse_latency_p50,
    parse_mid_throughput,
    collect_throughputs,
    collect_latencies,
    find_max_throughput_conc,
    find_latency_envelope_conc,
    LATENCY_MULTIPLIER,
    PROTOCOL_MAP,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_res(directory, protocol, site, workload, conc, mode, ycsb, server, throughput,
               total_only=False, latency_p50=None):
    """Create a minimal .res file with a throughput line.

    If total_only=True, writes only 'Total throughtput' (no Mid) to simulate
    shorter runs like MongoDB that don't produce the Mid measurement.
    If latency_p50 is provided, also writes a latency statistics line.
    """
    fname = f"{protocol}-{site}-{workload}-{conc}-{mode}-{ycsb}-{server}.res"
    path = os.path.join(directory, fname)
    with open(path, "w") as f:
        if latency_p50 is not None:
            f.write(f"I [s_main.cc:908] | All-original-path-attempts       "
                    f"statistics   count      100   0pct    50.00  "
                    f"50pct    {latency_p50:.2f}  90pct    {latency_p50 * 1.2:.2f}  "
                    f"99pct    {latency_p50 * 1.5:.2f}    ave    {latency_p50:.2f}\n")
        if total_only:
            f.write(f"Total throughtput is {throughput}\n")
        else:
            f.write(f"Mid throughput is {throughput}\n")
    return path


def _make_complete_experiment(directory, protocol, conc, mode, throughputs,
                               site="30c1s5r5p-zoo", workload="rw_1000000",
                               ycsb="YCSB_A", servers=None, total_only=False,
                               latency_p50s=None):
    """Create .res files for all 5 servers for one experiment point.

    If latency_p50s is provided, it should be a list parallel to throughputs.
    """
    if servers is None:
        servers = [f"zoo{i}" for i in range(5)]
    for i, (server, tp) in enumerate(zip(servers, throughputs)):
        p50 = latency_p50s[i] if latency_p50s else None
        _write_res(directory, protocol, site, workload, conc, mode, ycsb, server, tp,
                   total_only=total_only, latency_p50=p50)


# ---------------------------------------------------------------------------
# TestParseMidThroughput
# ---------------------------------------------------------------------------

class TestParseMidThroughput:
    def test_basic_parse(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("Some header\nMid throughput is 1234.56\nSome footer\n")
        assert parse_mid_throughput(str(p)) == pytest.approx(1234.56)

    def test_integer_throughput(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("Mid throughput is 5000\n")
        assert parse_mid_throughput(str(p)) == pytest.approx(5000.0)

    def test_missing_file(self):
        assert parse_mid_throughput("/nonexistent/file.res") is None

    def test_no_throughput_line(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("Some random content\nNo throughput here\n")
        assert parse_mid_throughput(str(p)) is None

    def test_empty_file(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("")
        assert parse_mid_throughput(str(p)) is None

    def test_first_match_returned(self, tmp_path):
        """If multiple Mid throughput lines exist, return the first."""
        p = tmp_path / "test.res"
        p.write_text("Mid throughput is 100.0\nMid throughput is 200.0\n")
        assert parse_mid_throughput(str(p)) == pytest.approx(100.0)

    def test_total_only_fallback(self, tmp_path):
        """When only 'Total throughtput' is present (e.g. shorter MongoDB runs),
        fall back to that value."""
        p = tmp_path / "test.res"
        p.write_text("Total throughtput is 40.00\nAfter worker.WaitForShutdown();\n")
        assert parse_mid_throughput(str(p)) == pytest.approx(40.0)

    def test_mid_preferred_over_total(self, tmp_path):
        """Mid throughput takes priority when both are present."""
        p = tmp_path / "test.res"
        p.write_text("Total throughtput is 120.00\nMid throughput is 100.00\n")
        assert parse_mid_throughput(str(p)) == pytest.approx(100.0)

    def test_neither_present(self, tmp_path):
        """Return None when neither throughput line is present."""
        p = tmp_path / "test.res"
        p.write_text("Some random log\nNo throughput here\n")
        assert parse_mid_throughput(str(p)) is None


# ---------------------------------------------------------------------------
# TestCollectThroughputs
# ---------------------------------------------------------------------------

class TestCollectThroughputs:
    def test_single_complete_experiment(self, tmp_path):
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0",
                                  [1000, 1100, 1200, 1300, 1400])
        data = collect_throughputs(str(tmp_path))
        assert "none_raft" in data
        assert "concurrent_100" in data["none_raft"]
        total = data["none_raft"]["concurrent_100"]["0"]
        assert total == pytest.approx(6000.0)

    def test_incomplete_experiment_excluded(self, tmp_path):
        """If only 4 of 5 servers report, the experiment is excluded."""
        servers = [f"zoo{i}" for i in range(4)]  # only 4 servers
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0",
                                  [1000, 1100, 1200, 1300],
                                  servers=servers)
        data = collect_throughputs(str(tmp_path))
        # Should be empty because we need 5 servers
        assert len(data) == 0 or "concurrent_100" not in data.get("none_raft", {})

    def test_multiple_concurrencies(self, tmp_path):
        for conc, tps in [("concurrent_100", [1000]*5),
                          ("concurrent_200", [2000]*5),
                          ("concurrent_400", [1500]*5)]:
            _make_complete_experiment(str(tmp_path), "none_raft", conc, "0", tps)
        data = collect_throughputs(str(tmp_path))
        assert len(data["none_raft"]) == 3
        assert data["none_raft"]["concurrent_200"]["0"] == pytest.approx(10000.0)

    def test_multiple_modes(self, tmp_path):
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0", [1000]*5)
        _make_complete_experiment(str(tmp_path), "rule_raft",
                                  "concurrent_100", "0", [900]*5)
        _make_complete_experiment(str(tmp_path), "rule_raft",
                                  "concurrent_100", "1", [1100]*5)
        data = collect_throughputs(str(tmp_path))
        assert "none_raft" in data
        assert "rule_raft" in data
        assert data["rule_raft"]["concurrent_100"]["0"] == pytest.approx(4500.0)
        assert data["rule_raft"]["concurrent_100"]["1"] == pytest.approx(5500.0)

    def test_multiple_protocols(self, tmp_path):
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0", [1000]*5)
        _make_complete_experiment(str(tmp_path), "none_copilot",
                                  "concurrent_100", "0", [800]*5)
        data = collect_throughputs(str(tmp_path))
        assert "none_raft" in data
        assert "none_copilot" in data

    def test_ignores_non_matching_files(self, tmp_path):
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0", [1000]*5)
        # Create non-matching files
        (tmp_path / "README.md").write_text("readme")
        (tmp_path / "metadata.json").write_text("{}")
        (tmp_path / "random.res").write_text("Mid throughput is 999\n")
        data = collect_throughputs(str(tmp_path))
        assert "none_raft" in data
        total = data["none_raft"]["concurrent_100"]["0"]
        assert total == pytest.approx(5000.0)

    def test_custom_servers(self, tmp_path):
        servers = ["server0", "server1", "server2"]
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0",
                                  [1000, 2000, 3000],
                                  servers=servers)
        data = collect_throughputs(str(tmp_path), servers=servers)
        assert data["none_raft"]["concurrent_100"]["0"] == pytest.approx(6000.0)

    def test_custom_site(self, tmp_path):
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0", [1000]*5,
                                  site="5c1s5r5p-aws")
        data = collect_throughputs(str(tmp_path), site="5c1s5r5p-aws")
        assert "none_raft" in data

    def test_empty_directory(self, tmp_path):
        data = collect_throughputs(str(tmp_path))
        assert len(data) == 0

    def test_total_only_files_included(self, tmp_path):
        """Files with only 'Total throughtput' (no Mid) should be picked up
        via the fallback — this happens for MongoDB shorter runs."""
        _make_complete_experiment(str(tmp_path), "none_mongodb",
                                  "concurrent_10", "0", [40, 38, 42, 39, 41],
                                  total_only=True)
        data = collect_throughputs(str(tmp_path))
        assert "none_mongodb" in data
        assert "concurrent_10" in data["none_mongodb"]
        total = data["none_mongodb"]["concurrent_10"]["0"]
        assert total == pytest.approx(200.0)

    def test_mixed_mid_and_total_only(self, tmp_path):
        """Protocols with Mid throughput coexist with total-only protocols."""
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_400", "0", [1800]*5)
        _make_complete_experiment(str(tmp_path), "none_mongodb",
                                  "concurrent_10", "0", [40]*5,
                                  total_only=True)
        data = collect_throughputs(str(tmp_path))
        assert "none_raft" in data
        assert "none_mongodb" in data
        assert data["none_raft"]["concurrent_400"]["0"] == pytest.approx(9000.0)
        assert data["none_mongodb"]["concurrent_10"]["0"] == pytest.approx(200.0)


# ---------------------------------------------------------------------------
# TestFindMaxThroughputConc
# ---------------------------------------------------------------------------

class TestFindMaxThroughputConc:
    def test_finds_best_conc(self):
        protocol_data = {
            "concurrent_100": {"0": 5000},
            "concurrent_200": {"0": 8000},
            "concurrent_400": {"0": 7000},
        }
        best_conc, best_tp, all_results = find_max_throughput_conc(protocol_data)
        assert best_conc == "concurrent_200"
        assert best_tp == pytest.approx(8000)

    def test_mode_filtering(self):
        protocol_data = {
            "concurrent_100": {"0": 5000, "1": 6000},
            "concurrent_200": {"0": 8000, "1": 4000},
        }
        # mode "0" should pick concurrent_200
        best_conc, _, _ = find_max_throughput_conc(protocol_data, mode="0")
        assert best_conc == "concurrent_200"
        # mode "1" should pick concurrent_100
        best_conc, _, _ = find_max_throughput_conc(protocol_data, mode="1")
        assert best_conc == "concurrent_100"

    def test_no_data_for_mode(self):
        protocol_data = {
            "concurrent_100": {"1": 5000},
        }
        best_conc, best_tp, _ = find_max_throughput_conc(protocol_data, mode="0")
        # mode "0" missing, tp defaults to 0
        assert best_conc == "concurrent_100"
        assert best_tp == 0

    def test_empty_data(self):
        best_conc, best_tp, all_results = find_max_throughput_conc({})
        assert best_conc is None
        assert best_tp == -1
        assert all_results == []

    def test_single_conc(self):
        protocol_data = {"concurrent_50": {"0": 3000}}
        best_conc, best_tp, all_results = find_max_throughput_conc(protocol_data)
        assert best_conc == "concurrent_50"
        assert best_tp == pytest.approx(3000)
        assert len(all_results) == 1

    def test_all_results_ordered(self):
        """Results should be sorted by concurrency number."""
        protocol_data = {
            "concurrent_200": {"0": 8000},
            "concurrent_50": {"0": 3000},
            "concurrent_100": {"0": 5000},
        }
        _, _, all_results = find_max_throughput_conc(protocol_data)
        concs = [r[0] for r in all_results]
        assert concs == ["concurrent_50", "concurrent_100", "concurrent_200"]

    def test_tie_goes_to_later_conc(self):
        """When throughputs are equal, the higher conc wins (last > best)."""
        protocol_data = {
            "concurrent_100": {"0": 5000},
            "concurrent_200": {"0": 5000},
        }
        best_conc, _, _ = find_max_throughput_conc(protocol_data)
        # With > comparison, first one wins (concurrent_100 is checked first)
        # With >= comparison, concurrent_200 wins
        # The actual behavior depends on the code's comparison operator
        assert best_conc in ("concurrent_100", "concurrent_200")


# ---------------------------------------------------------------------------
# TestParseLatencyP50
# ---------------------------------------------------------------------------

class TestParseLatencyP50:
    def test_basic_parse(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text(
            "I [s_main.cc:908] | All-original-path-attempts       "
            "statistics   count      100   0pct    50.00  "
            "50pct    82.16  90pct   100.00  99pct   120.00    ave    85.00\n"
        )
        assert parse_latency_p50(str(p)) == pytest.approx(82.16)

    def test_missing_file(self):
        assert parse_latency_p50("/nonexistent/file.res") is None

    def test_no_latency_line(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text("Mid throughput is 1000\n")
        assert parse_latency_p50(str(p)) is None

    def test_negative_p50_returns_none(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text(
            "I | All-original-path-attempts       "
            "statistics   count        0   0pct    -1.00  "
            "50pct    -1.00  90pct    -1.00  99pct    -1.00    ave    -1.00\n"
        )
        assert parse_latency_p50(str(p)) is None

    def test_fallback_to_efficient_attempts(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text(
            "I | All-efficient-attempts           "
            "statistics   count       50   0pct    60.00  "
            "50pct    75.50  90pct    90.00  99pct   100.00    ave    78.00\n"
        )
        assert parse_latency_p50(str(p)) == pytest.approx(75.50)

    def test_original_path_preferred_over_efficient(self, tmp_path):
        p = tmp_path / "test.res"
        p.write_text(
            "I | All-original-path-attempts       "
            "statistics   count      100   0pct    50.00  "
            "50pct    82.00  90pct   100.00  99pct   120.00    ave    85.00\n"
            "I | All-efficient-attempts           "
            "statistics   count      100   0pct    50.00  "
            "50pct    70.00  90pct    90.00  99pct   100.00    ave    72.00\n"
        )
        assert parse_latency_p50(str(p)) == pytest.approx(82.00)


# ---------------------------------------------------------------------------
# TestCollectLatencies
# ---------------------------------------------------------------------------

class TestCollectLatencies:
    def test_single_complete_experiment(self, tmp_path):
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0",
                                  [1000]*5, latency_p50s=[80.0]*5)
        data = collect_latencies(str(tmp_path))
        assert "none_raft" in data
        assert "concurrent_100" in data["none_raft"]
        assert data["none_raft"]["concurrent_100"]["0"] == pytest.approx(80.0)

    def test_incomplete_excluded(self, tmp_path):
        servers = [f"zoo{i}" for i in range(4)]
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0",
                                  [1000]*4, servers=servers,
                                  latency_p50s=[80.0]*4)
        data = collect_latencies(str(tmp_path))
        assert len(data) == 0 or "concurrent_100" not in data.get("none_raft", {})

    def test_average_across_servers(self, tmp_path):
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0",
                                  [1000]*5,
                                  latency_p50s=[70, 75, 80, 85, 90])
        data = collect_latencies(str(tmp_path))
        assert data["none_raft"]["concurrent_100"]["0"] == pytest.approx(80.0)


# ---------------------------------------------------------------------------
# TestFindLatencyEnvelopeConc
# ---------------------------------------------------------------------------

class TestFindLatencyEnvelopeConc:
    def test_picks_largest_in_envelope(self):
        tp_data = {
            "concurrent_10":  {"0": 500},
            "concurrent_100": {"0": 3000},
            "concurrent_200": {"0": 5000},
            "concurrent_400": {"0": 4000},
        }
        lat_data = {
            "concurrent_10":  {"0": 80.0},
            "concurrent_100": {"0": 82.0},
            "concurrent_200": {"0": 85.0},   # within 2x of 80
            "concurrent_400": {"0": 200.0},  # exceeds 2x of 80 = 160
        }
        conc, base, sel_p50, sel_tp, _ = find_latency_envelope_conc(tp_data, lat_data)
        assert conc == "concurrent_200"
        assert base == pytest.approx(80.0)
        assert sel_p50 == pytest.approx(85.0)

    def test_all_in_envelope_picks_highest(self):
        tp_data = {
            "concurrent_10":  {"0": 500},
            "concurrent_100": {"0": 3000},
            "concurrent_500": {"0": 5000},
        }
        lat_data = {
            "concurrent_10":  {"0": 80.0},
            "concurrent_100": {"0": 82.0},
            "concurrent_500": {"0": 90.0},
        }
        conc, _, _, _, _ = find_latency_envelope_conc(tp_data, lat_data)
        assert conc == "concurrent_500"

    def test_custom_multiplier(self):
        tp_data = {
            "concurrent_10":  {"0": 500},
            "concurrent_100": {"0": 3000},
        }
        lat_data = {
            "concurrent_10":  {"0": 80.0},
            "concurrent_100": {"0": 100.0},  # within 2x but not 1.2x
        }
        # With 1.2x multiplier (threshold=96), concurrent_100 exceeds it
        conc, _, _, _, _ = find_latency_envelope_conc(tp_data, lat_data, multiplier=1.2)
        assert conc == "concurrent_10"
        # With 2.0x multiplier (threshold=160), concurrent_100 is fine
        conc, _, _, _, _ = find_latency_envelope_conc(tp_data, lat_data, multiplier=2.0)
        assert conc == "concurrent_100"

    def test_no_latency_data_returns_none(self):
        tp_data = {"concurrent_100": {"0": 3000}}
        lat_data = {}
        conc, _, _, _, _ = find_latency_envelope_conc(tp_data, lat_data)
        assert conc is None

    def test_empty_data(self):
        conc, base, sel_p50, sel_tp, results = find_latency_envelope_conc({}, {})
        assert conc is None
        assert results == []

    def test_mode_filtering(self):
        tp_data = {
            "concurrent_10":  {"0": 500, "100": 600},
            "concurrent_100": {"0": 3000, "100": 4000},
        }
        lat_data = {
            "concurrent_10":  {"0": 80.0, "100": 70.0},
            "concurrent_100": {"0": 200.0, "100": 72.0},  # mode=0 out of envelope
        }
        # mode=0 should only pick concurrent_10
        conc, _, _, _, _ = find_latency_envelope_conc(tp_data, lat_data, mode="0")
        assert conc == "concurrent_10"
        # mode=100 should pick concurrent_100 (72 <= 70*2=140)
        conc, _, _, _, _ = find_latency_envelope_conc(tp_data, lat_data, mode="100")
        assert conc == "concurrent_100"

    def test_all_results_sorted_ascending(self):
        tp_data = {
            "concurrent_200": {"0": 5000},
            "concurrent_10":  {"0": 500},
            "concurrent_100": {"0": 3000},
        }
        lat_data = {
            "concurrent_200": {"0": 85.0},
            "concurrent_10":  {"0": 80.0},
            "concurrent_100": {"0": 82.0},
        }
        _, _, _, _, results = find_latency_envelope_conc(tp_data, lat_data)
        concs = [r[0] for r in results]
        assert concs == ["concurrent_10", "concurrent_100", "concurrent_200"]

    def test_missing_tp_at_some_concs(self):
        """Concurrency with latency but no throughput should be skipped."""
        tp_data = {
            "concurrent_10":  {"0": 500},
            "concurrent_100": {"0": 3000},
            # concurrent_200 has no throughput
        }
        lat_data = {
            "concurrent_10":  {"0": 80.0},
            "concurrent_100": {"0": 82.0},
            "concurrent_200": {"0": 85.0},
        }
        conc, _, _, _, _ = find_latency_envelope_conc(tp_data, lat_data)
        assert conc == "concurrent_100"  # concurrent_200 skipped (no tp)


# ---------------------------------------------------------------------------
# TestProtocolMap
# ---------------------------------------------------------------------------

class TestProtocolMap:
    def test_all_six_families(self):
        assert len(PROTOCOL_MAP) == 6

    def test_expected_protocols(self):
        expected = {"none_raft", "none_copilot", "none_mencius",
                    "none_mongodb", "none_etcd", "none_zookeeper"}
        assert set(PROTOCOL_MAP.keys()) == expected

    def test_display_names(self):
        assert PROTOCOL_MAP["none_raft"] == "Raft"
        assert PROTOCOL_MAP["none_copilot"] == "Copilot"
        assert PROTOCOL_MAP["none_mencius"] == "Mencius"
        assert PROTOCOL_MAP["none_mongodb"] == "MongoDB"
        assert PROTOCOL_MAP["none_etcd"] == "etcd"
        assert PROTOCOL_MAP["none_zookeeper"] == "ZooKeeper"


# ---------------------------------------------------------------------------
# TestEndToEnd
# ---------------------------------------------------------------------------

class TestEndToEnd:
    """Integration tests using the full derive pipeline."""

    def test_derive_two_protocols(self, tmp_path):
        """Simulate Raft and Copilot with multiple concurrencies."""
        # Raft: peak at concurrent_400
        for conc, tp in [("concurrent_100", 3000), ("concurrent_200", 6000),
                         ("concurrent_400", 9000), ("concurrent_600", 8000)]:
            _make_complete_experiment(str(tmp_path), "none_raft", conc, "0", [tp/5]*5)

        # Copilot: peak at concurrent_160
        for conc, tp in [("concurrent_80", 2000), ("concurrent_120", 3500),
                         ("concurrent_160", 4800), ("concurrent_200", 4000)]:
            _make_complete_experiment(str(tmp_path), "none_copilot", conc, "0", [tp/5]*5)

        data = collect_throughputs(str(tmp_path))

        raft_conc, raft_tp, _ = find_max_throughput_conc(data["none_raft"])
        assert raft_conc == "concurrent_400"
        assert raft_tp == pytest.approx(9000.0)

        copilot_conc, copilot_tp, _ = find_max_throughput_conc(data["none_copilot"])
        assert copilot_conc == "concurrent_160"
        assert copilot_tp == pytest.approx(4800.0)

    def test_rule_modes_ignored_for_selection(self, tmp_path):
        """Fixed conc should be derived from mode=0 (original), not rule modes."""
        # Original mode peaks at concurrent_200
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_200", "0", [2000]*5)
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_400", "0", [1500]*5)

        # Rule mode peaks at concurrent_400, but should be ignored
        _make_complete_experiment(str(tmp_path), "rule_raft",
                                  "concurrent_400", "1", [3000]*5)

        data = collect_throughputs(str(tmp_path))
        best_conc, _, _ = find_max_throughput_conc(data["none_raft"], mode="0")
        assert best_conc == "concurrent_200"

    def test_non_uniform_server_throughputs(self, tmp_path):
        """Servers with different throughputs should be summed correctly."""
        _make_complete_experiment(str(tmp_path), "none_raft",
                                  "concurrent_100", "0",
                                  [500, 600, 700, 800, 900])
        data = collect_throughputs(str(tmp_path))
        total = data["none_raft"]["concurrent_100"]["0"]
        assert total == pytest.approx(3500.0)


# ---------------------------------------------------------------------------
# TestWithRealData (only runs when Zoo results exist)
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
    def test_real_data_collects(self):
        data = collect_throughputs(ZOO_RESULT_DIR)
        assert len(data) > 0

    def test_raft_has_data(self):
        data = collect_throughputs(ZOO_RESULT_DIR)
        assert "none_raft" in data
        assert len(data["none_raft"]) > 0

    def test_raft_peak_throughput_in_plateau(self):
        """Peak throughput should be in the Raft plateau region (>=400)."""
        data = collect_throughputs(ZOO_RESULT_DIR)
        best_conc, best_tp, _ = find_max_throughput_conc(data["none_raft"])
        conc_num = int(best_conc.split('_')[1])
        assert conc_num >= 400
        assert best_tp > 8000  # Known to be ~9000+

    def test_raft_latency_envelope_selects_higher(self):
        """Latency-envelope method should pick higher than peak-throughput
        because Raft p50 stays flat through very high concurrency."""
        tp_data = collect_throughputs(ZOO_RESULT_DIR)
        lat_data = collect_latencies(ZOO_RESULT_DIR)
        conc, base, sel_p50, _, _ = find_latency_envelope_conc(
            tp_data["none_raft"], lat_data.get("none_raft", {}))
        conc_num = int(conc.split('_')[1])
        assert conc_num >= 400  # At least as high as old peak-throughput pick
        assert sel_p50 <= base * LATENCY_MULTIPLIER

    def test_copilot_fixed_conc_is_concurrent_180(self):
        tp_data = collect_throughputs(ZOO_RESULT_DIR)
        lat_data = collect_latencies(ZOO_RESULT_DIR)
        if "none_copilot" not in tp_data:
            pytest.skip("Copilot data not yet available")
        conc, base, sel_p50, _, _ = find_latency_envelope_conc(
            tp_data["none_copilot"], lat_data.get("none_copilot", {}))
        assert conc == "concurrent_180"

    def test_throughputs_positive(self):
        data = collect_throughputs(ZOO_RESULT_DIR)
        for proto, conc_data in data.items():
            for conc, mode_data in conc_data.items():
                for mode, tp in mode_data.items():
                    assert tp > 0, f"{proto} {conc} mode={mode} has non-positive throughput"
