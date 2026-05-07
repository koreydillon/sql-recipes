-- Idempotent ingestion via content hash.
--
-- Problem shape:
--   You poll an external source and want to record what you saw.
--   The source can replay rows (network retry, manual re-pull, file dropped
--   twice). Re-ingesting the same logical row should be a no-op, not a
--   duplicate.
--
-- The pattern: stage every row with a content hash, then INSERT only the
-- hashes that don't already exist in the target. The target carries a
-- UNIQUE constraint on the hash so even concurrent loaders converge.
--
-- Where this comes up: webhook ingestion, file-drop pipelines, snapshot
-- pollers (the Klaviyo-style "build the change history the API doesn't
-- expose" pattern).

CREATE OR REPLACE TABLE event_log (
    event_hash VARCHAR PRIMARY KEY,
    event_id VARCHAR,
    user_id INTEGER,
    event_type VARCHAR,
    occurred_at TIMESTAMP,
    payload VARCHAR,
    first_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE TABLE staging_events (
    event_id VARCHAR,
    user_id INTEGER,
    event_type VARCHAR,
    occurred_at TIMESTAMP,
    payload VARCHAR
);

-- First poll: 3 events arrive.
INSERT INTO staging_events VALUES
    ('evt_001', 42, 'page_view',   '2024-09-01 10:00:00', '{"path":"/home"}'),
    ('evt_002', 42, 'click',       '2024-09-01 10:00:30', '{"button":"signup"}'),
    ('evt_003', 17, 'page_view',   '2024-09-01 10:01:00', '{"path":"/pricing"}');

-- The merge step. md5 is fine for dedup; sha256 if you need cryptographic
-- collision resistance. Concatenate fields with a separator that can't
-- appear in any field, or hash a JSON-serialized representation.
INSERT INTO event_log (event_hash, event_id, user_id, event_type, occurred_at, payload)
SELECT
    md5(event_id || '|' || user_id || '|' || event_type || '|' || occurred_at::VARCHAR || '|' || payload) AS event_hash,
    event_id,
    user_id,
    event_type,
    occurred_at,
    payload
FROM staging_events
WHERE NOT EXISTS (
    SELECT 1
    FROM event_log el
    WHERE el.event_hash = md5(staging_events.event_id || '|' || staging_events.user_id || '|' ||
                              staging_events.event_type || '|' || staging_events.occurred_at::VARCHAR || '|' ||
                              staging_events.payload)
);

-- Simulate a re-poll that returns the same 3 events plus 1 new one.
TRUNCATE staging_events;
INSERT INTO staging_events VALUES
    ('evt_001', 42, 'page_view',   '2024-09-01 10:00:00', '{"path":"/home"}'),     -- duplicate
    ('evt_002', 42, 'click',       '2024-09-01 10:00:30', '{"button":"signup"}'),  -- duplicate
    ('evt_003', 17, 'page_view',   '2024-09-01 10:01:00', '{"path":"/pricing"}'),  -- duplicate
    ('evt_004', 17, 'click',       '2024-09-01 10:01:20', '{"button":"buy"}');     -- new

INSERT INTO event_log (event_hash, event_id, user_id, event_type, occurred_at, payload)
SELECT
    md5(event_id || '|' || user_id || '|' || event_type || '|' || occurred_at::VARCHAR || '|' || payload),
    event_id, user_id, event_type, occurred_at, payload
FROM staging_events
WHERE NOT EXISTS (
    SELECT 1 FROM event_log el
    WHERE el.event_hash = md5(staging_events.event_id || '|' || staging_events.user_id || '|' ||
                              staging_events.event_type || '|' || staging_events.occurred_at::VARCHAR || '|' ||
                              staging_events.payload)
);

-- Verification: 4 distinct rows, no duplicates from the re-poll.
SELECT event_id, user_id, event_type, occurred_at FROM event_log ORDER BY occurred_at;

-- Expected: exactly 4 rows. The re-poll added evt_004 only.
--
-- Production notes:
--   - For warehouses without ON CONFLICT (Snowflake, BigQuery), MERGE is
--     the equivalent. Postgres has both ON CONFLICT and MERGE.
--   - DuckDB has INSERT OR IGNORE and ON CONFLICT DO NOTHING; either works
--     for this pattern and is shorter than the NOT EXISTS shape.
--   - Always include the source's own ID in the hash even if you also hash
--     content - it disambiguates legitimately-identical content (two
--     anonymous "page_view /home" events from the same user a second apart).
