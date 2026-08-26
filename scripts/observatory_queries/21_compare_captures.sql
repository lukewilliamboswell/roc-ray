WITH b AS (SELECT avg(duration_ns) mean_ns,sum(alloc_bytes) alloc_bytes FROM before.cycles),
     a AS (SELECT avg(duration_ns) mean_ns,sum(alloc_bytes) alloc_bytes FROM after.cycles)
SELECT a.mean_ns-b.mean_ns AS mean_cycle_delta_ns,a.alloc_bytes-b.alloc_bytes AS allocation_delta_bytes FROM b,a;
