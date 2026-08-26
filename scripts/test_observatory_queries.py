#!/usr/bin/env python3
"""Read-only contract tests for the public Observatory SQL corpus."""

from __future__ import annotations

import importlib.util
import sqlite3
import unittest
from pathlib import Path

HERE = Path(__file__).parent
QUERY_DIR = HERE / "observatory_queries"
SPEC = importlib.util.spec_from_file_location("analyzer_tests", HERE / "test_analyze_observatory.py")
assert SPEC and SPEC.loader
fixture_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_module)


def query(name: str) -> str:
    return (QUERY_DIR / name).read_text()


def readonly(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    return db


class QueryCorpusTests(unittest.TestCase):
    def fixture(self):
        temporary, path = fixture_module.AnalyzerTests().fixture()
        self.addCleanup(temporary.cleanup)
        return path

    def test_every_public_query_is_standalone_read_only_and_self_documenting(self):
        path = self.fixture()
        before = path.read_bytes()
        db = readonly(path)
        self.addCleanup(db.close)
        db.execute("ATTACH DATABASE ? AS after", (str(path),))
        files = sorted(QUERY_DIR.glob("*.sql"))
        self.assertGreaterEqual(len(files), 1)
        for item in files:
            with self.subTest(query=item.name):
                self.assertFalse(item.name[0].isdigit(), item.name)
                self.assertTrue(item.read_text().lstrip().startswith("--"), item.name)
                cursor = db.execute(item.read_text())
                columns = tuple(column[0] for column in cursor.description)
                self.assertEqual(("evidence_status", "evidence_reason"), columns[:2])
                self.assertTrue(cursor.fetchall(), f"{item.name} returned no status row")
        self.assertEqual(before, path.read_bytes())

    def test_partial_measurement_returns_status_and_null_metrics(self):
        path = self.fixture()
        writable = sqlite3.connect(path)
        writable.execute(
            "UPDATE measurement_status SET status='partial',reason='injected omission',omitted_events=1 "
            "WHERE name='task_lifecycle'"
        )
        writable.commit()
        writable.close()
        db = readonly(path)
        self.addCleanup(db.close)
        row = db.execute(query("tasks.sql")).fetchone()
        self.assertEqual("partial", row["evidence_status"])
        self.assertEqual("injected omission", row["evidence_reason"])
        self.assertIsNone(row["subject_id"])
        self.assertIsNone(row["active_ns"])

    def test_task_turns_include_resumed_work_and_exclude_parked_time(self):
        path = self.fixture()
        db = readonly(path)
        self.addCleanup(db.close)
        row = db.execute(query("tasks.sql")).fetchone()
        self.assertEqual(700_000, row["active_ns"])
        self.assertEqual(500_000, row["longest_turn_ns"])
        self.assertEqual(1_000_000, row["parked_ns"])

    def test_rendering_keeps_cycle_aggregate_and_full_detail_separate(self):
        path = self.fixture()
        writable = sqlite3.connect(path)
        writable.execute(
            "INSERT INTO draw_summaries VALUES(2,1,1,0,0,0,100,1,0,'Draw.circle!')"
        )
        writable.commit()
        writable.close()
        db = readonly(path)
        self.addCleanup(db.close)
        rows = db.execute(query("rendering.sql")).fetchall()
        aggregate = next(row for row in rows if row["record_type"] == "cycle aggregate")
        detail = next(row for row in rows if row["record_type"] == "operation detail")
        self.assertEqual(12, aggregate["accepted_calls"])
        self.assertEqual(300_000, aggregate["host_duration_ns"])
        self.assertEqual(1, detail["accepted_calls"])
        self.assertEqual(100, detail["host_duration_ns"])

    def test_headless_capture_never_claims_presentation_evidence(self):
        path = self.fixture()
        writable = sqlite3.connect(path)
        writable.execute("UPDATE metadata SET value='native-headless' WHERE key='target_profile'")
        writable.execute("UPDATE metadata SET value='headless_stub' WHERE key='backend'")
        writable.execute("UPDATE gpu_facts SET name='headless_stub' WHERE kind=0")
        writable.execute("DELETE FROM gpu_facts WHERE kind=1")
        writable.execute("DELETE FROM structural_latency WHERE name LIKE 'input_to_present%'")
        writable.commit()
        writable.close()
        db = readonly(path)
        self.addCleanup(db.close)
        cycle = db.execute(query("cycles.sql")).fetchone()
        self.assertIsNone(cycle["presentation_budget_ns"])
        latency = {row["name"]: row for row in db.execute(query("latency.sql")).fetchall()}
        self.assertEqual("unavailable", latency["input_to_presentation"]["evidence_status"])
        self.assertIsNone(latency["input_to_presentation"]["observations"])

    def test_allocation_lifetimes_resolve_trace_zone_names(self):
        path = self.fixture()
        db = readonly(path)
        self.addCleanup(db.close)
        rows = db.execute(query("allocation_lifetimes.sql")).fetchall()
        named = next(row for row in rows if row["zone_id"] == 9)
        outside = next(row for row in rows if row["zone_id"] == 0)
        self.assertEqual("load", named["zone_name"])
        self.assertEqual("(outside a Trace zone)", outside["zone_name"])

    def test_compare_refuses_unclean_or_different_application(self):
        before = self.fixture()
        after_temp, after = fixture_module.AnalyzerTests().fixture()
        self.addCleanup(after_temp.cleanup)
        writable = sqlite3.connect(after)
        writable.execute("UPDATE metadata SET value='0' WHERE key='clean_shutdown'")
        writable.commit()
        writable.close()
        db = readonly(before)
        db.execute("ATTACH DATABASE ? AS after", (str(after),))
        row = db.execute(query("compare.sql")).fetchone()
        self.assertEqual("incomparable", row["evidence_status"])
        self.assertIsNone(row["median_delta_ns"])
        db.close()

        writable = sqlite3.connect(after)
        writable.execute("UPDATE metadata SET value='1' WHERE key='clean_shutdown'")
        writable.execute("UPDATE metadata SET value='different-app' WHERE key='app_name'")
        writable.commit()
        writable.close()
        db = readonly(before)
        self.addCleanup(db.close)
        db.execute("ATTACH DATABASE ? AS after", (str(after),))
        row = db.execute(query("compare.sql")).fetchone()
        self.assertEqual("incomparable", row["evidence_status"])
        self.assertEqual("application basename differs", row["evidence_reason"])


if __name__ == "__main__":
    unittest.main()
