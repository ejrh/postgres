-- tests for tidscans

CREATE TABLE tidscan(id integer);

-- only insert a few rows, we don't want to spill onto a second table page
INSERT INTO tidscan VALUES (1), (2), (3);

-- show ctids
SELECT ctid, * FROM tidscan;

-- ctid equality - implemented as tidscan
EXPLAIN (COSTS OFF)
SELECT ctid, * FROM tidscan WHERE ctid = '(0,1)';
SELECT ctid, * FROM tidscan WHERE ctid = '(0,1)';

EXPLAIN (COSTS OFF)
SELECT ctid, * FROM tidscan WHERE '(0,1)' = ctid;
SELECT ctid, * FROM tidscan WHERE '(0,1)' = ctid;

-- OR'd clauses
EXPLAIN (COSTS OFF)
SELECT ctid, * FROM tidscan WHERE ctid = '(0,2)' OR '(0,1)' = ctid;
SELECT ctid, * FROM tidscan WHERE ctid = '(0,2)' OR '(0,1)' = ctid;

-- ctid = ScalarArrayOp - implemented as tidscan
EXPLAIN (COSTS OFF)
SELECT ctid, * FROM tidscan WHERE ctid = ANY(ARRAY['(0,1)', '(0,2)']::tid[]);
SELECT ctid, * FROM tidscan WHERE ctid = ANY(ARRAY['(0,1)', '(0,2)']::tid[]);

-- ctid != ScalarArrayOp - can't be implemented as tidscan
EXPLAIN (COSTS OFF)
SELECT ctid, * FROM tidscan WHERE ctid != ANY(ARRAY['(0,1)', '(0,2)']::tid[]);
SELECT ctid, * FROM tidscan WHERE ctid != ANY(ARRAY['(0,1)', '(0,2)']::tid[]);

-- tid equality extracted from sub-AND clauses
EXPLAIN (COSTS OFF)
SELECT ctid, * FROM tidscan
WHERE (id = 3 AND ctid IN ('(0,2)', '(0,3)')) OR (ctid = '(0,1)' AND id = 1);
SELECT ctid, * FROM tidscan
WHERE (id = 3 AND ctid IN ('(0,2)', '(0,3)')) OR (ctid = '(0,1)' AND id = 1);

-- nestloop-with-inner-tidscan joins on tid
SET enable_hashjoin TO off;  -- otherwise hash join might win
EXPLAIN (COSTS OFF)
SELECT t1.ctid, t1.*, t2.ctid, t2.*
FROM tidscan t1 JOIN tidscan t2 ON t1.ctid = t2.ctid WHERE t1.id = 1;
SELECT t1.ctid, t1.*, t2.ctid, t2.*
FROM tidscan t1 JOIN tidscan t2 ON t1.ctid = t2.ctid WHERE t1.id = 1;
EXPLAIN (COSTS OFF)
SELECT t1.ctid, t1.*, t2.ctid, t2.*
FROM tidscan t1 LEFT JOIN tidscan t2 ON t1.ctid = t2.ctid WHERE t1.id = 1;
SELECT t1.ctid, t1.*, t2.ctid, t2.*
FROM tidscan t1 LEFT JOIN tidscan t2 ON t1.ctid = t2.ctid WHERE t1.id = 1;
RESET enable_hashjoin;

-- exercise backward scan and rewind
BEGIN;
DECLARE c CURSOR FOR
SELECT ctid, * FROM tidscan WHERE ctid = ANY(ARRAY['(0,1)', '(0,2)']::tid[]);
FETCH ALL FROM c;
FETCH BACKWARD 1 FROM c;
FETCH FIRST FROM c;
ROLLBACK;

-- tidscan via CURRENT OF
BEGIN;
DECLARE c CURSOR FOR SELECT ctid, * FROM tidscan;
FETCH NEXT FROM c; -- skip one row
FETCH NEXT FROM c;
-- perform update
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
UPDATE tidscan SET id = -id WHERE CURRENT OF c RETURNING *;
FETCH NEXT FROM c;
-- perform update
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
UPDATE tidscan SET id = -id WHERE CURRENT OF c RETURNING *;
SELECT * FROM tidscan;
-- position cursor past any rows
FETCH NEXT FROM c;
-- should error out
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
UPDATE tidscan SET id = -id WHERE CURRENT OF c RETURNING *;
ROLLBACK;

-- bulk joins on CTID
-- (these plans don't use TID scans, but this still seems like an
-- appropriate place for these tests)
EXPLAIN (COSTS OFF)
SELECT count(*) FROM tenk1 t1 JOIN tenk1 t2 ON t1.ctid = t2.ctid;
SELECT count(*) FROM tenk1 t1 JOIN tenk1 t2 ON t1.ctid = t2.ctid;
SET enable_hashjoin TO off;
EXPLAIN (COSTS OFF)
SELECT count(*) FROM tenk1 t1 JOIN tenk1 t2 ON t1.ctid = t2.ctid;
SELECT count(*) FROM tenk1 t1 JOIN tenk1 t2 ON t1.ctid = t2.ctid;
RESET enable_hashjoin;

DROP TABLE tidscan;

-- tests for tidrangescans

CREATE TABLE tidrangescan(id integer, data text);

INSERT INTO tidrangescan SELECT i,repeat('x', 100) FROM generate_series(1,1000) AS s(i);
DELETE FROM tidrangescan WHERE substring(ctid::text from ',(\d+)\)')::integer > 10 OR substring(ctid::text from '\((\d+),')::integer >= 10;;
VACUUM tidrangescan;

-- range scans with upper bound
EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE ctid < '(1,0)';
SELECT ctid FROM tidrangescan WHERE ctid < '(1,0)';

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE ctid <= '(1,5)';
SELECT ctid FROM tidrangescan WHERE ctid <= '(1,5)';

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE ctid < '(0,0)';
SELECT ctid FROM tidrangescan WHERE ctid < '(0,0)';

-- range scans with lower bound
EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE ctid > '(9,8)';
SELECT ctid FROM tidrangescan WHERE ctid > '(9,8)';

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE '(9,8)' < ctid;
SELECT ctid FROM tidrangescan WHERE '(9,8)' < ctid;

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE ctid >= '(9,8)';
SELECT ctid FROM tidrangescan WHERE ctid >= '(9,8)';

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE ctid >= '(100,0)';
SELECT ctid FROM tidrangescan WHERE ctid >= '(100,0)';

-- range scans with both bounds
EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE ctid > '(4,4)' AND '(4,7)' >= ctid;
SELECT ctid FROM tidrangescan WHERE ctid > '(4,4)' AND '(4,7)' >= ctid;

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE '(4,7)' >= ctid AND ctid > '(4,4)';
SELECT ctid FROM tidrangescan WHERE '(4,7)' >= ctid AND ctid > '(4,4)';

-- combinations
EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE '(4,7)' >= ctid AND ctid > '(4,4)' OR ctid = '(2,2)';
SELECT ctid FROM tidrangescan WHERE '(4,7)' >= ctid AND ctid > '(4,4)' OR ctid = '(2,2)';

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan WHERE '(4,7)' >= ctid AND ctid > '(4,4)' OR ctid = '(2,2)' AND data = 'foo';
SELECT ctid FROM tidrangescan WHERE '(4,7)' >= ctid AND ctid > '(4,4)' OR ctid = '(2,2)' AND data = 'foo';

-- extreme offsets
SELECT ctid FROM tidrangescan where ctid > '(0,65535)' AND ctid < '(1,0)' LIMIT 1;
SELECT ctid FROM tidrangescan where ctid < '(0,0)' LIMIT 1;

-- make sure ranges are combined correctly
SELECT COUNT(*) FROM tidrangescan WHERE ctid < '(0,3)' OR ctid >= '(0,2)' AND ctid <= '(0,5)';

SELECT COUNT(*) FROM tidrangescan WHERE ctid <= '(0,10)' OR ctid >= '(0,2)' AND ctid <= '(0,5)';

-- empty table
CREATE TABLE tidrangescan_empty(id integer, data text);

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan_empty WHERE ctid < '(1, 0)';
SELECT ctid FROM tidrangescan_empty WHERE ctid < '(1, 0)';

EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan_empty WHERE ctid > '(9, 0)';
SELECT ctid FROM tidrangescan_empty WHERE ctid > '(9, 0)';

-- check that ASC ordering on a tidscan doesn't require a sort
EXPLAIN (COSTS OFF)
SELECT ctid FROM tidscan WHERE ctid = ANY(ARRAY['(0,2)', '(0,1)', '(0,3)']::tid[]) ORDER BY ctid;
SELECT ctid FROM tidscan WHERE ctid = ANY(ARRAY['(0,2)', '(0,1)', '(0,3)']::tid[]) ORDER BY ctid;

-- ASC ordering with no quals should use tid range scan
EXPLAIN (COSTS OFF)
SELECT ctid FROM tidrangescan ORDER BY ctid ASC;

-- min/max
EXPLAIN (COSTS OFF)
SELECT MIN(ctid) FROM tidrangescan;
SELECT MIN(ctid) FROM tidrangescan;

EXPLAIN (COSTS OFF)
SELECT MIN(ctid) FROM tidrangescan WHERE ctid > '(5,0)';
SELECT MIN(ctid) FROM tidrangescan WHERE ctid > '(5,0)';

-- pathkeys can be usable for merge join?

EXPLAIN SELECT * FROM tidrangescan AS t1
INNER JOIN tidrangescan AS t2 ON t1.ctid = t2.ctid 
ORDER BY t1.ctid;
                                 QUERY PLAN
-----------------------------------------------------------------------------
 Merge Join  (cost=0.00..21.25 rows=300 width=14)
   Merge Cond: (t1.ctid = t2.ctid)
   ->  Tid Scan Backward on t1  (cost=0.00..8.00 rows=300 width=10)
   ->  Materialize  (cost=0.00..8.75 rows=300 width=10)
         ->  Tid Scan Backward on t1 t2  (cost=0.00..8.00 rows=300 width=10)
(5 rows)
-- clean up
DROP TABLE tidscan;
DROP TABLE tidrangescan;
