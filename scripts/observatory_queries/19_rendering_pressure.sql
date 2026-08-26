WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='draw_observations'), data AS (
 SELECT cycle,sum(value_a) submitted_items,sum(value_b) secondary_count,sum(duration_ns) host_duration_ns FROM draw_summaries GROUP BY cycle)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY cycle;
