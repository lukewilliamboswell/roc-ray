WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='hosted_effects'), data AS (
 SELECT name,count(*) calls,sum(value_a) inbound_copied_bytes,sum(outbound_copied_bytes) outbound_copied_bytes,sum(ownership_transfer_bytes) ownership_transfer_bytes FROM hosted_effects GROUP BY name)
SELECT evidence.status evidence_status,evidence.reason evidence_reason,data.* FROM evidence LEFT JOIN data ON evidence.status='complete' ORDER BY inbound_copied_bytes+outbound_copied_bytes DESC,name;
