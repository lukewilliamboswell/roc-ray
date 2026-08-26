#!/usr/bin/env python3
"""Execute every public Observatory SQL investigation against a v11 fixture."""

from __future__ import annotations

import importlib.util
import sqlite3
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("analyzer_tests", HERE / "test_analyze_observatory.py")
assert SPEC and SPEC.loader
fixture_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_module)

EXPECTED_COLUMNS = {
    "01_recording_trust.sql": ("schema_version", "clean_shutdown", "final_state", "omitted_events", "writer_failed"),
    "02_slowest_cycles.sql": ("cycle", "duration_ns", "update_ns", "render_ns", "task_pump_ns"),
    "03_presentation_budget_misses.sql": ("available", "missed_cycles"),
    "04_cycle_percentiles.sql": ("median_ns", "p95_ns", "p99_ns"),
    "05_missed_frame_dominance.sql": ("cycle", "duration_ns", "dominant_component"),
    "06_expensive_zones.sql": ("name", "phase", "zone_count", "wall_ns", "active_ns", "parked_ns", "max_wall_ns"),
    "07_marks_around_slow_cycles.sql": ("cycle", "timestamp_ns", "name"),
    "08_effect_tail_latency.sql": ("name", "calls", "mean_ns", "max_ns", "non_success"),
    "09_boundary_copy_hotspots.sql": ("name", "calls", "inbound_copied_bytes", "outbound_copied_bytes", "ownership_transfer_bytes"),
    "10_allocation_heavy_cycles.sql": ("cycle", "alloc_calls", "alloc_bytes", "free_calls", "free_bytes", "live_bytes", "peak_live_bytes"),
    "11_live_allocations.sql": ("subject_id", "bytes", "phase", "task_id", "zone_id"),
    "12_reallocation_moves.sql": ("subject_id", "cycle", "timestamp_ns", "prior_bytes", "bytes", "copied_bytes", "phase", "task_id", "zone_id"),
    "13_long_task_turns.sql": ("subject_id", "started_ns", "active_ns"),
    "14_task_latency_decomposition.sql": ("subject_id", "spawned_ns", "started_ns", "finished_ns", "delivered_ns"),
    "15_worker_vs_external.sql": ("name", "calls", "worker_ns", "external_ns", "unavailable_worker", "unavailable_external"),
    "16_queue_saturation.sql": ("name", "saturation_events", "high_water", "capacity", "oldest_age_ns"),
    "17_resource_destruction_delay.sql": ("subject_id", "name", "destruction_delay_ns", "heap_high_water"),
    "18_input_to_presentation.sql": ("subject_id", "parent_id", "cycle", "duration_ns"),
    "19_rendering_pressure.sql": ("cycle", "submitted_items", "secondary_count", "host_duration_ns"),
    "20_recorder_health_and_compare.sql": ("transactions", "checkpoints", "queue_high_water", "output_bytes", "omitted_events", "writer_failed", "output_limited", "writer_cpu_ns"),
    "21_compare_captures.sql": ("mean_cycle_delta_ns", "allocation_delta_bytes"),
}


class QueryCorpusTests(unittest.TestCase):
    def test_every_public_query_runs_read_only_with_locked_columns(self):
        temporary, path = fixture_module.AnalyzerTests().fixture()
        self.addCleanup(temporary.cleanup)
        before = path.read_bytes()
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self.addCleanup(db.close)
        db.execute("PRAGMA query_only=ON")
        db.execute("ATTACH DATABASE ? AS before", (str(path),))
        db.execute("ATTACH DATABASE ? AS after", (str(path),))
        query_dir = HERE / "observatory_queries"
        files = sorted(query_dir.glob("*.sql"))
        self.assertEqual(set(EXPECTED_COLUMNS), {item.name for item in files})
        for item in files:
            with self.subTest(query=item.name):
                cursor = db.execute(item.read_text(), {"limit": 3, "budget_ns": 1_500_000})
                self.assertEqual(EXPECTED_COLUMNS[item.name], tuple(column[0] for column in cursor.description))
                self.assertTrue(cursor.fetchall(), f"{item.name} returned no rows for its recognizable fixture pattern")
        self.assertEqual(before, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
