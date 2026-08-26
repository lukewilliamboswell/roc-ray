WITH ranked AS (SELECT duration_ns,row_number() OVER(ORDER BY duration_ns) n,count(*) OVER() c FROM cycles)
SELECT max(CASE WHEN n=(c+1)/2 THEN duration_ns END) AS median_ns,
       max(CASE WHEN n=(c*95+99)/100 THEN duration_ns END) AS p95_ns,
       max(CASE WHEN n=(c*99+99)/100 THEN duration_ns END) AS p99_ns FROM ranked;
