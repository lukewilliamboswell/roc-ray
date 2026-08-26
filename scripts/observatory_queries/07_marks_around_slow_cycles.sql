WITH slow AS (SELECT cycle FROM cycles ORDER BY duration_ns DESC LIMIT :limit)
SELECT a.cycle,a.timestamp_ns,a.name FROM annotations a JOIN slow USING(cycle) WHERE a.kind=0 ORDER BY a.cycle,a.timestamp_ns,a.id;
