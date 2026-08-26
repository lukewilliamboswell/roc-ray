-- Which host cycles were slow, and which measured component dominated them?
-- Works at every detail level. Results are the 20 slowest cycles; edit the
-- final LIMIT for a different bound. Presentation-budget columns are NULL
-- unless a graphical host enforced a numeric cap and presented that cycle.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'cycle_summary'
), ranked AS (
    SELECT duration_ns,
           row_number() OVER (ORDER BY duration_ns) AS n,
           count(*) OVER () AS c
    FROM cycles WHERE (SELECT status FROM evidence) = 'complete'
), distribution AS (
    SELECT count(*) AS cycle_count,
           max(CASE WHEN n = (c + 1) / 2 THEN duration_ns END) AS median_ns,
           max(CASE WHEN n = (c * 95 + 99) / 100 THEN duration_ns END) AS p95_ns,
           max(CASE WHEN n = (c * 99 + 99) / 100 THEN duration_ns END) AS p99_ns
    FROM ranked
), budget AS (
    SELECT CASE WHEN EXISTS (
               SELECT 1 FROM gpu_facts WHERE kind = 0 AND name = 'raylib_native'
           ) AND EXISTS (
               SELECT 1 FROM gpu_facts WHERE kind = 2 AND name = 'host_fps_cap' AND value_b > 0
           ) THEN 1000000000 / (
               SELECT value_b FROM gpu_facts
               WHERE kind = 2 AND name = 'host_fps_cap' AND value_b > 0 LIMIT 1
           ) END AS budget_ns
), data AS (
    SELECT cycles.*,
           CASE
               WHEN update_ns >= render_callback_ns AND update_ns >= task_executor_ns AND update_ns >= host_other_ns THEN 'update!'
               WHEN render_callback_ns >= task_executor_ns AND render_callback_ns >= host_other_ns THEN 'render! callback'
               WHEN task_executor_ns >= host_other_ns THEN 'task executor including polling or pacing'
               ELSE 'other host work'
           END AS dominant_component,
           EXISTS (SELECT 1 FROM gpu_facts p WHERE p.cycle = cycles.cycle AND p.kind = 1 AND p.name = 'presentation_completed') AS presented
    FROM cycles WHERE (SELECT status FROM evidence) = 'complete'
    ORDER BY duration_ns DESC, cycle LIMIT 20
)
SELECT evidence.status AS evidence_status, evidence.reason AS evidence_reason,
       distribution.cycle_count,
       distribution.median_ns, distribution.median_ns / 1000000.0 AS median_ms,
       distribution.p95_ns, distribution.p95_ns / 1000000.0 AS p95_ms,
       distribution.p99_ns, distribution.p99_ns / 1000000.0 AS p99_ms,
       data.cycle, data.duration_ns, data.duration_ns / 1000000.0 AS duration_ms,
       data.update_ns, data.update_ns / 1000000.0 AS update_ms,
       data.render_callback_ns, data.render_callback_ns / 1000000.0 AS render_callback_ms,
       data.task_executor_ns, data.task_executor_ns / 1000000.0 AS task_executor_ms,
       data.host_other_ns, data.host_other_ns / 1000000.0 AS host_other_ms,
       data.dominant_component,
       CASE WHEN data.presented AND budget.budget_ns IS NOT NULL THEN budget.budget_ns END AS presentation_budget_ns,
       CASE WHEN data.presented AND budget.budget_ns IS NOT NULL THEN data.duration_ns > budget.budget_ns END AS over_presentation_budget
FROM evidence CROSS JOIN distribution CROSS JOIN budget
LEFT JOIN data ON evidence.status = 'complete';
