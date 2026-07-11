-- ============================================================
-- VENDOR QUALITY & LOGISTICS SCORECARD — MySQL SCHEMA
-- Role of SQL in the pipeline: receive the cleaned data from
-- Python, enforce data integrity (keys), and serve one flat
-- analysis view (vw_fact_delivery) to Power BI / Tableau.
-- ============================================================

-- ------------------------------------------------------------
-- STEP 1: CREATE THE DATABASE
-- One dedicated database for the project; all 5 tables and the
-- analysis view live here.
-- ------------------------------------------------------------
CREATE DATABASE BRAZILIAN_ECOOMERCE;
USE BRAZILIAN_ECOOMERCE;
SHOW TABLES;

-- ------------------------------------------------------------
-- STEP 2: DIMENSION TABLE — SELLERS (who sold it)
-- seller_id is the PRIMARY KEY: one row per seller, and MySQL
-- now rejects any duplicate seller. city/state enable the
-- geographic analysis (state map, repeat rate by region).
-- ------------------------------------------------------------
CREATE TABLE sellers (
    seller_id VARCHAR(50) PRIMARY KEY,
    seller_zip_code_prefix INT,
    seller_city VARCHAR(100),
    seller_state VARCHAR(2)          -- 2-letter UF code (SP, RJ, MG...)
);

-- ------------------------------------------------------------
-- STEP 3: DIMENSION TABLE — PRODUCTS (what was sold)
-- product_category_name powers all category-level analysis.
-- Physical dimensions kept for freight analysis (nulls were
-- already filled with 0 in Python).
-- ------------------------------------------------------------
CREATE TABLE products (
    product_id VARCHAR(50) PRIMARY KEY,
    product_category_name VARCHAR(100),
    product_name_lenght INT,
    product_description_lenght INT,
    product_photos_qty INT,
    product_weight_g FLOAT,
    product_length_cm FLOAT,
    product_height_cm FLOAT,
    product_width_cm FLOAT
);

-- ------------------------------------------------------------
-- STEP 4: CORE TABLE — ORDERS (when it was bought & delivered)
-- Contains ONLY delivered orders (filtered in Python).
-- Includes the two engineered columns computed in pandas:
--   delivery_time_days = purchase -> customer door
--   sla_delay_days     = actual - promised (negative = early)
-- Storing them here means every downstream query/dashboard uses
-- identical logic — no re-deriving, no inconsistencies.
-- ------------------------------------------------------------
CREATE TABLE orders (
    order_id VARCHAR(50) PRIMARY KEY,
    customer_id VARCHAR(50),
    order_status VARCHAR(20),                 -- always 'delivered' here
    order_purchase_timestamp DATETIME,
    order_approved_at DATETIME,
    order_delivered_carrier_date DATETIME,    -- seller -> carrier handoff
    order_delivered_customer_date DATETIME,   -- carrier -> customer door
    order_estimated_delivery_date DATETIME,   -- the promise made at checkout
    delivery_time_days INT,                   -- engineered in Python
    sla_delay_days INT                        -- engineered in Python
);

-- ------------------------------------------------------------
-- STEP 5: FACT TABLE — ORDER_ITEMS (the money grain)
-- One row per item sold: the finest grain, where price, freight,
-- seller and product all meet. Composite PRIMARY KEY because an
-- order contains several items (order_id alone isn't unique).
-- FOREIGN KEYS guarantee referential integrity: an item can't
-- reference an order/product/seller that doesn't exist — this is
-- why Python loaded parents (sellers, products, orders) first.
-- ------------------------------------------------------------
CREATE TABLE order_items (
    order_id VARCHAR(50),
    order_item_id INT,
    product_id VARCHAR(50),
    seller_id VARCHAR(50),
    shipping_limit_date DATETIME,
    price FLOAT,                              -- revenue metric source
    freight_value FLOAT,                      -- shipping cost analysis
    PRIMARY KEY (order_id, order_item_id),    -- composite key
    FOREIGN KEY (order_id)  REFERENCES Orders(order_id),
    FOREIGN KEY (product_id) REFERENCES Products(product_id),
    FOREIGN KEY (seller_id) REFERENCES Sellers(seller_id)
);

-- ------------------------------------------------------------
-- STEP 6: ORDER_REVIEWS (the customer's verdict)
-- Deduplicated in Python: exactly one (latest) review per order,
-- so seller ratings never double-count a customer.
-- review_score (1-5) is the quality metric feeding the
-- Vendor Risk Score.
-- ------------------------------------------------------------
CREATE TABLE order_reviews (
    review_id VARCHAR(50),
    order_id VARCHAR(50),
    review_score INT,                         -- 1 (worst) to 5 (best)
    review_comment_title TEXT,
    review_comment_message TEXT,
    review_creation_date DATETIME,
    review_answer_timestamp DATETIME,
    PRIMARY KEY (review_id, order_id),        -- same review can span orders
    FOREIGN KEY (order_id) REFERENCES Orders(order_id)
);

-- ------------------------------------------------------------
-- STEP 7: THE ANALYSIS VIEW — vw_fact_delivery
-- Replaces Power Query: joins all 5 tables into ONE wide table,
-- one row per item sold, with price, seller, category, review
-- score and delivery delay side by side. Power BI loads only
-- this view. Note: Python did the FILTERING, this view does the
-- JOINING. LEFT JOIN on reviews = keep orders with no review
-- (they still count for revenue and delivery stats).
-- is_late converts the delay into a 1/0 flag for easy % math.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_fact_delivery AS
SELECT
    oi.order_id,
    oi.order_item_id,
    oi.seller_id,
    oi.product_id,
    oi.price,                                   -- revenue metric source
    oi.freight_value,                           -- shipping cost source
    o.order_purchase_timestamp,
    DATE(o.order_purchase_timestamp) AS purchase_date,   -- date-only, for trend axes
    o.delivery_time_days,                       -- engineered in Python
    o.sla_delay_days,                           -- engineered in Python (neg = early)
    CASE WHEN o.sla_delay_days > 0 THEN 1 ELSE 0 END AS is_late,  -- 1/0 flag for % math
    r.review_score,                             -- NULL if order was never reviewed
    s.seller_city,
    s.seller_state,                             -- powers the state map
    p.product_category_name                     -- powers category analysis
FROM order_items oi
JOIN orders o  ON o.order_id   = oi.order_id    -- inner: item must have a delivered order
JOIN sellers s ON s.seller_id  = oi.seller_id   -- attach seller geography
JOIN products p ON p.product_id = oi.product_id -- attach category
LEFT JOIN order_reviews r ON r.order_id = oi.order_id;
-- LEFT JOIN: an order without a review still counts for revenue
-- and delivery stats — its review_score is just NULL.



-- ============================================================
-- SELLER SCORECARD QUERY — the project's core deliverable
-- One row per seller: volume, delivery performance, and review
-- quality side by side. Answers: "which sellers are damaging
-- the platform through late deliveries and poor reviews?"
-- ============================================================
SELECT
    s.seller_id,
    s.seller_state,

    -- Volume: how many distinct orders this seller fulfilled.
    -- DISTINCT matters: the join is at ITEM level, so an order
    -- with 3 items appears as 3 rows — counting rows would
    -- inflate every seller's order count.
    COUNT(DISTINCT o.order_id) AS total_orders_fulfilled,

    -- Speed: average days from purchase to the customer's door
    ROUND(AVG(o.delivery_time_days), 1) AS avg_delivery_time_days,

    -- Reliability: % of ORDERS delivered past the promised date.
    -- Numerator counts DISTINCT late orders (not late item rows)
    -- so multi-item orders are not double-counted.
    ROUND(COUNT(DISTINCT CASE WHEN o.sla_delay_days > 0 THEN o.order_id END)
          / COUNT(DISTINCT o.order_id) * 100, 2) AS late_delivery_rate_pct,

    -- Quality: average review score (1-5) across the seller's orders
    ROUND(AVG(r.review_score), 2) AS avg_review_score,

    -- Worst-case quality: % of reviewed orders that got 1 star.
    -- Denominator = orders that HAVE a review (LEFT JOIN means
    -- some orders have none; they shouldn't dilute the rate).
    ROUND(COUNT(DISTINCT CASE WHEN r.review_score = 1 THEN r.order_id END)
          / COUNT(DISTINCT r.order_id) * 100, 2) AS one_star_rate_pct

FROM sellers s
JOIN order_items oi ON s.seller_id = oi.seller_id      -- seller -> their items sold
JOIN orders o       ON oi.order_id = o.order_id        -- item -> its delivery facts
LEFT JOIN order_reviews r ON o.order_id = r.order_id   -- LEFT: keep unreviewed orders

GROUP BY s.seller_id, s.seller_state                   -- one result row per seller

-- Volume floor: sellers with under 10 orders produce unstable
-- percentages (1 bad order = 50% late rate) — exclude them.
HAVING total_orders_fulfilled >= 10

-- Worst offenders first: most late, then lowest rated
ORDER BY late_delivery_rate_pct DESC, avg_review_score ASC;