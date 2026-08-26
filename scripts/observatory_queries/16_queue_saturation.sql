SELECT name,sum(kind=2) saturation_events,max(value_a) high_water,max(parent_id) capacity,max(duration_ns) oldest_age_ns
FROM queue_pressure GROUP BY name ORDER BY saturation_events DESC,name;
