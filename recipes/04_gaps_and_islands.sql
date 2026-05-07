-- Gaps and islands: group consecutive runs of events into sessions or streaks.
--
-- Problem shape:
--   You have a stream of events (logins, page views, daily activity).
--   Adjacent events within some threshold belong to the same session
--   (or streak, or contiguous block). Find the start and end of each.
--
-- The classic pattern: assign a group ID that increments only when the
-- gap to the previous event exceeds the threshold. Then GROUP BY that ID.
--
-- Where this comes up: web/app session reconstruction, login streaks,
-- contiguous activity windows (sleep tracking, employment history),
-- run-length compression of state changes.

CREATE OR REPLACE TABLE login_events (
    user_id INTEGER,
    logged_in_at TIMESTAMP
);

INSERT INTO login_events VALUES
    -- User 1: two sessions, separated by a 2-hour gap.
    (1, '2024-09-01 09:00:00'),
    (1, '2024-09-01 09:15:00'),
    (1, '2024-09-01 09:35:00'),
    (1, '2024-09-01 11:50:00'),  -- 2h 15m gap = new session
    (1, '2024-09-01 12:05:00'),
    -- User 2: one long session.
    (2, '2024-09-01 10:00:00'),
    (2, '2024-09-01 10:08:00'),
    (2, '2024-09-01 10:22:00'),
    (2, '2024-09-01 10:45:00');

-- Threshold: 30 minutes. Adjust to your business rule.
WITH gapped AS (
    SELECT
        user_id,
        logged_in_at,
        -- LAG returns NULL for the first event per user, which is what we want -
        -- the COALESCE makes the gap large enough to flag a new session.
        EXTRACT(EPOCH FROM (logged_in_at - LAG(logged_in_at) OVER (
            PARTITION BY user_id ORDER BY logged_in_at
        ))) / 60.0 AS minutes_since_prev
    FROM login_events
),
flagged AS (
    SELECT
        user_id,
        logged_in_at,
        -- The session boundary flag: 1 when this event starts a new session.
        CASE
            WHEN minutes_since_prev IS NULL OR minutes_since_prev > 30 THEN 1
            ELSE 0
        END AS is_new_session
    FROM gapped
),
sessioned AS (
    SELECT
        user_id,
        logged_in_at,
        -- Running sum of the boundary flag = session number per user.
        SUM(is_new_session) OVER (
            PARTITION BY user_id ORDER BY logged_in_at
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_num
    FROM flagged
)
SELECT
    user_id,
    session_num,
    MIN(logged_in_at) AS session_start,
    MAX(logged_in_at) AS session_end,
    COUNT(*)          AS event_count,
    EXTRACT(EPOCH FROM (MAX(logged_in_at) - MIN(logged_in_at))) / 60.0 AS duration_minutes
FROM sessioned
GROUP BY user_id, session_num
ORDER BY user_id, session_num;

-- Expected output:
--   user 1, session 1: 09:00-09:35, 3 events, 35 min
--   user 1, session 2: 11:50-12:05, 2 events, 15 min
--   user 2, session 1: 10:00-10:45, 4 events, 45 min
--
-- Variation: for daily-streak problems (consecutive calendar days), substitute
-- a date-difference of > 1 day as the gap condition.
