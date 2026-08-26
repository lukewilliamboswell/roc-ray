-- Which cycles generated the most Roc allocation traffic?
-- Works at every detail level from per-cycle counters; it does not require or
-- imply that individual allocations were recorded. Results are the top 20.
WITH evidence AS (
    SELECT status, reason FROM measurement_status WHERE name = 'allocation_counters'
), data AS (
    SELECT cycle, alloc_calls, alloc_bytes, free_calls, free_bytes,
           live_bytes, peak_live_bytes, update_alloc_calls, update_alloc_bytes
    FROM cycles WHERE (SELECT status FROM evidence) = 'complete'
    ORDER BY alloc_bytes DESC, alloc_calls DESC, cycle LIMIT 20
)
SELECT evidence.status AS evidence_status, evidence.reason AS evidence_reason,
       data.cycle, data.alloc_calls, data.alloc_bytes,
       data.alloc_bytes / 1024.0 AS alloc_kib,
       data.free_calls, data.free_bytes, data.free_bytes / 1024.0 AS free_kib,
       data.live_bytes, data.live_bytes / 1024.0 AS live_kib,
       data.peak_live_bytes, data.peak_live_bytes / 1024.0 AS peak_live_kib,
       data.update_alloc_calls, data.update_alloc_bytes,
       data.update_alloc_bytes / 1024.0 AS update_alloc_kib
FROM evidence LEFT JOIN data ON evidence.status = 'complete';
