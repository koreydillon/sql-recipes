-- Snapshot resolution: pick the latest version of each (entity, span) across files.
--
-- Problem shape:
--   You receive periodic snapshot files (daily, weekly, monthly).
--   Each file is a full or near-full extract of current state.
--   Later files supersede earlier ones for any (entity, span) they include.
--   But they may also drop spans that have become fully historical.
--
-- The naive approach (use only the latest file) loses spans the supplier
-- silently dropped after termination. The correct approach: resolve each
-- (entity, span_start) at its latest reported version, keeping spans that
-- only appear in earlier files.
--
-- Where this comes up: insurance enrollment, employment history, lease
-- terms, anything with overlapping or contiguous date spans reported
-- across rolling snapshots.

CREATE OR REPLACE TABLE snapshots (
    file_received_date DATE,
    member_id INTEGER,
    enrollment_start DATE,
    enrollment_end DATE,
    plan_code VARCHAR
);

-- Three monthly snapshot files. Member 1 has the same span reported across
-- all three files (with a corrected end date in file 3). Member 2's span
-- gets dropped from file 3 (it terminated mid-2024). Member 3 only appears
-- in file 3 (joined late). All three should appear in the resolved output.
INSERT INTO snapshots VALUES
    -- File 1 (received 2024-02-01)
    ('2024-02-01', 1, '2024-01-01', '9999-12-31', 'GOLD'),
    ('2024-02-01', 2, '2023-06-01', '9999-12-31', 'SILVER'),

    -- File 2 (received 2024-05-01) - member 2 now shows a term date
    ('2024-05-01', 1, '2024-01-01', '9999-12-31', 'GOLD'),
    ('2024-05-01', 2, '2023-06-01', '2024-04-15', 'SILVER'),

    -- File 3 (received 2024-08-01) - member 2 dropped, member 1 corrected, member 3 added
    ('2024-08-01', 1, '2024-01-01', '2024-07-31', 'GOLD'),
    ('2024-08-01', 3, '2024-07-15', '9999-12-31', 'BRONZE');

-- The pattern: rank each (member_id, enrollment_start) by file date descending,
-- then keep rank 1. ROW_NUMBER beats RANK here because we want exactly one
-- winner even if a span is reported on multiple dates (deterministic tie-break).
WITH resolved AS (
    SELECT
        member_id,
        enrollment_start,
        enrollment_end,
        plan_code,
        file_received_date AS resolved_from_file,
        ROW_NUMBER() OVER (
            PARTITION BY member_id, enrollment_start
            ORDER BY file_received_date DESC
        ) AS rn
    FROM snapshots
)
SELECT
    member_id,
    enrollment_start,
    enrollment_end,
    plan_code,
    resolved_from_file
FROM resolved
WHERE rn = 1
ORDER BY member_id, enrollment_start;

-- Expected output:
--   1 | 2024-01-01 | 2024-07-31 | GOLD   | 2024-08-01  (corrected end date)
--   2 | 2023-06-01 | 2024-04-15 | SILVER | 2024-05-01  (preserved despite drop in file 3)
--   3 | 2024-07-15 | 9999-12-31 | BRONZE | 2024-08-01
