-- Slowly Changing Dimension Type 2: keep history with valid_from / valid_to.
--
-- Problem shape:
--   A dimension attribute changes over time (a customer's plan, an
--   employee's department, an item's price). You need to answer
--   point-in-time questions: "what plan did this user have on 2024-03-15?"
--
-- SCD Type 2 keeps every version as its own row, with valid_from and
-- valid_to columns marking the lifetime of each version. The current
-- version has valid_to set to a sentinel (9999-12-31) so range
-- predicates work uniformly.
--
-- Where this comes up: anything where audit / point-in-time joins matter:
-- billing, compliance, A/B test attribution, employment records.

CREATE OR REPLACE TABLE customer_plan_history (
    customer_id INTEGER,
    plan_code VARCHAR,
    valid_from DATE,
    valid_to DATE,            -- '9999-12-31' = current
    is_current BOOLEAN
);

INSERT INTO customer_plan_history VALUES
    -- Customer 1: STARTER -> PRO -> ENTERPRISE
    (1, 'STARTER',    '2023-01-15', '2023-09-30', false),
    (1, 'PRO',        '2023-10-01', '2024-05-15', false),
    (1, 'ENTERPRISE', '2024-05-16', '9999-12-31', true),
    -- Customer 2: only ever PRO
    (2, 'PRO',        '2024-02-01', '9999-12-31', true);

-- Pattern 1: who has what plan right now? Trivial - filter on is_current.
SELECT customer_id, plan_code FROM customer_plan_history WHERE is_current;

-- Pattern 2: point-in-time lookup. What plan did each customer have on 2024-03-15?
SELECT customer_id, plan_code
FROM customer_plan_history
WHERE DATE '2024-03-15' BETWEEN valid_from AND valid_to
ORDER BY customer_id;
-- Expected: customer 1 = PRO, customer 2 = PRO

-- Pattern 3: applying a change. Customer 2 upgrades to ENTERPRISE today.
-- The update is two operations: close out the current row, insert the new one.
-- In production this should be one transaction.

UPDATE customer_plan_history
SET valid_to = DATE '2024-09-15' - INTERVAL '1 day',
    is_current = false
WHERE customer_id = 2 AND is_current;

INSERT INTO customer_plan_history VALUES
    (2, 'ENTERPRISE', '2024-09-15', '9999-12-31', true);

-- Pattern 4: point-in-time JOIN. Attribute revenue events to the plan
-- that was active when each event happened.
CREATE OR REPLACE TABLE revenue_events (
    event_id INTEGER,
    customer_id INTEGER,
    occurred_at DATE,
    amount_usd DECIMAL(10, 2)
);

INSERT INTO revenue_events VALUES
    (1, 1, '2023-06-01',  49.00),
    (2, 1, '2024-01-15',  99.00),
    (3, 1, '2024-08-01', 499.00),
    (4, 2, '2024-09-20', 499.00);

SELECT
    e.event_id,
    e.customer_id,
    e.occurred_at,
    e.amount_usd,
    h.plan_code AS plan_at_event_time
FROM revenue_events e
JOIN customer_plan_history h
  ON e.customer_id = h.customer_id
 AND e.occurred_at BETWEEN h.valid_from AND h.valid_to
ORDER BY e.event_id;

-- Expected: each event paired with the plan active on that date:
--   event 1 (2023-06-01, customer 1): STARTER
--   event 2 (2024-01-15, customer 1): PRO
--   event 3 (2024-08-01, customer 1): ENTERPRISE
--   event 4 (2024-09-20, customer 2): ENTERPRISE
--
-- Notes on this shape:
--   - Use the 9999-12-31 sentinel rather than NULL for valid_to so BETWEEN
--     works without a COALESCE on every join. NULL semantics in BETWEEN
--     differ across engines and hurt readability.
--   - The is_current boolean is denormalized but lets you filter without
--     comparing to the sentinel everywhere.
--   - Half-open intervals ([valid_from, valid_to)) are also a valid choice
--     and avoid a 1-day overlap if a customer changes plans on the same day.
--     Pick one and stick with it across all dimensions.
