-- ============================================================
-- SETUP: Verify master table
-- ============================================================
SELECT COUNT(*) AS total_rows,
       MIN(order_purchase_timestamp) AS earliest_order,
       MAX(order_purchase_timestamp) AS latest_order,
       COUNT(DISTINCT customer_unique_id) AS unique_customers,
       COUNT(DISTINCT product_category_name_english) AS categories
FROM master_orders;


-- ============================================================
-- QUERY 1: Revenue by State with Window Ranking
-- ============================================================
SELECT
    customer_state,
    COUNT(DISTINCT order_id)                          AS total_orders,
    ROUND(SUM(total_payment_value)::NUMERIC, 2)       AS total_revenue,
    ROUND(AVG(total_payment_value)::NUMERIC, 2)       AS avg_order_value,
    RANK() OVER (ORDER BY SUM(total_payment_value) DESC)   AS revenue_rank,
    ROUND(
        (100.0 * SUM(total_payment_value) / SUM(SUM(total_payment_value)) OVER ())::NUMERIC,
        2
    )                                                 AS revenue_share_pct
FROM master_orders
WHERE total_payment_value IS NOT NULL
GROUP BY customer_state
ORDER BY revenue_rank;


-- ============================================================
-- QUERY 2: Repeat Customer Rate (CTE)
-- ============================================================
WITH order_counts AS (
    SELECT
        customer_unique_id,
        COUNT(DISTINCT order_id) AS total_orders
    FROM master_orders
    GROUP BY customer_unique_id
),
customer_segments AS (
    SELECT
        customer_unique_id,
        total_orders,
        CASE
            WHEN total_orders = 1 THEN 'one_time'
            WHEN total_orders BETWEEN 2 AND 3 THEN 'returning'
            ELSE 'loyal'
        END AS customer_type
    FROM order_counts
)
SELECT
    customer_type,
    COUNT(*) AS customer_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_customers
FROM customer_segments
GROUP BY customer_type
ORDER BY customer_count DESC;


-- ============================================================
-- QUERY 3: Delivery Delay Impact on Review Score
-- ============================================================
SELECT
    CASE
        WHEN delivery_delay_days IS NULL     THEN 'not_delivered'
        WHEN delivery_delay_days > 7         THEN 'very_late_7plus'
        WHEN delivery_delay_days > 0         THEN 'late_1to7'
        WHEN delivery_delay_days = 0         THEN 'on_time'
        ELSE 'early'
    END AS delivery_status,
    COUNT(*)                                          AS order_count,
    ROUND(AVG(review_score) FILTER (WHERE review_score > 0)::NUMERIC, 2) AS avg_review_score,
    ROUND(AVG(delivery_delay_days)::NUMERIC, 1)       AS avg_delay_days,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2
    )                                                 AS pct_of_orders
FROM master_orders
GROUP BY delivery_status
ORDER BY avg_review_score DESC NULLS LAST;


-- ============================================================
-- QUERY 4: Monthly Revenue Trend with MoM Growth
-- ============================================================
WITH monthly_revenue AS (
    SELECT
        order_year,
        order_month,
        order_yearmonth,
        ROUND(SUM(total_payment_value)::NUMERIC, 2) AS revenue,
        COUNT(DISTINCT order_id)                     AS orders
    FROM master_orders
    WHERE order_year IN (2017, 2018)
      AND total_payment_value IS NOT NULL
    GROUP BY order_year, order_month, order_yearmonth
)
SELECT
    order_yearmonth,
    order_year,
    order_month,
    revenue,
    orders,
    LAG(revenue) OVER (ORDER BY order_year, order_month) AS prev_month_revenue,
    ROUND(
        100.0 * (revenue - LAG(revenue) OVER (ORDER BY order_year, order_month)) /
        NULLIF(LAG(revenue) OVER (ORDER BY order_year, order_month), 0), 2
    ) AS mom_growth_pct
FROM monthly_revenue
ORDER BY order_year, order_month;


-- ============================================================
-- QUERY 5: Top 10 Product Categories by Revenue
-- ============================================================
SELECT
    product_category_name_english                         AS category,
    COUNT(DISTINCT order_id)                              AS total_orders,
    ROUND(SUM(total_payment_value)::NUMERIC, 2)           AS total_revenue,
    ROUND(AVG(total_payment_value)::NUMERIC, 2)           AS avg_order_value,
    ROUND(AVG(review_score) FILTER (WHERE review_score > 0)::NUMERIC, 2) AS avg_review,
    ROUND(AVG(delivery_delay_days)::NUMERIC, 1)           AS avg_delay_days,
    RANK() OVER (ORDER BY SUM(total_payment_value) DESC)  AS revenue_rank
FROM master_orders
WHERE product_category_name_english IS NOT NULL
GROUP BY product_category_name_english
ORDER BY revenue_rank
LIMIT 15;


-- ============================================================
-- QUERY 6: Average Order Value by Payment Type
-- ============================================================
SELECT
    primary_payment_type,
    COUNT(DISTINCT order_id)                            AS order_count,
    ROUND(SUM(total_payment_value)::NUMERIC, 2)         AS total_revenue,
    ROUND(AVG(total_payment_value)::NUMERIC, 2)         AS avg_order_value,
    ROUND(AVG(payment_installments)::NUMERIC, 1)        AS avg_installments,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2
    )                                                   AS usage_share_pct
FROM master_orders
WHERE primary_payment_type IS NOT NULL
GROUP BY primary_payment_type
ORDER BY total_revenue DESC;


-- ============================================================
-- QUERY 7: Seller Performance Ranking (Top 20)
-- ============================================================
WITH seller_metrics AS (
    SELECT
        seller_id,
        seller_state,
        COUNT(DISTINCT order_id)                             AS total_orders,
        ROUND(SUM(total_payment_value)::NUMERIC, 2)          AS total_revenue,
        ROUND(AVG(review_score) FILTER (WHERE review_score > 0)::NUMERIC, 2) AS avg_review,
        ROUND(AVG(delivery_delay_days)::NUMERIC, 1)          AS avg_delay,
        COUNT(DISTINCT product_category_name_english)        AS categories_sold
    FROM master_orders
    WHERE seller_id IS NOT NULL
    GROUP BY seller_id, seller_state
)
SELECT
    seller_id,
    seller_state,
    total_orders,
    total_revenue,
    avg_review,
    avg_delay,
    categories_sold,
    DENSE_RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank
FROM seller_metrics
ORDER BY revenue_rank
LIMIT 20;


-- ============================================================
-- QUERY 8: Customer Cohort Retention (by first purchase month)
-- ============================================================
WITH customer_first_order AS (
    SELECT
        customer_unique_id,
        TO_CHAR(MIN(order_purchase_timestamp), 'YYYY-MM') AS cohort_month
    FROM master_orders
    GROUP BY customer_unique_id
),
customer_orders AS (
    SELECT
        m.customer_unique_id,
        TO_CHAR(m.order_purchase_timestamp, 'YYYY-MM') AS order_month,
        cfo.cohort_month
    FROM master_orders m
    JOIN customer_first_order cfo USING (customer_unique_id)
)
SELECT
    cohort_month,
    order_month,
    COUNT(DISTINCT customer_unique_id) AS active_customers
FROM customer_orders
GROUP BY cohort_month, order_month
ORDER BY cohort_month, order_month
LIMIT 50;


-- ============================================================
-- QUERY 9: Order Value Distribution by Bucket
-- ============================================================
SELECT
    order_value_bucket,
    COUNT(*)                                         AS order_count,
    ROUND(AVG(total_payment_value)::NUMERIC, 2)      AS avg_value,
    ROUND(MIN(total_payment_value)::NUMERIC, 2)      AS min_value,
    ROUND(MAX(total_payment_value)::NUMERIC, 2)      AS max_value,
    ROUND((100.0 * COUNT(*) / SUM(COUNT(*)) OVER ())::NUMERIC, 2) AS pct_of_orders,
    ROUND((100.0 * SUM(total_payment_value) / SUM(SUM(total_payment_value)) OVER ())::NUMERIC, 2) AS pct_of_revenue
FROM master_orders
WHERE order_value_bucket != 'unknown'
GROUP BY order_value_bucket
ORDER BY avg_value;


-- ============================================================
-- QUERY 10: State-Level Delivery Performance
-- ============================================================
SELECT
    customer_state,
    COUNT(*)                                                    AS total_orders,
    COUNT(*) FILTER (WHERE is_on_time = 1)                      AS on_time_orders,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_on_time = 1) / COUNT(*), 2
    )                                                           AS on_time_pct,
    ROUND(AVG(delivery_delay_days) FILTER (WHERE delivery_delay_days IS NOT NULL)::NUMERIC, 1)
                                                                AS avg_delay_days,
    ROUND(AVG(actual_delivery_days) FILTER (WHERE actual_delivery_days IS NOT NULL)::NUMERIC, 1)
                                                                AS avg_actual_delivery_days,
    ROUND(AVG(review_score) FILTER (WHERE review_score > 0)::NUMERIC, 2)
                                                                AS avg_review
FROM master_orders
GROUP BY customer_state
HAVING COUNT(*) > 100
ORDER BY avg_delay_days DESC NULLS LAST;


-- ============================================================
-- QUERY 11: CREATE VIEW for Power BI (optional but clean)
-- ============================================================
CREATE OR REPLACE VIEW vw_bi_master AS
SELECT
    order_id,
    customer_unique_id,
    customer_state,
    customer_city,
    order_status,
    order_purchase_timestamp,
    order_delivered_customer_date,
    order_estimated_delivery_date,
    order_year,
    order_month,
    order_month_name,
    order_quarter,
    order_yearmonth,
    product_category_name_english AS product_category,
    primary_payment_type,
    total_payment_value,
    total_price,
    total_freight_value,
    item_count,
    payment_installments,
    review_score,
    has_review,
    review_category,
    delivery_delay_days,
    actual_delivery_days,
    is_on_time,
    order_value_bucket,
    seller_state
FROM master_orders
WHERE total_payment_value IS NOT NULL;

SELECT COUNT(*) FROM vw_bi_master;