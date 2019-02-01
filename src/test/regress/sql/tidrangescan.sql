-- tests for tidrangescans

CREATE TABLE tidrangescan(id integer, data text);

INSERT INTO tidrangescan SELECT i,'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' FROM generate_series(1,1000) AS s(i);
DELETE FROM tidrangescan WHERE substring(ctid::text from ',(\d+)\)')::integer > 10 OR substring(ctid::text from '\((\d+),')::integer >= 10;;
VACUUM tidrangescan;

-- range scans with upper bound
EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan WHERE ctid < '(1, 0)';
SELECT ctid, data FROM tidrangescan WHERE ctid < '(1, 0)';

EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan WHERE ctid <= '(1, 5)';
SELECT ctid, data FROM tidrangescan WHERE ctid <= '(1, 5)';

EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan WHERE ctid < '(0, 0)';
SELECT ctid, data FROM tidrangescan WHERE ctid < '(0, 0)';

-- range scans with lower bound
EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan WHERE ctid > '(9, 8)';
SELECT ctid, data FROM tidrangescan WHERE ctid > '(9, 8)';

EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan WHERE ctid >= '(9, 8)';
SELECT ctid, data FROM tidrangescan WHERE ctid >= '(9, 8)';

EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan WHERE ctid >= '(100, 0)';
SELECT ctid, data FROM tidrangescan WHERE ctid >= '(100, 0)';

-- ordering with no quals should use tid range scan
EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan ORDER BY ctid ASC;

EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan ORDER BY ctid DESC;

-- min/max
EXPLAIN (COSTS OFF)
SELECT MIN(ctid) FROM tidrangescan;
SELECT MIN(ctid) FROM tidrangescan;

EXPLAIN (COSTS OFF)
SELECT MAX(ctid) FROM tidrangescan;
SELECT MAX(ctid) FROM tidrangescan;

EXPLAIN (COSTS OFF)
SELECT MIN(ctid) FROM tidrangescan WHERE ctid > '(5,0)';
SELECT MIN(ctid) FROM tidrangescan WHERE ctid > '(5,0)';

EXPLAIN (COSTS OFF)
SELECT MAX(ctid) FROM tidrangescan WHERE ctid < '(5,0)';
SELECT MAX(ctid) FROM tidrangescan WHERE ctid < '(5,0)';

-- empty table
CREATE TABLE tidrangescan_empty(id integer, data text);

EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan_empty WHERE ctid < '(1, 0)';
SELECT ctid, data FROM tidrangescan_empty WHERE ctid < '(1, 0)';

EXPLAIN (COSTS OFF)
SELECT ctid, data FROM tidrangescan_empty WHERE ctid > '(9, 0)';
SELECT ctid, data FROM tidrangescan_empty WHERE ctid > '(9, 0)';
