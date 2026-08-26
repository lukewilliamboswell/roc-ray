SELECT cycle,sum(value_a) submitted_items,sum(value_b) secondary_count,sum(duration_ns) host_duration_ns
FROM draw_summaries GROUP BY cycle ORDER BY cycle;
