-- Multi-region zone configuration for the cluster.
-- Topology: 5 replicas, voters split 2/2/1 across us-central / us-east-1 / us-east-2.
-- Lease preference: us-central > us-east-1 > us-east-2.

ALTER DATABASE system CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 90000,
    num_replicas = 5,
    num_voters = 5;

ALTER RANGE default CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 14400,
    num_replicas = 5,
    num_voters = 5,
    constraints = '{+region=us-central: 2, +region=us-east-1: 2, +region=us-east-2: 1}',
    voter_constraints = '{+region=us-central: 2, +region=us-east-1: 2, +region=us-east-2: 1}',
    lease_preferences = '[[+region=us-central], [+region=us-east-1], [+region=us-east-2]]';

ALTER RANGE liveness CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 600,
    num_replicas = 5,
    num_voters = 5;

ALTER RANGE meta CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 3600,
    num_replicas = 5,
    num_voters = 5;

ALTER RANGE system CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 90000,
    num_replicas = 5,
    num_voters = 5;

ALTER RANGE timeseries CONFIGURE ZONE USING
    gc.ttlseconds = 14400;

-- TODO: the original ALTER TABLE statement here had its identifier rewritten
-- by an Antigena URL proxy (https://us01.l.antigena.com/...). Replace with the
-- real fully-qualified table name before applying.
-- ALTER TABLE <real.table.name> CONFIGURE ZONE USING
--     gc.ttlseconds = 3600;

ALTER TABLE system.public.replication_constraint_stats CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 600,
    num_replicas = 5,
    num_voters = 5;

ALTER TABLE system.public.replication_stats CONFIGURE ZONE USING
    range_min_bytes = 134217728,
    range_max_bytes = 536870912,
    gc.ttlseconds = 600,
    num_replicas = 5,
    num_voters = 5;

ALTER TABLE system.public.span_stats_tenant_boundaries CONFIGURE ZONE USING
    gc.ttlseconds = 3600;

ALTER TABLE system.public.statement_activity CONFIGURE ZONE USING
    gc.ttlseconds = 3600;

ALTER TABLE system.public.statement_statistics CONFIGURE ZONE USING
    gc.ttlseconds = 3600;

ALTER TABLE system.public.transaction_activity CONFIGURE ZONE USING
    gc.ttlseconds = 3600;

ALTER TABLE system.public.transaction_statistics CONFIGURE ZONE USING
    gc.ttlseconds = 3600;
