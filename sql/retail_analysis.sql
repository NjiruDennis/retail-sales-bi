-- ============================================================
-- RETAIL SALES PERFORMANCE - SQL ANALYSIS
-- Database: retail_sales_dw (PostgreSQL 18)
-- Schema: Star Schema (fact_orders + 4 dimension tables)
-- Author: Dennis Njiru Aningu
-- ============================================================

-- ============================================================
-- QUERY 1: STAR SCHEMA VERIFICATION & OVERVIEW
-- ============================================================
SELECT
    COUNT(*)                            AS total_order_lines,
    COUNT(DISTINCT f.order_id)          AS unique_orders,
    COUNT(DISTINCT c.customer_id)       AS unique_customers,
    COUNT(DISTINCT p.product_id)        AS unique_products,
    COUNT(DISTINCT g.country)           AS countries,
    COUNT(DISTINCT g.region)            AS regions,
    MIN(d.order_date)                   AS earliest_order,
    MAX(d.order_date)                   AS latest_order,
    ROUND(SUM(f.sales)::NUMERIC, 2)     AS total_sales,
    ROUND(SUM(f.profit)::NUMERIC, 2)    AS total_profit,
    ROUND(AVG(f.sales)::NUMERIC, 2)     AS avg_order_line_value
FROM fact_orders f
JOIN dim_customers c ON f.customer_key = c.customer_key
JOIN dim_products  p ON f.product_key  = p.product_key
JOIN dim_geography g ON f.geo_key      = g.geo_key
JOIN dim_date      d ON f.date_key     = d.date_key;


-- ============================================================
-- QUERY 2: SALES & PROFIT BY MARKET AND REGION
-- WITH PROFIT MARGIN AND RANKING
-- ============================================================
WITH market_summary AS (
    SELECT
        g.market,
        g.region,
        COUNT(DISTINCT f.order_id)          AS total_orders,
        ROUND(SUM(f.sales)::NUMERIC, 2)     AS total_sales,
        ROUND(SUM(f.profit)::NUMERIC, 2)    AS total_profit,
        ROUND(AVG(f.sales)::NUMERIC, 2)     AS avg_order_value,
        COUNT(DISTINCT c.customer_id)       AS unique_customers
    FROM fact_orders f
    JOIN dim_customers  c ON f.customer_key = c.customer_key
    JOIN dim_geography  g ON f.geo_key      = g.geo_key
    GROUP BY g.market, g.region
)
SELECT
    market,
    region,
    total_orders,
    total_sales,
    total_profit,
    avg_order_value,
    unique_customers,
    ROUND(total_profit * 100.0 / NULLIF(total_sales, 0), 2)     AS profit_margin_pct,
    RANK() OVER (ORDER BY total_sales DESC)                      AS sales_rank,
    ROUND(total_sales * 100.0 / SUM(total_sales) OVER (), 2)    AS pct_of_total_sales
FROM market_summary
ORDER BY sales_rank;


-- ============================================================
-- QUERY 3: PRODUCT CATEGORY PERFORMANCE
-- WITH CONTRIBUTION AND PROFIT RANKING
-- ============================================================
WITH category_stats AS (
    SELECT
        p.category,
        p.sub_category,
        COUNT(DISTINCT f.order_id)          AS total_orders,
        SUM(f.quantity)                     AS total_units_sold,
        ROUND(SUM(f.sales)::NUMERIC, 2)     AS total_sales,
        ROUND(SUM(f.profit)::NUMERIC, 2)    AS total_profit,
        ROUND(AVG(f.discount)::NUMERIC, 4)  AS avg_discount
    FROM fact_orders f
    JOIN dim_products p ON f.product_key = p.product_key
    GROUP BY p.category, p.sub_category
),
ranked AS (
    SELECT *,
        ROUND(total_profit * 100.0 / NULLIF(total_sales, 0), 2) AS profit_margin_pct,
        RANK() OVER (PARTITION BY category ORDER BY total_profit DESC) AS rank_in_category,
        ROUND(total_sales * 100.0 / SUM(total_sales) OVER (), 2) AS pct_of_total_sales,
        ROUND(SUM(total_profit) OVER (ORDER BY total_profit DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)::NUMERIC, 2) AS running_profit_total
    FROM category_stats
)
SELECT
    category, sub_category, total_orders, total_units_sold,
    total_sales, total_profit, profit_margin_pct, avg_discount,
    rank_in_category, pct_of_total_sales, running_profit_total
FROM ranked
ORDER BY total_profit DESC;


-- ============================================================
-- QUERY 4: YEAR-OVER-YEAR SALES GROWTH
-- USING LAG FUNCTION
-- ============================================================
WITH yearly_sales AS (
    SELECT
        d.year,
        COUNT(DISTINCT f.order_id)          AS total_orders,
        COUNT(DISTINCT c.customer_id)       AS active_customers,
        ROUND(SUM(f.sales)::NUMERIC, 2)     AS total_sales,
        ROUND(SUM(f.profit)::NUMERIC, 2)    AS total_profit,
        ROUND(AVG(f.sales)::NUMERIC, 2)     AS avg_order_value
    FROM fact_orders f
    JOIN dim_date      d ON f.date_key      = d.date_key
    JOIN dim_customers c ON f.customer_key  = c.customer_key
    GROUP BY d.year
)
SELECT
    year,
    total_orders,
    active_customers,
    total_sales,
    total_profit,
    avg_order_value,
    ROUND(total_profit * 100.0 / NULLIF(total_sales, 0), 2)     AS profit_margin_pct,
    LAG(total_sales) OVER (ORDER BY year)                        AS prev_year_sales,
    ROUND((total_sales - LAG(total_sales) OVER (ORDER BY year)) * 100.0 /
        NULLIF(LAG(total_sales) OVER (ORDER BY year), 0), 2)    AS yoy_sales_growth_pct,
    ROUND((total_profit - LAG(total_profit) OVER (ORDER BY year)) * 100.0 /
        NULLIF(LAG(total_profit) OVER (ORDER BY year), 0), 2)   AS yoy_profit_growth_pct,
    CASE
        WHEN LAG(total_sales) OVER (ORDER BY year) IS NULL THEN 'Baseline Year'
        WHEN (total_sales - LAG(total_sales) OVER (ORDER BY year)) * 100.0 /
            NULLIF(LAG(total_sales) OVER (ORDER BY year), 0) > 20 THEN 'Strong Growth'
        WHEN (total_sales - LAG(total_sales) OVER (ORDER BY year)) * 100.0 /
            NULLIF(LAG(total_sales) OVER (ORDER BY year), 0) > 0  THEN 'Moderate Growth'
        ELSE 'Decline'
    END                                                          AS growth_flag
FROM yearly_sales
ORDER BY year;


-- ============================================================
-- QUERY 5: CUSTOMER SEGMENTATION & RFM ANALYSIS
-- RECENCY, FREQUENCY, MONETARY VALUE
-- ============================================================
WITH customer_metrics AS (
    SELECT
        c.customer_id,
        c.customer_name,
        c.segment,
        g.market,
        COUNT(DISTINCT f.order_id)              AS frequency,
        ROUND(SUM(f.sales)::NUMERIC, 2)         AS monetary_value,
        ROUND(AVG(f.sales)::NUMERIC, 2)         AS avg_order_value,
        ROUND(SUM(f.profit)::NUMERIC, 2)        AS total_profit,
        MAX(d.order_date)                       AS last_order_date,
        MIN(d.order_date)                       AS first_order_date,
        MAX(d.order_date) - MIN(d.order_date)   AS customer_lifespan_days
    FROM fact_orders f
    JOIN dim_customers c ON f.customer_key  = c.customer_key
    JOIN dim_geography g ON f.geo_key       = g.geo_key
    JOIN dim_date      d ON f.date_key      = d.date_key
    GROUP BY c.customer_id, c.customer_name, c.segment, g.market
),
rfm_scored AS (
    SELECT *,
        NTILE(4) OVER (ORDER BY last_order_date DESC)   AS recency_score,
        NTILE(4) OVER (ORDER BY frequency DESC)         AS frequency_score,
        NTILE(4) OVER (ORDER BY monetary_value DESC)    AS monetary_score
    FROM customer_metrics
)
SELECT
    customer_id, customer_name, segment, market,
    frequency, monetary_value, avg_order_value, total_profit,
    last_order_date, customer_lifespan_days,
    recency_score, frequency_score, monetary_score,
    (recency_score + frequency_score + monetary_score)  AS rfm_total,
    CASE
        WHEN (recency_score + frequency_score + monetary_score) >= 10 THEN 'Champion'
        WHEN (recency_score + frequency_score + monetary_score) >= 7  THEN 'Loyal Customer'
        WHEN (recency_score + frequency_score + monetary_score) >= 5  THEN 'Potential Loyalist'
        ELSE 'At Risk'
    END                                                 AS customer_segment
FROM rfm_scored
ORDER BY rfm_total DESC, monetary_value DESC
LIMIT 25;


-- ============================================================
-- QUERY 6: TOP 10 MOST PROFITABLE PRODUCTS
-- VS TOP 10 HIGHEST REVENUE PRODUCTS
-- ============================================================
WITH product_performance AS (
    SELECT
        p.product_id, p.product_name, p.category, p.sub_category,
        COUNT(DISTINCT f.order_id)          AS total_orders,
        SUM(f.quantity)                     AS units_sold,
        ROUND(SUM(f.sales)::NUMERIC, 2)     AS total_sales,
        ROUND(SUM(f.profit)::NUMERIC, 2)    AS total_profit,
        ROUND(AVG(f.discount)::NUMERIC, 4)  AS avg_discount
    FROM fact_orders f
    JOIN dim_products p ON f.product_key = p.product_key
    GROUP BY p.product_id, p.product_name, p.category, p.sub_category
),
ranked AS (
    SELECT *,
        ROUND(total_profit * 100.0 / NULLIF(total_sales, 0), 2) AS profit_margin_pct,
        RANK() OVER (ORDER BY total_profit DESC)                 AS profit_rank,
        RANK() OVER (ORDER BY total_sales DESC)                  AS revenue_rank
    FROM product_performance
)
SELECT
    profit_rank, revenue_rank, product_name, category, sub_category,
    total_orders, units_sold, total_sales, total_profit,
    profit_margin_pct, avg_discount,
    CASE
        WHEN profit_rank <= 10 AND revenue_rank <= 10 THEN 'Top Revenue AND Profit'
        WHEN profit_rank <= 10                        THEN 'Top Profit Only'
        WHEN revenue_rank <= 10                       THEN 'Top Revenue Only'
    END AS product_flag
FROM ranked
WHERE profit_rank <= 10 OR revenue_rank <= 10
ORDER BY profit_rank;


-- ============================================================
-- QUERY 7: DISCOUNT IMPACT ON PROFITABILITY
-- ============================================================
WITH discount_bands AS (
    SELECT
        CASE
            WHEN f.discount = 0     THEN '0% - No Discount'
            WHEN f.discount <= 0.10 THEN '1-10% Discount'
            WHEN f.discount <= 0.20 THEN '11-20% Discount'
            WHEN f.discount <= 0.30 THEN '21-30% Discount'
            WHEN f.discount <= 0.50 THEN '31-50% Discount'
            ELSE                         '50%+ Discount'
        END         AS discount_band,
        f.discount, f.sales, f.profit, f.quantity, p.category
    FROM fact_orders f
    JOIN dim_products p ON f.product_key = p.product_key
)
SELECT
    discount_band,
    COUNT(*)                                                    AS total_lines,
    ROUND(AVG(discount)::NUMERIC, 4)                            AS avg_discount,
    ROUND(SUM(sales)::NUMERIC, 2)                               AS total_sales,
    ROUND(SUM(profit)::NUMERIC, 2)                              AS total_profit,
    ROUND(AVG(profit)::NUMERIC, 2)                              AS avg_profit_per_line,
    ROUND(SUM(profit) * 100.0 / NULLIF(SUM(sales), 0)::NUMERIC, 2) AS profit_margin_pct,
    ROUND(AVG(quantity)::NUMERIC, 2)                            AS avg_quantity,
    CASE
        WHEN SUM(profit) < 0 THEN 'Loss Making'
        WHEN SUM(profit) * 100.0 / NULLIF(SUM(sales), 0) < 5   THEN 'Low Margin'
        WHEN SUM(profit) * 100.0 / NULLIF(SUM(sales), 0) < 15  THEN 'Healthy Margin'
        ELSE 'High Margin'
    END                                                         AS margin_flag
FROM discount_bands
GROUP BY discount_band
ORDER BY avg_discount;


-- ============================================================
-- QUERY 8: MONTHLY SALES TREND WITH 3-MONTH MOVING AVERAGE
-- ============================================================
WITH monthly_sales AS (
    SELECT
        d.year, d.month, d.month_name,
        TO_CHAR(DATE_TRUNC('month', d.order_date), 'YYYY-MM') AS year_month,
        COUNT(DISTINCT f.order_id)              AS total_orders,
        ROUND(SUM(f.sales)::NUMERIC, 2)         AS total_sales,
        ROUND(SUM(f.profit)::NUMERIC, 2)        AS total_profit,
        COUNT(DISTINCT c.customer_id)           AS active_customers
    FROM fact_orders f
    JOIN dim_date      d ON f.date_key      = d.date_key
    JOIN dim_customers c ON f.customer_key  = c.customer_key
    GROUP BY d.year, d.month, d.month_name, DATE_TRUNC('month', d.order_date)
)
SELECT
    year_month, year, month_name, total_orders,
    total_sales, total_profit, active_customers,
    ROUND(total_profit * 100.0 / NULLIF(total_sales, 0)::NUMERIC, 2)   AS profit_margin_pct,
    ROUND(AVG(total_sales) OVER (
        ORDER BY year, month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)::NUMERIC, 2)         AS moving_avg_3m,
    LAG(total_sales) OVER (ORDER BY year, month)                        AS prev_month_sales,
    ROUND((total_sales - LAG(total_sales) OVER (ORDER BY year, month)) * 100.0 /
        NULLIF(LAG(total_sales) OVER (ORDER BY year, month), 0)::NUMERIC, 2) AS mom_growth_pct
FROM monthly_sales
ORDER BY year, month;