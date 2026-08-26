WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='queue_pressure'), data AS (
 SELECT name,sum(kind=2) saturation_events,max(value_a) high_water,max(parent_id) capacity,max(duration_ns) oldest_age_ns FROM queue_pressure GROUP BY name)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY saturation_events DESC,name;
