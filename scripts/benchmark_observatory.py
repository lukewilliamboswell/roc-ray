#!/usr/bin/env python3
"""Report RocRay Observatory overhead without universal timing thresholds."""

from __future__ import annotations

import argparse
import json
import os
import platform
import random
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local_bundles  # noqa: E402

MODES = ("disabled", "summary", "standard", "full", "full_slow_writer")
SLOW_WRITER_DELAY_MS = "25"


@dataclass(frozen=True)
class Sample:
    repetition: int
    order: int
    mode: str
    elapsed_ns: int
    frames: int
    cycles_per_second: float
    capture_bytes: int
    rows_written: int
    omitted_events: int
    drain_duration_ns: int


def executable_for(entry: Path) -> Path:
    return entry.with_name(entry.stem + (".exe" if os.name == "nt" else ""))


def capture_facts(
    path: Path, expected_frames: int, expected_detail: str, slow_writer: bool
) -> tuple[int, int, int]:
    with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
        metadata = dict(db.execute("SELECT key,value FROM metadata"))
        if metadata.get("clean_shutdown") != "1" or metadata.get("final_state") != "complete":
            raise RuntimeError(f"capture did not finalize cleanly: {metadata.get('final_state')!r}")
        if metadata.get("requested_detail") != expected_detail or metadata.get("effective_detail") != expected_detail:
            raise RuntimeError("capture detail does not match the benchmark mode")
        cycle_count = db.execute("SELECT count(*) FROM cycles").fetchone()[0]
        if not slow_writer and cycle_count != expected_frames:
            raise RuntimeError(
                f"{expected_detail}: expected {expected_frames} cycles, recorded {cycle_count}"
            )
        if slow_writer and not 0 < cycle_count <= expected_frames:
            raise RuntimeError(f"slow-writer capture has invalid cycle count {cycle_count}")
        health = db.execute(
            "SELECT rows_written,omitted_events FROM recorder_health"
        ).fetchone()
        drain = int(metadata.get("drain_duration_ns", "0"))
        if slow_writer:
            if metadata.get("benchmark_writer_delay_ms") != SLOW_WRITER_DELAY_MS:
                raise RuntimeError("slow-writer delay was not active in the recorder")
            if int(health[1]) == 0:
                raise RuntimeError("slow-writer run did not exercise bounded recorder loss")
        return int(health[0]), int(health[1]), drain


def summarize(samples: list[Sample]) -> dict[str, dict[str, float]]:
    result: dict[str, dict[str, float]] = {}
    for mode in MODES:
        selected = [sample for sample in samples if sample.mode == mode]
        elapsed = [sample.elapsed_ns / sample.frames for sample in selected]
        rates = [sample.cycles_per_second for sample in selected]
        sizes = [sample.capture_bytes / sample.frames for sample in selected]
        median_elapsed = statistics.median(elapsed)
        ordered_elapsed = sorted(elapsed)
        p95_elapsed = ordered_elapsed[min(len(ordered_elapsed) - 1, (95 * len(ordered_elapsed) + 99) // 100 - 1)]
        result[mode] = {
            "samples": len(selected),
            "median_wall_ns_per_cycle": median_elapsed,
            "p95_wall_ns_per_cycle": p95_elapsed,
            "mad_wall_ns_per_cycle": statistics.median(abs(value - median_elapsed) for value in elapsed),
            "median_cycles_per_second": statistics.median(rates),
            "median_capture_bytes_per_cycle": statistics.median(sizes),
            "median_rows_written": statistics.median(sample.rows_written for sample in selected),
            "median_omitted_events": statistics.median(sample.omitted_events for sample in selected),
            "median_drain_duration_ns": statistics.median(sample.drain_duration_ns for sample in selected),
        }
    baseline = result["disabled"]["median_wall_ns_per_cycle"]
    for values in result.values():
        values["wall_ratio_to_disabled"] = values["median_wall_ns_per_cycle"] / baseline
    return result


def markdown_report(report: dict) -> str:
    lines = [
        "# RocRay Observatory benchmark",
        "",
        "Timing values are report-only. Semantic failures abort the run; machine-dependent ratios do not.",
        "",
        "| mode | samples | median ns/cycle | cycles/s | bytes/cycle | omitted | ratio to disabled |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for mode in MODES:
        row = report["summary"][mode]
        lines.append(
            f"| {mode} | {row['samples']} | {row['median_wall_ns_per_cycle']:.1f} | "
            f"{row['median_cycles_per_second']:.1f} | {row['median_capture_bytes_per_cycle']:.1f} | "
            f"{row['median_omitted_events']:.0f} | {row['wall_ratio_to_disabled']:.3f} |"
        )
    return "\n".join(lines) + "\n"


def run_sample(executable: Path, directory: Path, mode: str, frames: int, repetition: int, order: int) -> Sample:
    command = [str(executable), "--host-headless", f"--host-headless-frames={frames}"]
    capture = directory / f"{repetition:02d}-{order}-{mode}.rrstats"
    slow_writer = mode == "full_slow_writer"
    if mode != "disabled":
        detail = "full" if slow_writer else mode
        command.extend(
            (
                f"--host-stats-output={capture}",
                f"--host-stats-detail={detail}",
                "--host-stats-max-mib=128",
            )
        )
        if slow_writer:
            command.append("--host-stats-buffer-mib=1")
        else:
            # This benchmark validates recorder cost, not default-buffer
            # saturation while an intentionally tiny app runs flat out.
            command.append("--host-stats-buffer-mib=512")
    environment = os.environ.copy()
    if slow_writer:
        environment["ROC_RAY_OBSERVATORY_BENCH_WRITER_DELAY_MS"] = SLOW_WRITER_DELAY_MS
    started = time.perf_counter_ns()
    completed = subprocess.run(
        command, cwd=directory, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    elapsed = time.perf_counter_ns() - started
    if completed.returncode != 0:
        raise RuntimeError(f"{mode} run failed ({completed.returncode}): {completed.stderr.decode(errors='replace')}")
    if mode == "disabled":
        rows, omitted, drain, size = 0, 0, 0, 0
    else:
        rows, omitted, drain = capture_facts(
            capture, frames, "full" if slow_writer else mode, slow_writer
        )
        size = capture.stat().st_size
    return Sample(repetition, order, mode, elapsed, frames, frames * 1_000_000_000 / elapsed, size, rows, omitted, drain)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", type=int, default=20_000)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--repeats", type=int, default=9)
    parser.add_argument("--seed", type=int, default=178)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    parser.add_argument("--skip-platform-build", action="store_true")
    args = parser.parse_args()
    if args.frames < 1 or args.warmups < 0 or args.repeats < 1:
        parser.error("frames/repeats must be positive and warmups non-negative")
    return args


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parent.parent
    if not args.skip_platform_build:
        subprocess.run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=root, check=True)
    roc = os.environ.get("ROC", "roc")
    rng = random.Random(args.seed)
    try:
        with local_bundles.terminating_signals(), local_bundles.serve_packages(root, mode="source", roc=roc) as packages:
            staged = local_bundles.stage_app(root / "test/observatory_perf/main.roc", packages, packages.scratch_dir / "observatory_perf")
            subprocess.run([roc, "build", staged.name, *local_bundles.PACKAGE_LIMIT_ARGS], cwd=staged.parent, check=True)
            executable = executable_for(staged)
            for warmup in range(args.warmups):
                warmup_order = list(MODES)
                rng.shuffle(warmup_order)
                for position, mode in enumerate(warmup_order):
                    run_sample(executable, staged.parent, mode, args.frames, -(warmup + 1), position)
            samples: list[Sample] = []
            for repetition in range(args.repeats):
                order = list(MODES)
                rng.shuffle(order)
                for position, mode in enumerate(order):
                    samples.append(run_sample(executable, staged.parent, mode, args.frames, repetition, position))
    except (OSError, RuntimeError, subprocess.CalledProcessError, local_bundles.LocalBundleError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    report = {
        "format_version": 1,
        "methodology": {"frames": args.frames, "warmups": args.warmups, "repeats": args.repeats, "seed": args.seed, "randomized_within_repetition": True, "timing_is_report_only": True},
        "machine": {"platform": platform.platform(), "processor": platform.processor(), "python": platform.python_version()},
        "summary": summarize(samples),
        "samples": [asdict(sample) for sample in samples],
    }
    rendered_json = json.dumps(report, indent=2, sort_keys=True) + "\n"
    rendered_markdown = markdown_report(report)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(rendered_json, encoding="utf-8")
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(rendered_markdown, encoding="utf-8")
    print(rendered_markdown, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
