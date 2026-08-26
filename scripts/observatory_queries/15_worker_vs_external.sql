WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='hosted_effects'), data AS (
 SELECT name,count(*) calls,sum(worker_ns) worker_ns,sum(external_ns) external_ns,sum(worker_ns IS NULL) unavailable_worker,sum(external_ns IS NULL) unavailable_external FROM hosted_effects GROUP BY name)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY name;
