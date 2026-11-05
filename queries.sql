-- Product Catalog Data Quality Audit, Part 2: SQL analysis
-- Author: RoShawn Frazier
-- Database: SQLite. Tables:
--   products      one row per product (from outputs/product_master.csv)
--   transactions  one row per clean sales line (from outputs/clean_transactions.csv.gz)
-- Prices and revenue are in British pounds.

-- Q1. Catalog health overview: how many products need a description review?
SELECT COUNT(*)                                           AS total_products,
       SUM(needs_review)                                  AS needs_review,
       ROUND(100.0 * SUM(needs_review) / COUNT(*), 1)     AS pct_needs_review,
       MAX(description_variants)                          AS most_names_for_one_product
FROM products;

-- Q2. Products with the most conflicting names: where to start the cleanup
SELECT StockCode, canonical_description, description_variants, invoice_lines
FROM products
WHERE needs_review = 1
ORDER BY description_variants DESC, invoice_lines DESC
LIMIT 10;

-- Q3. Revenue tied to products with conflicting names: why the cleanup matters
SELECT p.needs_review,
       COUNT(DISTINCT p.StockCode)                                   AS products,
       ROUND(SUM(t.Revenue), 0)                                      AS revenue,
       ROUND(100.0 * SUM(t.Revenue) / (SELECT SUM(Revenue) FROM transactions), 1) AS pct_of_revenue
FROM transactions t
JOIN products p ON p.StockCode = t.StockCode
GROUP BY p.needs_review;

-- Q4. Top 10 products by revenue
SELECT p.StockCode, p.canonical_description,
       SUM(t.Quantity)            AS units_sold,
       ROUND(SUM(t.Revenue), 0)   AS revenue
FROM transactions t
JOIN products p ON p.StockCode = t.StockCode
GROUP BY p.StockCode, p.canonical_description
ORDER BY revenue DESC
LIMIT 10;

-- Q5. Pricing consistency: products whose highest price is 5x+ their lowest.
-- Some spread is normal (bulk discounts), but large gaps are worth checking for entry errors.
SELECT StockCode, canonical_description, min_price, median_price, max_price,
       ROUND(max_price / min_price, 1) AS price_ratio, invoice_lines
FROM products
WHERE max_price / min_price >= 5 AND invoice_lines >= 50
ORDER BY price_ratio DESC
LIMIT 10;

-- Q6. Inactive products: no sales in the last 6 months of data (candidates to retire from the catalog)
SELECT COUNT(*) AS inactive_products,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM products), 1) AS pct_of_catalog
FROM products
WHERE last_sold < DATE((SELECT MAX(InvoiceDate) FROM transactions), '-6 months');

-- Q7. Monthly revenue with month-over-month change (window function).
-- December 2011 is excluded because the data ends on Dec 9.
WITH monthly AS (
    SELECT STRFTIME('%Y-%m', InvoiceDate) AS month,
           ROUND(SUM(Revenue), 0)         AS revenue
    FROM transactions
    WHERE InvoiceDate < '2011-12-01'
    GROUP BY month
)
SELECT month, revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / LAG(revenue) OVER (ORDER BY month), 1) AS pct_change
FROM monthly
ORDER BY month;

-- Q8. Revenue by country (top 10), with each country's share
SELECT Country,
       COUNT(DISTINCT Invoice)    AS orders,
       ROUND(SUM(Revenue), 0)     AS revenue,
       ROUND(100.0 * SUM(Revenue) / (SELECT SUM(Revenue) FROM transactions), 1) AS pct_of_revenue
FROM transactions
GROUP BY Country
ORDER BY revenue DESC
LIMIT 10;

-- Q9. Best-selling product in each of the top 5 countries (window function: RANK)
WITH country_product AS (
    SELECT t.Country, p.canonical_description,
           SUM(t.Revenue) AS revenue,
           RANK() OVER (PARTITION BY t.Country ORDER BY SUM(t.Revenue) DESC) AS rnk
    FROM transactions t
    JOIN products p ON p.StockCode = t.StockCode
    GROUP BY t.Country, p.StockCode
),
top_countries AS (
    SELECT Country FROM transactions GROUP BY Country ORDER BY SUM(Revenue) DESC LIMIT 5
)
SELECT cp.Country, cp.canonical_description AS top_product, ROUND(cp.revenue, 0) AS revenue
FROM country_product cp
JOIN top_countries tc ON tc.Country = cp.Country
WHERE cp.rnk = 1
ORDER BY cp.revenue DESC;
