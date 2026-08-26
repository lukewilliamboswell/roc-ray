SELECT CAST((SELECT value FROM metadata WHERE key='schema_version') AS INTEGER) AS schema_version,
       CAST((SELECT value FROM metadata WHERE key='clean_shutdown') AS INTEGER) AS clean_shutdown,
       (SELECT value FROM metadata WHERE key='final_state') AS final_state,
       (SELECT coalesce(sum(lost_count),0) FROM recording_gaps) AS omitted_events,
       (SELECT writer_failed FROM recorder_health WHERE id=1) AS writer_failed,
       (SELECT count(*) FROM measurement_status WHERE status<>'complete' AND status<>'unavailable') AS incomplete_measurements;
