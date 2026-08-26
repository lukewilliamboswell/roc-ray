WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='annotations'), data AS (
 SELECT name,phase,count(*) zone_count,sum(wall_ns) wall_ns,sum(active_ns) active_ns,sum(parked_ns) parked_ns,max(wall_ns) max_wall_ns FROM annotations WHERE kind IN (2,5) GROUP BY name,phase)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY max_wall_ns DESC,name;
