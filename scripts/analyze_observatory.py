#!/usr/bin/env python3
"""Read-only summary reporter for RocRay Observatory ``.rrstats`` captures."""

from __future__ import annotations

import argparse
import math
import sqlite3
import sys
from pathlib import Path

SUPPORTED_SCHEMA = 11
DETAIL_TABLES = (
    ("Effects", "hosted_effects", "hosted_effects"),
    ("Tasks", "task_events", "task_lifecycle"),
    ("Queues", "queue_pressure", "queue_pressure"),
    ("Resources", "resource_lifecycle", "resource_lifecycle"),
    ("Draw", "draw_summaries", "draw_observations"),
    ("Allocations", "allocation_events", "allocation_lifecycle"),
    ("Latency", "structural_latency", "structural_latency"),
)


class CaptureError(Exception):
    """The file is not a supported, finalized Observatory capture."""


def _open_readonly(path: Path) -> sqlite3.Connection:
    """Open one capture without authority to mutate or trust its schema."""
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    db.execute("PRAGMA query_only=ON")
    db.execute("PRAGMA trusted_schema=OFF")
    return db


def percentile(values: list[int], fraction: float) -> float:
    """Return the linearly interpolated percentile of sorted integer values."""
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def _tables(db: sqlite3.Connection) -> set[str]:
    return {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def _metadata(db: sqlite3.Connection) -> dict[str, str]:
    if "metadata" not in _tables(db):
        raise CaptureError("missing metadata table")
    return dict(db.execute("SELECT key, value FROM metadata"))


def validate(db: sqlite3.Connection) -> dict[str, str]:
    metadata = _metadata(db)
    try:
        version = int(metadata.get("schema_version", ""))
    except ValueError as error:
        raise CaptureError("invalid schema_version metadata") from error
    if version != SUPPORTED_SCHEMA:
        raise CaptureError(f"unsupported schema version {version}; expected {SUPPORTED_SCHEMA}")
    if metadata.get("clean_shutdown") != "1":
        raise CaptureError("capture did not record a clean shutdown")
    if metadata.get("final_state") != "complete":
        raise CaptureError(f"capture final state is {metadata.get('final_state', 'missing')!r}, not 'complete'")
    if "measurement_status" not in _tables(db):
        raise CaptureError("missing final schema-v11 measurement_status contract")
    unfinished = list(db.execute(
        "SELECT name FROM measurement_status WHERE status='unfinalized' ORDER BY name"
    ))
    if unfinished:
        raise CaptureError("capture has unfinalized measurement status")
    return metadata


def _measurement_status(db: sqlite3.Connection) -> dict[str, tuple[str, str]]:
    return {name: (status, reason) for name, status, reason in db.execute(
        "SELECT name,status,reason FROM measurement_status"
    )}


def _complete(statuses: dict[str, tuple[str, str]], name: str) -> bool:
    return statuses.get(name, ("unavailable", "measurement status is missing"))[0] == "complete"


def _unavailable_line(statuses: dict[str, tuple[str, str]], name: str, label: str) -> str:
    status, reason = statuses.get(name, ("unavailable", "measurement status is missing"))
    return f"  {label}: unavailable (evidence={status}: {reason})"


def _duration_summary(db: sqlite3.Connection, title: str, table: str) -> list[str]:
    rows = list(db.execute(
        f"SELECT name,kind,count(*),sum(duration_ns),max(duration_ns),sum(value_a),max(value_b) FROM {table} "
        "GROUP BY name,kind ORDER BY count(*) DESC,name,kind LIMIT 10"
    ))
    lines = [f"{title}: {sum(row[2] for row in rows)} event(s) in displayed groups"]
    lines.extend(f"  {name or '(unnamed)'} kind={kind}: count={count} duration_total={total / 1e6:.3f}ms duration_max={maximum / 1e6:.3f}ms value_a_total={value_a} value_b_max={value_b}" for name, kind, count, total, maximum, value_a, value_b in rows)
    return lines


def _callback_summary(db: sqlite3.Connection) -> list[str]:
    rows = list(db.execute(
        "SELECT name,phase,outcome,count(*),sum(duration_ns),max(duration_ns) "
        "FROM callback_summaries GROUP BY name,phase,outcome "
        "ORDER BY count(*) DESC,name,phase,outcome LIMIT 10"
    ))
    lines = [f"Callbacks: {sum(row[3] for row in rows)} callback(s) in displayed groups"]
    lines.extend(f"  {name or '(unnamed)'} phase={phase} outcome={outcome}: count={count} total={total / 1e6:.3f}ms max={maximum / 1e6:.3f}ms" for name, phase, outcome, count, total, maximum in rows)
    return lines


def _demonstrated_analyses(db: sqlite3.Connection, tables: set[str], statuses: dict[str, tuple[str, str]]) -> list[str]:
    """Report the issue's concrete investigations without inventing data."""
    lines = ["Demonstrated analyses:"]
    if "gpu_facts" in tables and _complete(statuses, "backend_facts"):
        pacing = db.execute("SELECT name,value_b FROM gpu_facts WHERE kind=2 ORDER BY id LIMIT 1").fetchone()
        if pacing and pacing[0] == "host_fps_cap" and pacing[1] > 0:
            budget = 1_000_000_000 / pacing[1]
            missed = db.execute("SELECT count(*) FROM cycles WHERE duration_ns>?", (budget,)).fetchone()[0]
            lines.append(f"  Presentation budget: {missed} cycle(s) over {budget / 1e6:.3f}ms host cap")
        else:
            lines.append("  Presentation budget: unavailable (no enforceable numeric presentation budget recorded)")
        phases = list(db.execute("SELECT name,count(*),sum(duration_ns),max(duration_ns) FROM gpu_facts WHERE kind BETWEEN 4 AND 7 GROUP BY name ORDER BY kind,name"))
        lines.append("  Backend phases: " + ("unavailable (no phase facts)" if not phases else "; ".join(f"{name}: count={count} total={total / 1e6:.3f}ms max={maximum / 1e6:.3f}ms" for name, count, total, maximum in phases)))
    else:
        lines.append("  Presentation budget: unavailable (gpu_facts absent)")
        lines.append("  Backend phases: unavailable (gpu_facts absent)")

    if "annotations" in tables and _complete(statuses, "annotations"):
        marks = list(db.execute(
            "SELECT a.cycle,a.name,a.timestamp_ns FROM annotations a "
            "WHERE a.kind=0 AND a.cycle IN "
            "(SELECT cycle FROM cycles ORDER BY duration_ns DESC LIMIT 10) "
            "ORDER BY a.timestamp_ns,a.id LIMIT 20"
        ))
        lines.append("  Marks around slow cycles: " + (
            "none" if not marks else "; ".join(
                f"cycle={cycle} {name}@{timestamp / 1e6:.3f}ms"
                for cycle, name, timestamp in marks
            )
        ))
    else:
        lines.append("  Marks around slow cycles: unavailable (annotations absent)")

    if "hosted_effects" in tables and _complete(statuses, "hosted_effects"):
        names = [row[0] for row in db.execute("SELECT name FROM hosted_effects GROUP BY name ORDER BY max(duration_ns) DESC,name LIMIT 10")]
        rows = []
        for name in names:
            values = list(db.execute("SELECT duration_ns,value_a FROM hosted_effects WHERE name=?", (name,)))
            rows.append((name, len(values), sum(row[1] for row in values), percentile([row[0] for row in values], .95), max(row[0] for row in values)))
        lines.append("  Effect tail/copy costs: " + ("no events" if not rows else "; ".join(f"{name}: count={count} copied={copied}B p95={p95 / 1e6:.3f}ms max={maximum / 1e6:.3f}ms" for name, count, copied, p95, maximum in rows)))
        worker = db.execute(
            "SELECT count(*),sum(worker_ns),sum(external_ns) FROM hosted_effects "
            "WHERE worker_ns IS NOT NULL OR external_ns IS NOT NULL"
        ).fetchone()
        lines.append("  Worker/external intervals: " + (
            "unavailable" if worker[0] == 0 else
            f"count={worker[0]} worker_total={(worker[1] or 0) / 1e6:.3f}ms external_total={(worker[2] or 0) / 1e6:.3f}ms"
        ))
    else: lines.append(_unavailable_line(statuses, "hosted_effects", "Effect tail/copy costs"))
    if "allocation_events" in tables and _complete(statuses, "allocation_lifecycle"):
        rows = list(db.execute("SELECT subject_id,kind,timestamp_ns,bytes,prior_bytes,copied_bytes FROM allocation_events ORDER BY subject_id,timestamp_ns,id"))
        starts: dict[int, int] = {}
        sizes: dict[int, int] = {}
        lifetimes: list[int] = []
        moves = 0
        in_place = 0
        copied = 0
        live = 0
        peak = 0
        for subject, kind, timestamp, size, prior, copied_bytes in rows:
            if kind == 0:
                starts.setdefault(subject, timestamp)
                sizes[subject] = size
                live += size
            elif kind == 2:
                moves += 1
                copied += copied_bytes
                live += size - sizes.get(subject, prior)
                sizes[subject] = size
            elif kind == 3:
                in_place += 1
                live += size - sizes.get(subject, prior)
                sizes[subject] = size
            elif kind == 1 and subject in starts:
                lifetimes.append(timestamp - starts.pop(subject))
                live -= sizes.pop(subject, prior)
            peak = max(peak, live)
        lines.append(f"  Allocation lifetimes: completed={len(lifetimes)} median={percentile(lifetimes, .5) / 1e6:.3f}ms realloc_moves={moves} realloc_in_place={in_place} copied={copied}B live={live}B peak={peak}B survivors={len(starts)}")
        heavy = list(db.execute(
            "SELECT cycle,count(*),sum(CASE WHEN kind IN (0,2,3) THEN bytes ELSE 0 END) "
            "FROM allocation_events GROUP BY cycle ORDER BY 3 DESC,2 DESC,cycle LIMIT 10"
        ))
        lines.append("  Allocation-heavy cycles: " + (
            "none" if not heavy else "; ".join(
                f"cycle={cycle} events={count} allocated_or_resized={amount or 0}B"
                for cycle, count, amount in heavy
            )
        ))
    else: lines.append(_unavailable_line(statuses, "allocation_lifecycle", "Allocation lifetimes"))
    if "task_events" in tables and _complete(statuses, "task_lifecycle"):
        events = list(db.execute("SELECT subject_id,kind,timestamp_ns FROM task_events ORDER BY subject_id,timestamp_ns,id"))
        active_start: dict[int, int] = {}
        park_start: dict[int, int] = {}
        finish: dict[int, int] = {}
        active: list[int] = []
        parked: list[int] = []
        delivery: list[int] = []
        for subject, kind, timestamp in events:
            if kind == 2: active_start[subject] = timestamp
            elif kind == 3:
                if subject in active_start: active.append(timestamp - active_start.pop(subject))
                park_start[subject] = timestamp
            elif kind == 4:
                if subject in park_start: parked.append(timestamp - park_start.pop(subject))
                active_start[subject] = timestamp
            elif kind == 5:
                if subject in active_start: active.append(timestamp - active_start.pop(subject))
                finish[subject] = timestamp
            elif kind == 6 and subject in finish: delivery.append(timestamp - finish.pop(subject))
        lines.append(f"  Task intervals: active_median={percentile(active, .5) / 1e6:.3f}ms parked_median={percentile(parked, .5) / 1e6:.3f}ms delivery_median={percentile(delivery, .5) / 1e6:.3f}ms")
        lines.append("  Longest task turn: " + (
            "unavailable" if not active else f"{max(active) / 1e6:.3f}ms"
        ))
    else: lines.append(_unavailable_line(statuses, "task_lifecycle", "Task intervals"))
    if "queue_pressure" in tables and _complete(statuses, "queue_pressure"):
        saturation, oldest = db.execute("SELECT sum(kind=2),max(duration_ns) FROM queue_pressure").fetchone()
        lines.append(f"  Queue pressure: saturations={saturation or 0} oldest_age_max={(oldest or 0) / 1e6:.3f}ms")
    else: lines.append(_unavailable_line(statuses, "queue_pressure", "Queue pressure"))
    if "resource_lifecycle" in tables and _complete(statuses, "resource_lifecycle"):
        count, delay = db.execute("SELECT count(*),max(duration_ns) FROM resource_lifecycle WHERE kind=3").fetchone()
        lines.append(f"  Resource destruction: count={count} delay_max={(delay or 0) / 1e6:.3f}ms")
        retained = db.execute(
            "SELECT count(DISTINCT created.subject_id) FROM resource_lifecycle created "
            "WHERE created.kind=0 AND NOT EXISTS "
            "(SELECT 1 FROM resource_lifecycle destroyed WHERE destroyed.subject_id=created.subject_id AND destroyed.kind=3)"
        ).fetchone()[0]
        lines.append(f"  Resources retained at shutdown: {retained}")
    else: lines.append(_unavailable_line(statuses, "resource_lifecycle", "Resource destruction"))
    if "structural_latency" in tables and _complete(statuses, "structural_latency"):
        values = [row[0] for row in db.execute("SELECT duration_ns FROM structural_latency WHERE name='input_to_presentation'")]
        if values:
            lines.append(f"  Input-to-presentation: count={len(values)} median={percentile(values, .5) / 1e6:.3f}ms p95={percentile(values, .95) / 1e6:.3f}ms")
        else:
            upper = [row[0] for row in db.execute("SELECT duration_ns FROM structural_latency WHERE name='input_to_end_drawing_including_pacing'")]
            lines.append("  Input-to-presentation: unavailable (backend exposes only input-to-EndDrawing including pacing)" + (f"; upper_bound_p95={percentile(upper, .95) / 1e6:.3f}ms" if upper else ""))
    else: lines.append(_unavailable_line(statuses, "structural_latency", "Input-to-presentation"))
    if "draw_summaries" in tables and _complete(statuses, "draw_observations"):
        draw = db.execute(
            "SELECT count(*),sum(value_a),sum(value_b),sum(duration_ns) FROM draw_summaries"
        ).fetchone()
        lines.append(
            f"  Rendering pressure: events={draw[0]} primary_count={draw[1] or 0} "
            f"secondary_count={draw[2] or 0} total={(draw[3] or 0) / 1e6:.3f}ms"
        )
    else:
        lines.append(_unavailable_line(statuses, "draw_observations", "Rendering pressure"))
    return lines


def analyze(path: Path, slowest: int = 10) -> str:
    """Validate and summarize *path* without allowing SQLite writes."""
    try:
        db = _open_readonly(path)
    except sqlite3.Error as error:
        raise CaptureError(f"cannot open capture read-only: {error}") from error
    try:
        metadata = validate(db)
        tables = _tables(db)
        statuses = _measurement_status(db)
        if "cycles" not in tables:
            raise CaptureError("missing cycles table")
        if not _complete(statuses, "cycle_summary"):
            status, reason = statuses.get("cycle_summary", ("unavailable", "missing status"))
            raise CaptureError(f"cycle summary evidence is {status}: {reason}")
        durations = [row[0] for row in db.execute("SELECT duration_ns FROM cycles")]
        lines = [
            f"Observatory capture: {path}",
            f"schema={metadata['schema_version']} detail={metadata.get('effective_detail', 'unknown')} cycles={len(durations)}",
            "Environment: "
            f"RocRay={metadata.get('rocray_version', 'unknown')} "
            f"Roc={metadata.get('roc_compiler_pin', 'unknown')} "
            f"target={metadata.get('target_profile', 'unknown')} "
            f"backend={metadata.get('backend', 'unknown')} "
            f"host={metadata.get('host_os', 'unknown')}/{metadata.get('host_arch', 'unknown')} "
            f"app={metadata.get('app_name', 'unknown')}",
            f"Unavailable sources: {metadata.get('unavailable_sources', 'none disclosed')}",
            "Cycle latency: " + (
                f"median={percentile(durations, .5) / 1e6:.3f}ms "
                f"p95={percentile(durations, .95) / 1e6:.3f}ms "
                f"p99={percentile(durations, .99) / 1e6:.3f}ms"
                if durations else "no cycle rows"
            ),
            f"Slowest cycles (top {slowest}):",
        ]
        for cycle, duration, update, render, executor, host_other in db.execute(
            "SELECT cycle,duration_ns,update_ns,render_callback_ns,task_executor_ns,host_other_ns FROM cycles "
            "ORDER BY duration_ns DESC,cycle LIMIT ?", (slowest,)
        ):
            lines.append(f"  {cycle}: total={duration / 1e6:.3f}ms update={update / 1e6:.3f}ms render_callback={render / 1e6:.3f}ms task_executor={executor / 1e6:.3f}ms host_other={host_other / 1e6:.3f}ms")

        if "callback_summaries" in tables and _complete(statuses, "callback_summaries"):
            lines.extend(_callback_summary(db))
        if "annotations" in tables and _complete(statuses, "annotations"):
            zones = list(db.execute(
                "SELECT name,count(*),sum(wall_ns),sum(active_ns),sum(parked_ns),max(wall_ns) "
                "FROM annotations WHERE kind=2 GROUP BY name ORDER BY sum(wall_ns) DESC,name LIMIT 10"
            ))
            lines.append(f"Zones: {sum(row[1] for row in zones)} completed zone(s)")
            lines.extend(f"  {name}: count={count} wall={wall / 1e6:.3f}ms active={active / 1e6:.3f}ms parked={parked / 1e6:.3f}ms max={maximum / 1e6:.3f}ms" for name, count, wall, active, parked, maximum in zones)
        lines.extend(_demonstrated_analyses(db, tables, statuses))
        for title, table, measurement in DETAIL_TABLES:
            if table in tables and _complete(statuses, measurement):
                lines.extend(_duration_summary(db, title, table))
        if "recorder_health" in tables:
            row = db.execute("SELECT transactions,checkpoints,queue_high_water,output_bytes,omitted_events,rows_written,writer_failed,output_limited,writer_active_wall_ns,writer_idle_wall_ns,writer_cpu_ns FROM recorder_health WHERE id=1").fetchone()
            lines.append("Recorder health: " + ("missing" if row is None else "transactions={} checkpoints={} queue_high_water={} output_bytes={} omissions={} rows={} writer_failed={} output_limited={} writer_active_wall={:.3f}ms writer_idle_wall={:.3f}ms writer_cpu={}".format(*row[:8], row[8] / 1e6, row[9] / 1e6, "unavailable" if row[10] is None else f"{row[10] / 1e6:.3f}ms")))
        if "recording_gaps" in tables:
            gaps = db.execute("SELECT coalesce(sum(lost_count),0) FROM recording_gaps").fetchone()[0]
            lines.append(f"Recording gaps: {gaps} omitted event(s)")
        return "\n".join(lines)
    except sqlite3.Error as error:
        raise CaptureError(f"invalid capture schema: {error}") from error
    finally:
        db.close()


def compare(before: Path, after: Path) -> str:
    """Compare cycle distributions from two validated captures, read-only."""
    results = []
    environments = []
    for path in (before, after):
        db = _open_readonly(path)
        try:
            metadata = validate(db)
            statuses = _measurement_status(db)
            if not _complete(statuses, "cycle_summary"):
                status, reason = statuses.get("cycle_summary", ("unavailable", "missing status"))
                raise CaptureError(f"cycle summary evidence is {status}: {reason}")
            environments.append(tuple(metadata.get(key, "unknown") for key in (
                "target_profile", "backend", "host_os", "host_arch", "effective_detail",
                "chunk_count", "summary_reserve", "max_output_bytes", "transaction_chunks",
            )))
            values = [row[0] for row in db.execute("SELECT duration_ns FROM cycles")]
            results.append((len(values), percentile(values, .5), percentile(values, .95), percentile(values, .99)))
        finally:
            db.close()
    if environments[0] != environments[1]:
        raise CaptureError(
            "captures use different target/backend/host/detail/recorder configurations; "
            f"before={environments[0]!r} after={environments[1]!r}"
        )
    old, new = results
    return (f"Before vs after: cycles={old[0]}->{new[0]} "
            f"median={old[1] / 1e6:.3f}->{new[1] / 1e6:.3f}ms delta={(new[1]-old[1]) / 1e6:+.3f}ms "
            f"p95={old[2] / 1e6:.3f}->{new[2] / 1e6:.3f}ms delta={(new[2]-old[2]) / 1e6:+.3f}ms "
            f"p99={old[3] / 1e6:.3f}->{new[3] / 1e6:.3f}ms delta={(new[3]-old[3]) / 1e6:+.3f}ms")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="Observatory .rrstats capture")
    parser.add_argument("--compare", type=Path, help="compare CAPTURE (before) with this after capture")
    parser.add_argument("--slowest", type=int, default=10, help="number of slow cycles to show (default: 10)")
    args = parser.parse_args(argv)
    if args.slowest < 0:
        parser.error("--slowest must not be negative")
    try:
        print(compare(args.capture, args.compare) if args.compare else analyze(args.capture, args.slowest))
    except CaptureError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
