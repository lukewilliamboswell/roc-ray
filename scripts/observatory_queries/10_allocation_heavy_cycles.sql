WITH evidence AS (SELECT status,reason FROM measurement_status WHERE name='allocation_counters')
SELECT evidence.status evidence_status,evidence.reason evidence_reason,cycle,alloc_calls,alloc_bytes,free_calls,free_bytes,live_bytes,peak_live_bytes FROM evidence LEFT JOIN cycles ON evidence.status='complete' ORDER BY alloc_bytes DESC,cycle;
