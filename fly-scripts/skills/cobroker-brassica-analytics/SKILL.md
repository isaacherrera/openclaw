---
name: cobroker-brassica-analytics
description: >
  Query and analyze Brassica restaurant POS data. Sales trends, store comparisons,
  menu item analysis, and performance metrics across 6 Ohio locations (2023-2025).
  Use whenever the user asks about Brassica sales, revenue, menu items, or store performance.
user-invocable: true
metadata:
  openclaw:
    emoji: "📊"
---

# Brassica POS Analytics

Query a SQLite database with 5.3M transaction rows from 6 Brassica restaurant locations in Ohio (Jan 2023 – Sep 2025).

## How to Query

Use the `exec` tool to run Node.js one-liners. The database is read-only.

```
node -e "
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('/data/databases/brassica_pos.db', { readOnly: true });
const rows = db.prepare('YOUR SQL HERE LIMIT 100').all();
console.log(JSON.stringify(rows, null, 2));
db.close();
"
```

Replace `YOUR SQL HERE` with your query. Always include `LIMIT 100`.

## Schema Reference

### stores (6 rows)
- `id` TEXT PK — UUID
- `name` TEXT — store name
- `address` TEXT — full street address
- `latitude` REAL
- `longitude` REAL

### store_metrics (6 rows)
- `store_id` TEXT PK — FK to stores.id
- `median_income_10mi` REAL — median household income within 10 miles (only populated field)
- Other columns exist but are NULL: population_1mi, population_2mi, manufacturing_jobs_1mi, grocery_nearest_distance_mi, grocery_stores_within_4mi, grocery_score_pct, overall_score, rank

### item_sales (5.3M rows) — LARGE TABLE, always filter!
- `id` INTEGER PK — auto-increment
- `store_id` TEXT — FK to stores.id
- `location` TEXT — store name (denormalized)
- `business_date` DATE — format YYYY-MM-DD
- `check_id` TEXT — unique per transaction
- `master_department` TEXT — detailed category (16 values)
- `sale_department` TEXT — high-level category (8 values)
- `item_name` TEXT — menu item (171 distinct)
- `quantity` REAL
- `order_price` REAL — original price
- `bill_price` REAL — actual amount charged
- `comp_amount` REAL — comped amount
- `tax_amount` REAL
- `transaction_time` TEXT — format HH:MM:SS
- `modifiers` TEXT — nullable, item modifications
- `discount` TEXT — nullable, discount applied

### daily_sales (VIEW) — use for store-level aggregates, much faster than item_sales
- `store_id` TEXT
- `date` DATE
- `sales_amount` REAL — SUM(bill_price)
- `item_count` INTEGER — COUNT(*)
- `order_count` INTEGER — COUNT(DISTINCT check_id)

## Store Quick Reference

Use these IDs in WHERE clauses. Always display store names (not UUIDs) in responses.

- **Westlake** — `73d94728-2a71-4561-9254-558abd87521d` — 30070 Detroit Rd, Westlake, OH 44145 — Median income: $81,067
- **Easton** — `ebb3d31f-4602-4f36-b827-247ab3053753` — 4012 Townsfair Way, Columbus, OH 43219 — Median income: $75,999
- **Upper Arlington** — `e568f306-d5c9-4159-a7cd-e105db9ede37` — 1442 W Lane Ave, Upper Arlington, OH 43221 — Median income: $74,397
- **Bexley** — `12929e1d-f569-486e-be06-abf6b8a3f0f1` — 2212 E Main St, Bexley, OH 43209 — Median income: $67,646
- **Short North** — `dbaee129-6872-4223-9306-1a2097eb4abb` — 680 N High St, Columbus, OH 43215 — Median income: $69,803
- **Shaker Heights** — `4aff7a81-d586-4a92-922d-dde5d5fda855` — 20301 Meade Rd, Shaker Heights, OH 44122 — Median income: $58,936

## Departments

**master_department** (16 values): (Undefined), A la Carte, Beverages, Canned NA Beverages, Carryout / Online Ordering, Catering, Earth Day, Olo Items, Other, Pickles & Veggies, Plates Sides Extras & Kids, Retail, Sandwiches + Salads, Sauces & Dressing, Wine - Bottles, Wine - Glasses

**sale_department** (8 values): (Undefined), Beer, Beverages, Catering, Cocktails, Food, Retail / Other, Wine

## Performance Rules — CRITICAL

The `item_sales` table has 5.3M rows. Unfiltered queries WILL be slow or crash.

1. **ALWAYS** include a WHERE clause on `store_id` and/or `business_date` when querying `item_sales`
2. **Use `daily_sales` VIEW** for store-level revenue, order counts, and trends — it's pre-aggregated and fast
3. **Only use `item_sales`** when you need item-level, department-level, or check-level detail
4. **LIMIT 100** on every query, no exceptions
5. **Never SELECT *** from `item_sales` — always specify columns

## Common Query Patterns

### 1. Revenue trend (monthly) — use daily_sales VIEW
```sql
SELECT strftime('%Y-%m', date) AS month, ROUND(SUM(sales_amount), 2) AS revenue, SUM(order_count) AS orders
FROM daily_sales
WHERE store_id = '{store_id}'
GROUP BY month ORDER BY month LIMIT 100
```

### 2. Store comparison — daily_sales VIEW
```sql
SELECT s.name, ROUND(SUM(d.sales_amount), 2) AS revenue, SUM(d.order_count) AS orders
FROM daily_sales d JOIN stores s ON d.store_id = s.id
WHERE d.date BETWEEN '2025-01-01' AND '2025-06-30'
GROUP BY s.name ORDER BY revenue DESC
```

### 3. Top menu items by revenue — item_sales with filter
```sql
SELECT item_name, ROUND(SUM(bill_price), 2) AS revenue, SUM(quantity) AS qty
FROM item_sales
WHERE store_id = '{store_id}' AND business_date BETWEEN '2025-01-01' AND '2025-03-31'
GROUP BY item_name ORDER BY revenue DESC LIMIT 20
```

### 4. Year-over-year growth — daily_sales VIEW
```sql
SELECT strftime('%Y', date) AS year, ROUND(SUM(sales_amount), 2) AS revenue
FROM daily_sales
WHERE store_id = '{store_id}'
GROUP BY year ORDER BY year
```

### 5. Day-of-week patterns — daily_sales VIEW
```sql
SELECT CASE CAST(strftime('%w', date) AS INTEGER)
  WHEN 0 THEN 'Sun' WHEN 1 THEN 'Mon' WHEN 2 THEN 'Tue'
  WHEN 3 THEN 'Wed' WHEN 4 THEN 'Thu' WHEN 5 THEN 'Fri' WHEN 6 THEN 'Sat' END AS day,
  ROUND(AVG(sales_amount), 2) AS avg_daily_revenue, ROUND(AVG(order_count), 0) AS avg_orders
FROM daily_sales WHERE store_id = '{store_id}'
GROUP BY strftime('%w', date) ORDER BY strftime('%w', date)
```

### 6. Peak hours — item_sales with filter
```sql
SELECT SUBSTR(transaction_time, 1, 2) AS hour, COUNT(*) AS items_sold, ROUND(SUM(bill_price), 2) AS revenue
FROM item_sales
WHERE store_id = '{store_id}' AND business_date BETWEEN '2025-01-01' AND '2025-03-31'
GROUP BY hour ORDER BY hour LIMIT 24
```

### 7. Comp/discount analysis — item_sales with filter
```sql
SELECT item_name, COUNT(*) AS comp_count, ROUND(SUM(comp_amount), 2) AS total_comped
FROM item_sales
WHERE store_id = '{store_id}' AND comp_amount > 0 AND business_date >= '2025-01-01'
GROUP BY item_name ORDER BY total_comped DESC LIMIT 20
```

### 8. Department breakdown — item_sales with filter
```sql
SELECT sale_department, ROUND(SUM(bill_price), 2) AS revenue, COUNT(DISTINCT check_id) AS checks
FROM item_sales
WHERE store_id = '{store_id}' AND business_date BETWEEN '2025-01-01' AND '2025-06-30'
GROUP BY sale_department ORDER BY revenue DESC
```

## Formatting Rules

- Use **bullet or numbered lists only** — NO markdown tables (they break in Telegram)
- Always display **store names**, never UUIDs
- Round dollar amounts to **2 decimal places**, percentages to **1 decimal place**
- Format large numbers with commas (e.g., $1,234,567.89)
- **Summarize first**, then offer to show details
- **Max 20 items** per list — if more results exist, say "showing top 20" and offer to continue

## Constraints

- **SELECT only** — the database is read-only (3 layers: readOnly flag, chmod 444, these instructions)
- **Date range:** 2023-01-10 to 2025-09-09
- **171 distinct menu items**, 218K distinct checks, 5.3M item rows
- If a query returns no results, check the date range and store_id before saying "no data"
- When the user says "all stores" or doesn't specify a store, query across all stores but always break down results by store name
