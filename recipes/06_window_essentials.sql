-- Window function essentials: the four patterns I use weekly.
--
-- These are not novel, but they're the ones engineers most often write
-- as subqueries when a window function would be one line. Window functions
-- don't collapse rows, so you keep the row-level grain while computing
-- partition-level aggregates.

CREATE OR REPLACE TABLE daily_revenue (
    region VARCHAR,
    revenue_date DATE,
    revenue_usd DECIMAL(10, 2)
);

INSERT INTO daily_revenue VALUES
    ('US', '2024-09-01', 1200.00),
    ('US', '2024-09-02', 1500.00),
    ('US', '2024-09-03', 1100.00),
    ('US', '2024-09-04', 1800.00),
    ('US', '2024-09-05', 1700.00),
    ('US', '2024-09-06', 2100.00),
    ('US', '2024-09-07', 1900.00),
    ('EU', '2024-09-01',  900.00),
    ('EU', '2024-09-02',  950.00),
    ('EU', '2024-09-03', 1050.00),
    ('EU', '2024-09-04', 1100.00),
    ('EU', '2024-09-05', 1150.00),
    ('EU', '2024-09-06', 1300.00),
    ('EU', '2024-09-07', 1250.00);

-- Pattern 1: running total. The frame ROWS BETWEEN UNBOUNDED PRECEDING
-- AND CURRENT ROW says "sum from the partition start up to this row."
-- PARTITION BY resets the running total per region.
SELECT
    region,
    revenue_date,
    revenue_usd,
    SUM(revenue_usd) OVER (
        PARTITION BY region
        ORDER BY revenue_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM daily_revenue
ORDER BY region, revenue_date;

-- Pattern 2: 3-day rolling average. The frame ROWS BETWEEN 2 PRECEDING
-- AND CURRENT ROW gives a trailing 3-row window. For a centered window
-- use 1 PRECEDING AND 1 FOLLOWING.
SELECT
    region,
    revenue_date,
    revenue_usd,
    AVG(revenue_usd) OVER (
        PARTITION BY region
        ORDER BY revenue_date
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    )::DECIMAL(10, 2) AS rolling_3day_avg
FROM daily_revenue
ORDER BY region, revenue_date;

-- Pattern 3: rank within partition. ROW_NUMBER assigns sequential numbers,
-- RANK leaves gaps after ties, DENSE_RANK does not. Pick by intent:
--   - "give me exactly one row per group" -> ROW_NUMBER (deterministic tie-break)
--   - "olympic medal style ranking" -> RANK
--   - "competition ranking, no skipped positions" -> DENSE_RANK
SELECT
    region,
    revenue_date,
    revenue_usd,
    ROW_NUMBER() OVER (PARTITION BY region ORDER BY revenue_usd DESC) AS row_num,
    RANK()       OVER (PARTITION BY region ORDER BY revenue_usd DESC) AS rnk,
    DENSE_RANK() OVER (PARTITION BY region ORDER BY revenue_usd DESC) AS dense_rnk
FROM daily_revenue
ORDER BY region, row_num;

-- Pattern 4: lead / lag for period-over-period deltas. LAG looks backward,
-- LEAD looks forward. NULL on the partition boundary; COALESCE if you
-- want zeros instead.
SELECT
    region,
    revenue_date,
    revenue_usd,
    LAG(revenue_usd, 1) OVER (PARTITION BY region ORDER BY revenue_date) AS prev_day,
    revenue_usd - LAG(revenue_usd, 1) OVER (PARTITION BY region ORDER BY revenue_date) AS day_over_day_change
FROM daily_revenue
ORDER BY region, revenue_date;

-- Notes:
--   - Frame defaults differ between RANGE (the spec default) and ROWS
--     (what you usually want). Always specify the frame explicitly when
--     using SUM / AVG / COUNT over a window.
--   - PARTITION BY without ORDER BY computes a single value across the
--     entire partition (useful for "row's share of partition total":
--     revenue_usd / SUM(revenue_usd) OVER (PARTITION BY region)).
--   - On Postgres, AVG returns numeric. On Snowflake / BigQuery it returns
--     float. Cast to DECIMAL when you need consistent rounding.
