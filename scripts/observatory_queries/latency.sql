-- Which structural observations had measurable latency?
-- Requires standard or full detail. Input-to-presentation is unavailable on
-- headless targets and remains distinct from input-to-EndDrawing, which also
-- includes opaque presentation and pacing time.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'structural_latency'
), expected(name) AS (VALUES
    ('input_to_update'),
    ('input_to_presentation'),
    ('input_to_end_drawing_including_pacing'),
    ('task_message_staged'),
    ('task_finish_to_delivery')
), ranked AS (
    SELECT name, duration_ns,
           row_number() OVER (PARTITION BY name ORDER BY duration_ns) AS n,
           count(*) OVER (PARTITION BY name) AS c
    FROM structural_latency WHERE (SELECT status FROM evidence) = 'complete'
), data AS (
    SELECT name, max(c) AS observations,
           max(CASE WHEN n = (c + 1) / 2 THEN duration_ns END) AS median_ns,
           max(CASE WHEN n = (c * 95 + 99) / 100 THEN duration_ns END) AS p95_ns,
           max(duration_ns) AS max_ns
    FROM ranked GROUP BY name
), backend AS (
    SELECT EXISTS(SELECT 1 FROM gpu_facts WHERE kind = 0 AND name = 'raylib_native') AS graphical
)
SELECT CASE
           WHEN evidence.status <> 'complete' THEN evidence.status
           WHEN expected.name = 'input_to_presentation' AND (NOT backend.graphical OR data.observations IS NULL) THEN 'unavailable'
           WHEN expected.name = 'input_to_end_drawing_including_pacing' AND (NOT backend.graphical OR data.observations IS NULL) THEN 'unavailable'
           ELSE 'complete' END AS evidence_status,
       CASE
           WHEN evidence.status <> 'complete' THEN evidence.reason
           WHEN expected.name IN ('input_to_presentation', 'input_to_end_drawing_including_pacing') AND NOT backend.graphical THEN 'headless backend has no presentation boundary'
           WHEN expected.name IN ('input_to_presentation', 'input_to_end_drawing_including_pacing') AND data.observations IS NULL THEN 'no supported presentation latency rows were recorded'
           WHEN data.observations IS NULL THEN 'complete evidence; no matching events observed'
           ELSE evidence.reason END AS evidence_reason,
       expected.name, data.observations,
       data.median_ns, data.median_ns / 1000000.0 AS median_ms,
       data.p95_ns, data.p95_ns / 1000000.0 AS p95_ms,
       data.max_ns, data.max_ns / 1000000.0 AS max_ms
FROM evidence CROSS JOIN expected CROSS JOIN backend
LEFT JOIN data USING(name)
ORDER BY expected.name;
