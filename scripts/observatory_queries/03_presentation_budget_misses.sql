WITH pacing AS (SELECT value_b AS fps FROM gpu_facts WHERE kind=2 AND name='host_fps_cap' AND value_b>0 LIMIT 1)
SELECT CASE WHEN EXISTS(SELECT 1 FROM pacing) THEN 1 ELSE 0 END AS available,
       CASE WHEN EXISTS(SELECT 1 FROM pacing) THEN (SELECT count(*) FROM cycles,pacing WHERE duration_ns>1000000000/fps) END AS missed_cycles;
