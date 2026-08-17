-- =====================================================================
-- Pharma Sales Territory & Rep Performance Analysis
-- Author: Hrishika Jain
-- Tool: MySQL 8.0
-- Dataset: reps (50 rows), accounts (620 rows) -- see accounts.csv / reps.csv
--
-- PIPELINE (2 stages, both scripts included in this project folder):
--   1. generate_data.py       -> produces reps.csv, accounts.csv with original_rep_id
--   2. rebalance_algorithm.py -> reads that, produces rebalanced_rep_id
-- The queries below MEASURE the before/after; they do not perform the rebalance --
-- that logic lives in rebalance_algorithm.py, documented and independently reproducible
-- (100% match against the shipped accounts.csv when re-run).
--
-- NOTE on capacity=12: this is an ASSERTED modeling parameter, not empirically derived
-- from real call-frequency data (a real derivation would use calls/day x selling days /
-- target call frequency per account -- for a primary-care model that lands closer to
-- ~100-150 accounts/rep; 12 is more consistent with a key-account/specialty model on
-- this dataset's scale). No sensitivity analysis was run varying this parameter.
-- =====================================================================

-- 1. SCHEMA -----------------------------------------------------------
CREATE TABLE reps (
    rep_id     INT PRIMARY KEY,
    rep_name   VARCHAR(20),
    region     VARCHAR(20)
);

CREATE TABLE accounts (
    account_id          VARCHAR(10) PRIMARY KEY,
    region              VARCHAR(20),
    revenue_potential   INT,
    original_rep_id     INT,
    rebalanced_rep_id   INT,
    FOREIGN KEY (original_rep_id)   REFERENCES reps(rep_id),
    FOREIGN KEY (rebalanced_rep_id) REFERENCES reps(rep_id)
);

-- Load data: LOAD DATA INFILE 'accounts.csv' INTO TABLE accounts ...
-- (or import via MySQL Workbench's Table Data Import Wizard)


-- 2. WORKLOAD PER REP -- BEFORE (original assignment) -----------------
SELECT
    r.rep_id,
    r.rep_name,
    r.region,
    COUNT(a.account_id)            AS account_count,
    SUM(a.revenue_potential)       AS total_revenue_potential
FROM reps r
LEFT JOIN accounts a ON a.original_rep_id = r.rep_id
GROUP BY r.rep_id, r.rep_name, r.region
ORDER BY total_revenue_potential DESC;


-- 3. WORKLOAD PER REP -- AFTER (rebalanced assignment) -----------------
SELECT
    r.rep_id,
    r.rep_name,
    r.region,
    COUNT(a.account_id)            AS account_count,
    SUM(a.revenue_potential)       AS total_revenue_potential
FROM reps r
LEFT JOIN accounts a ON a.rebalanced_rep_id = r.rep_id
GROUP BY r.rep_id, r.rep_name, r.region
ORDER BY total_revenue_potential DESC;


-- 4. WORKLOAD IMBALANCE (BEFORE vs AFTER) -- variance / std dev --------
-- MySQL 8.0 supports VARIANCE()/STDDEV() as native aggregate functions.
SELECT 'BEFORE' AS scenario,
       AVG(rev_by_rep.total_revenue_potential)      AS avg_workload,
       STDDEV(rev_by_rep.total_revenue_potential)    AS stddev_workload
FROM (
    SELECT original_rep_id AS rep_id, SUM(revenue_potential) AS total_revenue_potential
    FROM accounts
    GROUP BY original_rep_id
) AS rev_by_rep

UNION ALL

SELECT 'AFTER' AS scenario,
       AVG(rev_by_rep.total_revenue_potential)      AS avg_workload,
       STDDEV(rev_by_rep.total_revenue_potential)    AS stddev_workload
FROM (
    SELECT rebalanced_rep_id AS rep_id, SUM(revenue_potential) AS total_revenue_potential
    FROM accounts
    GROUP BY rebalanced_rep_id
) AS rev_by_rep;

-- Result (this dataset): BEFORE stddev = 46,105 | AFTER stddev = 28,419
-- => ~38% reduction in workload variance after rebalancing.


-- 5. ACCOUNT-VALUE SEGMENTATION -- rank accounts into quartiles --------
-- (used to decide which accounts move during rebalancing)
SELECT
    account_id,
    region,
    revenue_potential,
    NTILE(4) OVER (PARTITION BY region ORDER BY revenue_potential DESC) AS value_quartile
FROM accounts
ORDER BY region, value_quartile;


-- 6. REPS OVER CAPACITY (workload > 12 accounts) -- BEFORE vs AFTER ----
-- Capacity threshold of 12 accounts models the point at which call
-- frequency / attention per account starts to dilute.
SELECT
    'BEFORE' AS scenario,
    SUM(CASE WHEN account_count > 12 THEN 1 ELSE 0 END) AS reps_over_capacity
FROM (
    SELECT original_rep_id AS rep_id, COUNT(*) AS account_count
    FROM accounts GROUP BY original_rep_id
) t

UNION ALL

SELECT
    'AFTER' AS scenario,
    SUM(CASE WHEN account_count > 12 THEN 1 ELSE 0 END) AS reps_over_capacity
FROM (
    SELECT rebalanced_rep_id AS rep_id, COUNT(*) AS account_count
    FROM accounts GROUP BY rebalanced_rep_id
) t;

-- Result (this dataset): BEFORE = 19 reps over capacity | AFTER = 24 reps over capacity.
-- This is the ONE metric that moves the wrong direction -- and it looks bad in isolation.
-- Resolution (see query 6b): it's a blind count-over-threshold metric. It scores a rep
-- with 13 accounts the same as a rep with 24, even though the revenue impact of those
-- two situations is completely different. Total excess load (6b) and captured revenue
-- (query 7) are the metrics that actually matter, and both improve substantially --
-- because the capture penalty (query 7) is convex, so spreading overload thin across
-- more reps is strictly better than leaving it concentrated on a few, even though the
-- raw headcount-over-threshold goes up.


-- 6b. TOTAL EXCESS LOAD -- the metric that resolves the query-6 paradox ---------------
-- Sum of (account_count - 12) for every rep who is over capacity. Unlike query 6,
-- this is sensitive to MAGNITUDE, not just headcount over the line.
SELECT
    'BEFORE' AS scenario,
    SUM(CASE WHEN account_count > 12 THEN account_count - 12 ELSE 0 END) AS total_excess_accounts,
    MAX(account_count) AS heaviest_rep_load
FROM (
    SELECT original_rep_id AS rep_id, COUNT(*) AS account_count
    FROM accounts GROUP BY original_rep_id
) t

UNION ALL

SELECT
    'AFTER' AS scenario,
    SUM(CASE WHEN account_count > 12 THEN account_count - 12 ELSE 0 END) AS total_excess_accounts,
    MAX(account_count) AS heaviest_rep_load
FROM (
    SELECT rebalanced_rep_id AS rep_id, COUNT(*) AS account_count
    FROM accounts GROUP BY rebalanced_rep_id
) t;

-- Result: BEFORE total excess = 112 accounts, heaviest rep = 24
--         AFTER  total excess = 43 accounts,  heaviest rep = 19
-- => 62% reduction in total excess load, and the single worst-loaded rep drops by 21%.
-- This is the real story: rebalancing traded a few catastrophically overloaded reps for
-- more, but mildly, overloaded reps -- a strict improvement once the penalty is convex.


-- 7. PROJECTED QUOTA ATTAINMENT / CAPTURED REVENUE ----------------------
-- Effective capture rate = capacity / account_count when a rep is over
-- capacity (attention dilution), else 1.0 (full capture).
SELECT
    scenario,
    SUM(revenue_potential * capture_rate) AS captured_revenue,
    SUM(revenue_potential)                AS total_potential,
    ROUND(SUM(revenue_potential * capture_rate) / SUM(revenue_potential) * 100, 1) AS pct_of_potential_captured
FROM (
    SELECT 'BEFORE' AS scenario, a.revenue_potential,
           LEAST(1.0, 12.0 / t.account_count) AS capture_rate
    FROM accounts a
    JOIN (SELECT original_rep_id, COUNT(*) AS account_count FROM accounts GROUP BY original_rep_id) t
      ON a.original_rep_id = t.original_rep_id

    UNION ALL

    SELECT 'AFTER' AS scenario, a.revenue_potential,
           LEAST(1.0, 12.0 / t.account_count) AS capture_rate
    FROM accounts a
    JOIN (SELECT rebalanced_rep_id, COUNT(*) AS account_count FROM accounts GROUP BY rebalanced_rep_id) t
      ON a.rebalanced_rep_id = t.rebalanced_rep_id
) x
GROUP BY scenario;

-- Result (this dataset): BEFORE = 82.6% of potential captured
--                         AFTER  = 93.1% of potential captured
-- => ~13% projected uplift in effective quota attainment.
