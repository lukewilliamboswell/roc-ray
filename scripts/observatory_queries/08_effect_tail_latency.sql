SELECT name,count(*) AS calls,avg(duration_ns) AS mean_ns,max(duration_ns) AS max_ns,sum(value_b<>0) AS non_success
FROM hosted_effects GROUP BY name ORDER BY max_ns DESC,name;
