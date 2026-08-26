#!/usr/bin/env python3
"""Tests for the read-only Observatory analyzer."""

import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("analyze_observatory.py")
SPEC = importlib.util.spec_from_file_location("analyze_observatory", SCRIPT)
assert SPEC and SPEC.loader
analyzer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyzer)


class AnalyzerTests(unittest.TestCase):
    def fixture(self, clean="1", final="complete"):
        temporary = tempfile.TemporaryDirectory()
        path = Path(temporary.name) / "fixture.rrstats"
        db = sqlite3.connect(path)
        db.executescript("""
          CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          CREATE TABLE measurement_status(name TEXT PRIMARY KEY,family INTEGER,required_detail TEXT,status TEXT,reason TEXT,rows_recorded INTEGER,omitted_events INTEGER);
          CREATE TABLE cycles(cycle INTEGER,start_ns INTEGER,duration_ns INTEGER,update_ns INTEGER,render_callback_ns INTEGER,task_executor_ns INTEGER,host_other_ns INTEGER,alloc_bytes INTEGER,alloc_calls INTEGER,free_bytes INTEGER DEFAULT 0,free_calls INTEGER DEFAULT 0,live_bytes INTEGER DEFAULT 0,peak_live_bytes INTEGER DEFAULT 0,update_alloc_bytes INTEGER DEFAULT 0,update_alloc_calls INTEGER DEFAULT 0,task_events INTEGER DEFAULT 0,effect_calls INTEGER DEFAULT 0,draw_calls INTEGER DEFAULT 0,resource_events INTEGER DEFAULT 0,queue_events INTEGER DEFAULT 0);
          CREATE TABLE annotations(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,phase INTEGER,kind INTEGER,name TEXT,integer_value INTEGER,real_value REAL,unit INTEGER,wall_ns INTEGER,active_ns INTEGER,parked_ns INTEGER);
          CREATE TABLE hosted_effects(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,parent_id INTEGER,duration_ns INTEGER,value_a INTEGER,value_b INTEGER,name TEXT,outbound_copied_bytes INTEGER,ownership_transfer_bytes INTEGER,validation_ns INTEGER,conversion_ns INTEGER,worker_ns INTEGER,external_ns INTEGER);
          CREATE TABLE task_events(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,parent_id INTEGER,duration_ns INTEGER,value_a INTEGER,value_b INTEGER,name TEXT);
          CREATE TABLE queue_pressure(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,parent_id INTEGER,duration_ns INTEGER,value_a INTEGER,value_b INTEGER,name TEXT);
          CREATE TABLE resource_lifecycle(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,parent_id INTEGER,duration_ns INTEGER,value_a INTEGER,value_b INTEGER,name TEXT);
          CREATE TABLE structural_latency(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,parent_id INTEGER,duration_ns INTEGER,value_a INTEGER,value_b INTEGER,name TEXT);
          CREATE TABLE draw_summaries(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,parent_id INTEGER,duration_ns INTEGER,value_a INTEGER,value_b INTEGER,name TEXT);
          CREATE TABLE allocation_events(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,phase INTEGER,task_id INTEGER,zone_id INTEGER,bytes INTEGER,prior_bytes INTEGER,copied_bytes INTEGER);
          CREATE TABLE gpu_facts(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,kind INTEGER,subject_id INTEGER,parent_id INTEGER,duration_ns INTEGER,value_a INTEGER,value_b INTEGER,name TEXT);
          CREATE TABLE recorder_health(id INTEGER,transactions INTEGER,checkpoints INTEGER,queue_high_water INTEGER,output_bytes INTEGER,omitted_events INTEGER,rows_written INTEGER,writer_failed INTEGER,output_limited INTEGER,writer_active_wall_ns INTEGER,writer_idle_wall_ns INTEGER,writer_cpu_ns INTEGER);
          CREATE TABLE recording_gaps(id INTEGER,cycle INTEGER,timestamp_ns INTEGER,family INTEGER,lost_count INTEGER,first_cycle INTEGER,last_cycle INTEGER,started_ns INTEGER,ended_ns INTEGER,producer_track TEXT);
          INSERT INTO cycles(cycle,start_ns,duration_ns,update_ns,render_callback_ns,task_executor_ns,host_other_ns,alloc_bytes,alloc_calls) VALUES(0,0,1000000,400000,300000,100000,200000,0,0),(1,0,3000000,1000000,500000,200000,1300000,128,2),(2,0,2000000,500000,500000,100000,900000,0,0);
          INSERT INTO annotations VALUES(1,1,0,1,2,'load',9,NULL,0,2000000,1500000,500000);
          INSERT INTO annotations VALUES(2,1,500000,1,0,'loaded',NULL,NULL,0,0,0,0);
          INSERT INTO hosted_effects VALUES(1,1,0,1,0,0,750000,0,0,'File.read',0,0,NULL,NULL,200000,500000);
          INSERT INTO hosted_effects VALUES(2,1,0,1,0,0,1750000,128,0,'File.read',64,0,NULL,NULL,NULL,NULL);
          INSERT INTO task_events VALUES(1,0,100000,2,7,0,0,0,0,''),(2,0,300000,3,7,0,0,0,0,'sleep'),(3,0,1300000,4,7,0,0,0,0,'sleep'),(4,0,1800000,5,7,0,0,0,0,''),(5,1,2300000,6,7,0,0,0,0,'');
          INSERT INTO queue_pressure VALUES(1,0,0,2,0,0,4000000,8,8,'cmd children');
          INSERT INTO resource_lifecycle VALUES(1,0,0,3,9,0,6000000,0,0,'texture'),(2,1,0,0,10,0,0,0,0,'font');
          INSERT INTO structural_latency VALUES(1,0,0,1,1,0,5000000,0,0,'input_to_presentation'),(2,1,0,1,2,0,7000000,0,0,'input_to_presentation');
          INSERT INTO allocation_events VALUES(1,0,100000,0,11,2,0,0,64,0,0),(2,0,200000,2,11,2,0,0,128,64,64),(3,1,2100000,1,11,2,0,0,128,128,0),(4,2,2200000,0,12,4,7,9,32,0,0);
          INSERT INTO gpu_facts VALUES(1,0,0,0,0,0,0,0,0,'raylib_native'),(2,0,0,2,0,0,0,0,500,'host_fps_cap'),(3,0,0,4,0,0,400000,0,0,'render_callback'),(4,0,0,5,0,0,100000,0,0,'begin_drawing'),(5,0,0,6,0,0,200000,0,0,'host_draw_submission'),(6,0,0,7,0,0,800000,0,0,'end_drawing_including_presentation_and_pacing'),(7,1,0,1,0,0,0,1,0,'presentation_completed');
          INSERT INTO draw_summaries VALUES(1,1,0,1,0,0,300000,12,2,'public_draw_effects');
          INSERT INTO recorder_health VALUES(1,2,1,4,4096,0,8,0,0,1500000,2500000,NULL);
        """)
        measurements = (
            ("cycle_summary", 0, "summary"), ("allocation_counters", 0, "summary"),
            ("annotations", 1, "summary"), ("hosted_effects", 2, "standard"),
            ("task_lifecycle", 3, "standard"), ("allocation_lifecycle", 4, "full"),
            ("resource_lifecycle", 5, "standard"), ("queue_pressure", 6, "standard"),
            ("draw_observations", 7, "summary"), ("structural_latency", 8, "standard"),
            ("backend_facts", 9, "summary"), ("callback_summaries", 10, "summary"),
        )
        db.executemany(
            "INSERT INTO measurement_status VALUES(?,?,?,'complete','complete evidence; zero rows means measured zero',1,0)",
            measurements,
        )
        db.executemany("INSERT INTO metadata VALUES(?,?)", (
            ("schema_version", str(analyzer.SUPPORTED_SCHEMA)), ("clean_shutdown", clean),
            ("final_state", final), ("requested_detail", "full"), ("effective_detail", "full"),
            ("host_os", "linux"), ("host_arch", "x86_64"),
            ("target_profile", "native-graphical"), ("backend", "raylib_native"),
            ("app_name", "fixture-app"), ("chunk_count", "256"),
            ("summary_reserve", "8"), ("transaction_chunks", "32"),
            ("max_output_bytes", "16777216"), ("benchmark_writer_delay_ms", "0"),
            ("unavailable_sources", "gpu_timing,writer_thread_cpu_time"),
        ))
        db.commit()
        db.close()
        return temporary, path

    def test_report_has_percentiles_and_available_families(self):
        temporary, path = self.fixture()
        self.addCleanup(temporary.cleanup)
        before = path.read_bytes()
        report = analyzer.analyze(path, 2)
        self.assertIn("median=2.000ms p95=2.900ms p99=2.980ms", report)
        self.assertIn("Slowest cycles (top 2):", report)
        self.assertIn("Zones: 1 completed zone(s)", report)
        self.assertIn("Recorder health:", report)
        self.assertIn("writer_active_wall=1.500ms", report)
        self.assertIn("writer_cpu=unavailable", report)
        self.assertIn("Unavailable sources: gpu_timing,writer_thread_cpu_time", report)
        self.assertIn("Presentation budget: 1 cycle(s) over 2.000ms", report)
        self.assertIn("render_callback: count=1 total=0.400ms", report)
        self.assertIn("end_drawing_including_presentation_and_pacing: count=1 total=0.800ms", report)
        self.assertIn("File.read: count=2 copied=128B p95=1.700ms max=1.750ms", report)
        self.assertIn("Marks around slow cycles: cycle=1 loaded@0.500ms", report)
        self.assertIn("Worker/external intervals: count=1 worker_total=0.200ms external_total=0.500ms", report)
        self.assertIn("Allocation lifetimes: completed=1 median=2.000ms realloc_moves=1", report)
        self.assertIn("Allocation-heavy cycles: cycle=0 events=2 allocated_or_resized=192B", report)
        self.assertIn("Task intervals: active_median=0.350ms parked_median=1.000ms delivery_median=0.500ms", report)
        self.assertIn("Longest task turn: 0.500ms", report)
        self.assertIn("Queue pressure: saturations=1 oldest_age_max=4.000ms", report)
        self.assertIn("Resource destruction: count=1 delay_max=6.000ms", report)
        self.assertIn("Resources retained at shutdown: 1", report)
        self.assertIn("Input-to-presentation: count=2 median=6.000ms p95=6.900ms", report)
        self.assertIn("Rendering pressure: events=1 primary_count=12 secondary_count=2 total=0.300ms", report)
        self.assertEqual(before, path.read_bytes())

    def test_rejects_unclean_capture(self):
        temporary, path = self.fixture(clean="0", final="failed")
        self.addCleanup(temporary.cleanup)
        with self.assertRaisesRegex(analyzer.CaptureError, "clean shutdown"):
            analyzer.analyze(path)

    def test_rejects_unknown_schema(self):
        temporary, path = self.fixture()
        self.addCleanup(temporary.cleanup)
        db = sqlite3.connect(path)
        db.execute("UPDATE metadata SET value='99' WHERE key='schema_version'")
        db.commit()
        db.close()
        with self.assertRaisesRegex(analyzer.CaptureError, "unsupported schema"):
            analyzer.analyze(path)

    def test_compares_two_captures(self):
        first_temp, first = self.fixture()
        second_temp, second = self.fixture()
        self.addCleanup(first_temp.cleanup)
        self.addCleanup(second_temp.cleanup)
        db = sqlite3.connect(second)
        db.execute("UPDATE cycles SET duration_ns=duration_ns+1000000")
        db.commit()
        db.close()
        report = analyzer.compare(first, second)
        self.assertIn("median=2.000->3.000ms delta=+1.000ms", report)
        self.assertIn("p95=2.900->3.900ms delta=+1.000ms", report)

    def test_refuses_cross_environment_comparison(self):
        first_temp, first = self.fixture()
        second_temp, second = self.fixture()
        self.addCleanup(first_temp.cleanup)
        self.addCleanup(second_temp.cleanup)
        db = sqlite3.connect(second)
        db.execute("UPDATE metadata SET value='headless_stub' WHERE key='backend'")
        db.commit()
        db.close()
        with self.assertRaisesRegex(analyzer.CaptureError, "different target/backend/host"):
            analyzer.compare(first, second)

    def test_reports_end_drawing_as_upper_bound_not_presentation(self):
        temporary, path = self.fixture()
        self.addCleanup(temporary.cleanup)
        db = sqlite3.connect(path)
        db.execute("UPDATE structural_latency SET name='input_to_end_drawing_including_pacing'")
        db.commit()
        db.close()
        report = analyzer.analyze(path)
        self.assertIn("Input-to-presentation: unavailable", report)
        self.assertIn("upper_bound_p95=6.900ms", report)

    def test_uncaptured_summary_detail_is_never_reported_as_zero(self):
        temporary, path = self.fixture()
        self.addCleanup(temporary.cleanup)
        db = sqlite3.connect(path)
        db.execute("UPDATE metadata SET value='summary' WHERE key='effective_detail'")
        for measurement in ("hosted_effects", "task_lifecycle", "allocation_lifecycle", "resource_lifecycle", "queue_pressure", "structural_latency"):
            db.execute("UPDATE measurement_status SET status='not_recorded',reason='selected detail level does not record this measurement',rows_recorded=0 WHERE name=?", (measurement,))
        db.commit()
        db.close()
        report = analyzer.analyze(path)
        self.assertIn("Allocation lifetimes: unavailable (evidence=not_recorded", report)
        self.assertIn("Task intervals: unavailable (evidence=not_recorded", report)
        self.assertIn("Queue pressure: unavailable (evidence=not_recorded", report)
        self.assertNotIn("Resources retained at shutdown: 0", report)

    def test_refuses_partial_cycle_distribution(self):
        temporary, path = self.fixture()
        self.addCleanup(temporary.cleanup)
        db = sqlite3.connect(path)
        db.execute("UPDATE measurement_status SET status='partial',reason='recorder omitted events',omitted_events=1 WHERE name='cycle_summary'")
        db.commit()
        db.close()
        with self.assertRaisesRegex(analyzer.CaptureError, "cycle summary evidence is partial"):
            analyzer.analyze(path)


if __name__ == "__main__":
    unittest.main()
