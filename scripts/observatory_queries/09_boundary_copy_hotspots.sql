SELECT name,count(*) AS calls,sum(value_a) AS inbound_copied_bytes,sum(outbound_copied_bytes) AS outbound_copied_bytes,
       sum(ownership_transfer_bytes) AS ownership_transfer_bytes
FROM hosted_effects GROUP BY name ORDER BY inbound_copied_bytes+outbound_copied_bytes DESC,name;
