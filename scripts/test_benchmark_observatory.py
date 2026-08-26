#!/usr/bin/env python3

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("benchmark_observatory.py")
SPEC = importlib.util.spec_from_file_location("benchmark_observatory", SCRIPT)
benchmark = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)


class BenchmarkReportTests(unittest.TestCase):
    def test_summary_uses_medians_and_disabled_ratio(self):
        samples = []
        for mode, elapsed, size in (
            ("disabled", 100, 0),
            ("summary", 120, 20),
            ("standard", 140, 30),
            ("full", 200, 50),
            ("full_slow_writer", 240, 60),
        ):
            samples.append(benchmark.Sample(0, 0, mode, elapsed, 10, 10e9 / elapsed, size, 1, 0, 0))
        summary = benchmark.summarize(samples)
        self.assertEqual(summary["disabled"]["median_wall_ns_per_cycle"], 10)
        self.assertEqual(summary["full"]["wall_ratio_to_disabled"], 2)
        self.assertEqual(summary["standard"]["median_capture_bytes_per_cycle"], 3)

    def test_markdown_labels_timing_as_report_only(self):
        samples = [benchmark.Sample(0, 0, mode, 100, 10, 1e8, 0, 0, 0, 0) for mode in benchmark.MODES]
        report = {"summary": benchmark.summarize(samples)}
        rendered = benchmark.markdown_report(report)
        self.assertIn("report-only", rendered)
        self.assertIn("ratio to disabled", rendered)


if __name__ == "__main__":
    unittest.main()
