SELECT m.name AS measurement,m.status,m.reason,m.rows_recorded,m.omitted_events,
       g.first_cycle,g.last_cycle,g.started_ns,g.ended_ns,g.producer_track
FROM measurement_status m
LEFT JOIN recording_gaps g ON g.family=m.family
ORDER BY CASE m.status WHEN 'partial' THEN 0 WHEN 'unfinalized' THEN 1 WHEN 'not_recorded' THEN 2 WHEN 'unavailable' THEN 3 ELSE 4 END,m.name,g.first_cycle;
