SELECT name,count(*) calls,sum(worker_ns) worker_ns,sum(external_ns) external_ns,
       sum(worker_ns IS NULL) unavailable_worker,sum(external_ns IS NULL) unavailable_external
FROM hosted_effects GROUP BY name ORDER BY name;
