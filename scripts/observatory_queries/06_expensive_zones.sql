SELECT name,phase,count(*) AS zone_count,sum(wall_ns) AS wall_ns,sum(active_ns) AS active_ns,sum(parked_ns) AS parked_ns,max(wall_ns) AS max_wall_ns
FROM annotations WHERE kind IN (2,5) GROUP BY name,phase ORDER BY max_wall_ns DESC,name;
