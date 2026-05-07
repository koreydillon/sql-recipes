-- Member-month expansion: turn date spans into per-month rows.
--
-- Problem shape:
--   You have one row per (member, enrollment span). You need one row per
--   (member, month) for any month the member was enrolled at least one day.
--   Coverage gaps must produce no row for the gap months.
--
-- Where this comes up: enrollment / member-month rosters for healthcare
-- and insurance, subscription billing, anything where you bill per month
-- of active service.
--
-- Common bug: cross-joining members with all months produces rows for
-- non-enrolled members. The right shape filters by overlap with each
-- member's actual spans.

CREATE OR REPLACE TABLE enrollments (
    member_id INTEGER,
    enrollment_start DATE,
    enrollment_end DATE  -- 9999-12-31 means 'still enrolled'
);

INSERT INTO enrollments VALUES
    (1, '2024-01-15', '2024-04-15'),  -- Jan-Apr 2024
    (1, '2024-08-01', '2024-12-31'),  -- gap May-Jul, then Aug-Dec
    (2, '2024-03-01', '9999-12-31'),  -- Mar 2024 onwards, still active
    (3, '2024-06-15', '2024-06-20');  -- single-month, partial overlap

-- Pattern: generate the universe of months once, then INNER JOIN against
-- each enrollment span on month-level overlap. The overlap test is the
-- standard span-intersection: span starts on or before month end, AND
-- span ends on or after month start.
WITH months AS (
    -- Substitute generate_series for your warehouse:
    --   Postgres:  generate_series(...)::date
    --   Snowflake: dateadd via TABLE(GENERATOR(...))
    --   BigQuery:  GENERATE_DATE_ARRAY(...)
    SELECT date_trunc('month', d)::DATE AS month_start
    FROM generate_series(DATE '2024-01-01', DATE '2024-12-01', INTERVAL '1 month') AS t(d)
),
member_months AS (
    SELECT
        e.member_id,
        m.month_start,
        (m.month_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS month_end
    FROM enrollments e
    JOIN months m
      ON e.enrollment_start <= (m.month_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE
     AND e.enrollment_end   >= m.month_start
)
SELECT
    member_id,
    -- YYYYMM integer is the conventional output shape for member-months.
    CAST(strftime(month_start, '%Y%m') AS INTEGER) AS yearmonth,
    month_start,
    month_end
FROM member_months
ORDER BY member_id, month_start;

-- Expected output:
--   Member 1: 202401, 202402, 202403, 202404 (gap), 202408..202412
--   Member 2: 202403..202412 (10 months, still active)
--   Member 3: 202406 only
--
-- Note: a 1-day overlap counts as a full month, which is the conventional
-- billing rule. If your business rule is different (e.g. mid-month start
-- counts as half), apply it as a derived column on the final result.
