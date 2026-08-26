-- Which innermost Trace zones owned allocation traffic, moves, and survivors?
-- Requires full detail and complete annotations. Allocations outside a zone are
-- reported explicitly. requested_bytes is requested allocation/resize size;
-- copied_bytes is known only for moving reallocations.
WITH allocation_evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'allocation_lifecycle'
), annotation_evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'annotations'
), evidence AS (
    SELECT CASE
             WHEN allocation_evidence.status <> 'complete' THEN allocation_evidence.status
             WHEN annotation_evidence.status <> 'complete' THEN annotation_evidence.status
             ELSE 'complete' END AS status,
           CASE
             WHEN allocation_evidence.status <> 'complete' THEN allocation_evidence.reason
             WHEN annotation_evidence.status <> 'complete' THEN annotation_evidence.reason
             ELSE 'complete allocation and annotation evidence' END AS reason
    FROM allocation_evidence CROSS JOIN annotation_evidence
), zone_names AS (
    SELECT CAST(integer_value AS INTEGER) AS zone_id, name,
           row_number() OVER (PARTITION BY integer_value ORDER BY kind = 2 DESC, id DESC) AS n
    FROM annotations WHERE kind IN (2, 5)
), latest AS (
    SELECT *, row_number() OVER (PARTITION BY subject_id ORDER BY timestamp_ns DESC, id DESC) AS n
    FROM allocation_events WHERE (SELECT status FROM evidence) = 'complete'
), activity AS (
    SELECT a.zone_id, a.phase,
           count(*) AS lifecycle_events,
           sum(a.kind IN (0, 2, 3)) AS allocation_or_resize_calls,
           sum(CASE WHEN a.kind IN (0, 2, 3) THEN a.bytes ELSE 0 END) AS requested_bytes,
           sum(a.copied_bytes) AS copied_bytes,
           sum(CASE WHEN a.kind = 1 THEN a.bytes ELSE 0 END) AS freed_bytes
    FROM allocation_events a WHERE (SELECT status FROM evidence) = 'complete'
    GROUP BY a.zone_id, a.phase
), survivors AS (
    SELECT zone_id, phase, count(*) AS survivor_count, sum(bytes) AS survivor_bytes
    FROM latest WHERE n = 1 AND kind <> 1 GROUP BY zone_id, phase
)
SELECT evidence.status AS evidence_status,
       CASE WHEN evidence.status = 'complete' AND activity.zone_id IS NULL
            THEN 'complete evidence; no allocation lifecycle events observed' ELSE evidence.reason END AS evidence_reason,
       activity.zone_id,
       CASE WHEN activity.zone_id = 0 THEN '(outside a Trace zone)'
            ELSE zone_names.name END AS zone_name,
       CASE activity.phase WHEN 1 THEN 'init!' WHEN 2 THEN 'update!'
                           WHEN 3 THEN 'render!' WHEN 4 THEN 'task' ELSE 'unknown' END AS phase,
       activity.lifecycle_events, activity.allocation_or_resize_calls,
       activity.requested_bytes, activity.requested_bytes / 1024.0 AS requested_kib,
       activity.copied_bytes, activity.copied_bytes / 1024.0 AS copied_kib,
       activity.freed_bytes, activity.freed_bytes / 1024.0 AS freed_kib,
       coalesce(survivors.survivor_count, 0) AS survivor_count,
       coalesce(survivors.survivor_bytes, 0) AS survivor_bytes
FROM evidence
LEFT JOIN activity ON evidence.status = 'complete'
LEFT JOIN zone_names ON zone_names.zone_id = activity.zone_id AND zone_names.n = 1
LEFT JOIN survivors ON survivors.zone_id = activity.zone_id AND survivors.phase = activity.phase
ORDER BY activity.requested_bytes DESC, activity.zone_id;
