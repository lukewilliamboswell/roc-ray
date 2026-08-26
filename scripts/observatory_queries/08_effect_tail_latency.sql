WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='hosted_effects'), data AS (
 SELECT name,count(*) calls,avg(duration_ns) mean_ns,max(duration_ns) max_ns,sum(value_b<>0) non_success FROM hosted_effects GROUP BY name)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY max_ns DESC,name;
