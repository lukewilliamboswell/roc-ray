SELECT subject_id,name,max(CASE WHEN kind=3 THEN duration_ns END) destruction_delay_ns,max(value_b) heap_high_water
FROM resource_lifecycle GROUP BY subject_id,name ORDER BY destruction_delay_ns DESC,subject_id;
