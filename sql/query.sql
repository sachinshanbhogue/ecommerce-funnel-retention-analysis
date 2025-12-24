--------- data preparation and cleaning -------------------------------------------------------------------------------------------

select * from events_d
select count(*) from events
EXEC sp_help 'events';
SELECT event_type, COUNT(*) AS cnt
FROM events
GROUP BY event_type
ORDER BY cnt DESC;

SELECT
    user_id,
    product_id,
    event_time,
    event_type,
    user_session,
    COUNT(*) AS cnt
FROM events
GROUP BY user_id, product_id, event_time,event_type,user_session
HAVING COUNT(*) > 1;

---“The dataset contained empty strings instead of NULLs, so I standardized missing values by
--trimming whitespace and converting blanks to NULL to ensure accurate filtering and aggregation.”

SELECT
    SUM(CASE WHEN user_id IS NULL OR LTRIM(RTRIM(user_id)) = '' THEN 1 ELSE 0 END) AS blank_user,
    SUM(CASE WHEN event_time IS NULL OR LTRIM(RTRIM(event_time)) = '' THEN 1 ELSE 0 END) AS blank_time,
    SUM(CASE WHEN product_id IS NULL OR LTRIM(RTRIM(product_id)) = '' THEN 1 ELSE 0 END) AS blank_product,
    SUM(CASE WHEN category_id IS NULL OR LTRIM(RTRIM(category_id)) = '' THEN 1 ELSE 0 END) AS blank_category,
    SUM(CASE WHEN category_code IS NULL OR LTRIM(RTRIM(category_code)) = '' THEN 1 ELSE 0 END) AS blank_category_code,
    SUM(CASE WHEN event_type IS NULL OR LTRIM(RTRIM(event_type)) = '' THEN 1 ELSE 0 END) AS blank_event_type,
    SUM(CASE WHEN price IS NULL THEN 1 ELSE 0 END) AS null_price
FROM events;


UPDATE events
SET
    user_id = NULLIF(LTRIM(RTRIM(user_id)), ''),
    product_id = NULLIF(LTRIM(RTRIM(product_id)), ''),
    category_id = NULLIF(LTRIM(RTRIM(category_id)), ''),
    category_code = NULLIF(LTRIM(RTRIM(category_code)), ''),
    event_type = NULLIF(LTRIM(RTRIM(event_type)), ''),
    event_time = NULLIF(LTRIM(RTRIM(event_time)), '');


    WITH ranked_events AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY user_id, product_id, event_time, event_type, user_session
               ORDER BY event_time
           ) AS rn
    FROM events
)
SELECT
    user_id,
    event_type,
    product_id,
    category_id,
    category_code,
    price,
    event_time,
    brand,
    user_session
INTO events_d
FROM ranked_events
WHERE rn = 1;

ALTER TABLE events_d
ADD event_time_dt DATETIME;

UPDATE events_d
SET event_time_dt = TRY_CONVERT(
    DATETIME,
    REPLACE(event_time, ' UTC', ''),
    120
);

SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN event_time_dt IS NULL THEN 1 ELSE 0 END) AS failed_rows
FROM events_d;

ALTER TABLE events_d
ADD event_date DATE,event_hour INT;

UPDATE events_d
SET
    event_date = CAST(event_time_dt AS DATE),
    event_hour = DATEPART(HOUR, event_time_dt);


-----funnel analysis ----------------------------------------------------------------------------------------------------


WITH funnel_flags AS (
    SELECT
        user_id,
        MAX(CASE WHEN event_type = 'view' THEN 1 ELSE 0 END) AS viewed,
        MAX(CASE WHEN event_type = 'cart' THEN 1 ELSE 0 END) AS added_to_cart,
        MAX(CASE WHEN event_type = 'purchase' THEN 1 ELSE 0 END) AS purchased
    FROM events_d
    GROUP BY user_id
)
SELECT *
INTO user_funnel
FROM funnel_flags;

select * from user_funnel

SELECT
    COUNT(DISTINCT user_id) AS total_users,
    SUM(viewed) AS viewed_users,
    SUM(added_to_cart) AS cart_users,
    SUM(purchased) AS purchased_users
FROM user_funnel;

SELECT
    CAST(SUM(added_to_cart) * 1.0 / SUM(viewed) AS DECIMAL(5,2)) AS view_to_cart_rate,
    CAST(SUM(purchased) * 1.0 / SUM(added_to_cart) AS DECIMAL(5,2)) AS cart_to_purchase_rate,
    CAST(SUM(purchased) * 1.0 / SUM(viewed) AS DECIMAL(5,2)) AS view_to_purchase_rate
FROM user_funnel;

SELECT
    SUM(viewed) - SUM(added_to_cart) AS drop_after_view,
    SUM(added_to_cart) - SUM(purchased) AS drop_after_cart
FROM user_funnel;

----level 2----------

SELECT
    event_hour,
    COUNT(DISTINCT CASE WHEN event_type = 'view' THEN user_id END) AS viewers,
    COUNT(DISTINCT CASE WHEN event_type = 'purchase' THEN user_id END) AS purchasers
FROM events_d
GROUP BY event_hour
ORDER BY event_hour;


SELECT
    category_code,
    COUNT(DISTINCT CASE WHEN event_type = 'view' THEN user_id END) AS viewers,
    COUNT(DISTINCT CASE WHEN event_type = 'purchase' THEN user_id END) AS purchasers
FROM events_d
GROUP BY category_code
ORDER BY purchasers DESC;

WITH first_view AS (
    SELECT user_id, MIN(event_time_dt) AS first_view_time
    FROM events_d
    WHERE event_type = 'view'
    GROUP BY user_id
),
first_purchase AS (
    SELECT user_id, MIN(event_time_dt) AS first_purchase_time
    FROM events_d
    WHERE event_type = 'purchase'
    GROUP BY user_id
)
SELECT
    AVG(DATEDIFF(MINUTE, fv.first_view_time, fp.first_purchase_time)) AS avg_minutes_to_purchase
FROM first_view fv
JOIN first_purchase fp
ON fv.user_id = fp.user_id;

------------------------------------------------------------part 2 ---------------------------------------------------------
--retention analysis--------------------------------------------------------------------------------------------------------


-- Step 1: First purchase per user
WITH first_purchase AS (
    SELECT
        user_id,
        MIN(event_time_dt) AS first_purchase_date
    FROM events_d
    WHERE event_type = 'purchase'
    GROUP BY user_id
),

-- Step 2: Second (repeat) purchase per user
repeat_purchase AS (
    SELECT
        fp.user_id,
        MIN(e.event_time_dt) AS repeat_purchase_date,
        DATEDIFF(
            day,
            fp.first_purchase_date,
            MIN(e.event_time_dt)
        ) AS days_after
    FROM first_purchase fp
    JOIN events_d e
        ON fp.user_id = e.user_id
       AND e.event_type = 'purchase'
       AND e.event_time_dt > fp.first_purchase_date
    GROUP BY fp.user_id, fp.first_purchase_date
)

-- Step 3: Retention metrics (repeat purchase only)
SELECT
    (SELECT COUNT(*) FROM first_purchase) AS total_buyers,
    COUNT(CASE WHEN days_after <= 7 THEN 1 END) AS retained_7d,
    COUNT(CASE WHEN days_after <= 30 THEN 1 END) AS retained_30d,
    ROUND(
        1.0 * COUNT(CASE WHEN days_after <= 7 THEN 1 END)
        / (SELECT COUNT(*) FROM first_purchase), 2
    ) AS retention_7d_rate,
    ROUND(
        1.0 * COUNT(CASE WHEN days_after <= 30 THEN 1 END)
        / (SELECT COUNT(*) FROM first_purchase), 2
    ) AS retention_30d_rate
FROM repeat_purchase;


---category conversion chart

WITH category_funnel AS (
    SELECT
        category_code,
        COUNT(DISTINCT CASE WHEN event_type = 'view' THEN user_id END) AS viewers,
        COUNT(DISTINCT CASE WHEN event_type = 'purchase' THEN user_id END) AS purchasers
    FROM events_d
    WHERE category_code IS NOT NULL
    GROUP BY category_code
)
SELECT
    category_code,
    viewers,
    purchasers,
    CAST(purchasers * 1.0 / NULLIF(viewers, 0) AS DECIMAL(5,3)) AS conversion_rate
FROM category_funnel
WHERE viewers >= 1000   -- important: removes noisy tiny categories
ORDER BY conversion_rate DESC;

