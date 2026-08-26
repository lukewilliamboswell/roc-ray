-- Which named application zones consumed active time or spent time parked?
-- Works at every detail level because annotations are application-selected.
-- Nested zones each include work performed inside their children.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'annotations'
), data AS (
    SELECT name,
           CASE phase WHEN 1 THEN 'init!' WHEN 2 THEN 'update!'
                      WHEN 3 THEN 'render!' WHEN 4 THEN 'task' ELSE 'unknown' END AS phase,
           count(*) AS zone_count,
           sum(kind = 5) AS aborted_zones,
           sum(wall_ns) AS wall_ns,
           sum(active_ns) AS active_ns,
           sum(parked_ns) AS parked_ns,
           max(wall_ns) AS max_wall_ns
    FROM annotations WHERE kind IN (2, 5)
    GROUP BY name, phase
)
SELECT evidence.status AS evidence_status,
       CASE WHEN evidence.status = 'complete' AND data.name IS NULL
            THEN 'complete evidence; no completed zones observed'
            ELSE evidence.reason END AS evidence_reason,
       data.name, data.phase, data.zone_count, data.aborted_zones,
       data.wall_ns, data.wall_ns / 1000000.0 AS wall_ms,
       data.active_ns, data.active_ns / 1000000.0 AS active_ms,
       data.parked_ns, data.parked_ns / 1000000.0 AS parked_ms,
       data.max_wall_ns, data.max_wall_ns / 1000000.0 AS max_wall_ms
FROM evidence LEFT JOIN data ON evidence.status = 'complete'
ORDER BY data.active_ns DESC, data.wall_ns DESC, data.name;
