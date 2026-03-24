---
name: cobroker-brassica-toast
description: >
  Query live Toast POS data for Brassica, Northstar Cafe, and Third & Hollywood restaurants.
  Use when the user asks about sales, orders, menus, employees, labor, hours, stock, cash drawer,
  or any operational data for Brassica, Northstar, Third & Hollywood, Harpers Station, Upper Arlington,
  Easton, Westlake, Hunters Creek, Shaker Heights, Bexley, Keystone Crossing, Short North, Westerville,
  Liberty Center, Kenwood, Beechwold, or Grandview locations.
requires.env:
  - TOAST_CLIENT_ID
  - TOAST_CLIENT_SECRET
user-invocable: true
metadata:
  openclaw:
    emoji: "🍽️"
---

# Toast POS — Live Restaurant Data

Query the live Toast POS API for 17 restaurants across 3 brands: **Brassica** (9), **Northstar Cafe** (7), and **Third & Hollywood** (1).

## 1. Authentication

Get a Bearer token (cached ~17h). Run this FIRST before any API call:

```bash
node -e "
const fs = require('fs');
const CACHE = '/data/workspace/toast-token.json';
const TTL = 17 * 60 * 60 * 1000;
try {
  const c = JSON.parse(fs.readFileSync(CACHE, 'utf8'));
  if (Date.now() - c.ts < TTL) { process.stdout.write(c.token); process.exit(0); }
} catch {}
const body = JSON.stringify({
  clientId: process.env.TOAST_CLIENT_ID,
  clientSecret: process.env.TOAST_CLIENT_SECRET,
  userAccessType: 'TOAST_MACHINE_CLIENT'
});
fetch('https://ws-api.toasttab.com/authentication/v1/authentication/login', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body
}).then(r => r.json()).then(d => {
  const tok = d.token?.accessToken || d.accessToken;
  if (!tok) { console.error('Auth failed:', JSON.stringify(d)); process.exit(1); }
  fs.writeFileSync(CACHE, JSON.stringify({ token: tok, ts: Date.now() }));
  process.stdout.write(tok);
});
"
```

Capture the output as TOKEN. Use it in all subsequent API calls.

## 2. Restaurant Reference

### BRASSICA (9 locations)

| Location | GUID |
|----------|------|
| Harpers Station | `08d8271d-ac3d-42db-bf4b-8724eb36ea53` |
| Upper Arlington | `13aa8d5d-41c1-4694-b6cf-7a8da70512e7` |
| Easton | `3feb5d58-b0ad-469e-820a-8cc5ab11bd86` |
| Westlake | `7ef5ed1f-0866-439e-81d1-1f9be6cf9357` |
| Hunters Creek | `9a96efbb-bd24-4897-aa9d-6f76fd4fc32a` |
| Shaker Heights | `a41cc554-8827-4b68-befc-56ba95c88b8f` |
| Bexley | `b8aee3b6-cfb0-450d-9150-36524f7cc1ba` |
| Keystone Crossing | `bb917331-581f-43b2-a2b6-8e92796a3eb2` |
| Short North | `f36dddf1-99b4-45e6-a7ae-a93708ceae60` |

### NORTHSTAR CAFE (7 locations)

| Location | GUID |
|----------|------|
| Easton | `2d24a02d-95cd-45a5-8376-4a07ac1f9bdd` |
| Short North | `2fc5f505-4c1c-40b2-b31f-d964af5bde43` |
| Westerville | `51481795-2bb8-434a-832a-bb483d33393c` |
| Liberty Center | `702e2a7c-5b20-4397-9e06-d2aa55ae6b1d` |
| Kenwood | `92f3d73b-8dd1-48c0-bbd1-745283e3d3b8` |
| Shaker Heights | `a07b0d10-5441-408b-afad-95a6ac573542` |
| Beechwold | `d285cba3-9b49-4230-9c1a-805b26d6a69d` |

### THIRD & HOLLYWOOD (1 location)

| Location | GUID |
|----------|------|
| Grandview | `1cccccc3-34a8-44d1-8291-b2e0f901d2a1` |

### Disambiguation

Some location names exist in multiple brands:
- **"Short North"** — ask which brand, or default to **Brassica** Short North
- **"Easton"** — ask which brand, or default to **Brassica** Easton
- **"Shaker Heights"** — ask which brand, or default to **Brassica** Shaker Heights
- If the user says just the brand name without a location, query **all locations** for that brand
- **"all stores"** or **"all locations"** = all 17 restaurants

## 3. API Call Patterns

All calls use `exec` tool with curl. Replace `<TOKEN>` with the captured auth token and `<GUID>` with the restaurant GUID.

### 3a. List all restaurants
```bash
curl -s "https://ws-api.toasttab.com/partners/v1/restaurants" \
  -H "Authorization: Bearer <TOKEN>"
```

### 3b. Restaurant details (hours, address, lat/lng, online ordering)
```bash
curl -s "https://ws-api.toasttab.com/restaurants/v1/restaurants/<GUID>" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3c. Order GUIDs for a business date
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/orders?businessDate=YYYYMMDD" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Returns an array of order GUID strings. Use the count for "how many orders" questions.

### 3d. Full order details
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/orders/<ORDER_GUID>" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Returns: checks (with selections/items, payments, applied discounts), voidDate, revenue center, dining option, timestamps.

### 3e. Revenue centers
```bash
curl -s "https://ws-api.toasttab.com/config/v2/revenueCenters" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Typical: "Online Ordering", "Restaurant"

### 3f. Sales categories
```bash
curl -s "https://ws-api.toasttab.com/config/v2/salesCategories" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Typical: Food, Beer, Wine, Cocktails, Beverages, Catering, Retail/Other

### 3g. Discounts list
```bash
curl -s "https://ws-api.toasttab.com/config/v2/discounts" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3h. Employees
```bash
curl -s "https://ws-api.toasttab.com/labor/v1/employees" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3i. Jobs (roles)
```bash
curl -s "https://ws-api.toasttab.com/labor/v1/jobs" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3j. Time entries (who's working)
```bash
curl -s "https://ws-api.toasttab.com/labor/v1/timeEntries?startDate=<ISO>&endDate=<ISO>" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
ISO format: `2026-03-04T00:00:00.000+0000`. For "who's clocked in now", use today's date range.

### 3k. Menus
```bash
curl -s "https://ws-api.toasttab.com/menus/v2/menus" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Returns full menu: groups, items, prices, modifiers, visibility.

### 3l. Stock/inventory
```bash
curl -s "https://ws-api.toasttab.com/stock/v1/inventory" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Empty response = everything in stock. Non-empty = items marked out of stock.

### 3m. Cash drawer entries
```bash
curl -s "https://ws-api.toasttab.com/cashmgmt/v1/entries?businessDate=YYYYMMDD" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

## 4. Data Accuracy Rules

**CRITICAL: All Toast POS data must be based on ACTUAL API data. Never fabricate numbers.**

**What must be EXACT (query every single day):**
- Order counts — always query every day in the range using Section 10 batching
- Number of orders per store, per month, per day — never extrapolate from a sample

**What uses a REPRESENTATIVE SAMPLE (this is statistics, not estimation):**
- Average check size — sample 100+ orders spread across ALL 12 months (minimum 8-10 per month per store). This gives a statistically valid average.
- Top-selling items, menu mix, online vs dine-in ratios — sample enough orders to be representative

**How to report revenue:**
- Revenue = (exact order count) × (avg check from representative sample)
- Label it: "Revenue based on [exact count] orders × $XX.XX avg check (from [N]-order sample across 12 months)"
- This is NOT an estimate — the order count is exact, and the avg check is a statistically valid mean

**NEVER do this:**
- Sample a few days and multiply to get annual order counts
- Use 10 orders for avg check (too small — use 100+ spread across months)
- Report numbers as "estimated" or "approximate" — they are calculated from real data
- Fabricate or guess any number

**For any query spanning more than 1 day:** Use the batched parallel approach in Section 10.

## 5. Common Query Patterns

### Today's sales (single store)
1. Auth (section 1)
2. Get order GUIDs for today (3c) — count = total orders
3. Fetch ALL order details using batched Node.js script (write to /tmp, use Promise.all with batches of 20)
4. Sum actual check totals from every order
5. Report exact revenue — not an estimate

### Top-selling items (single store)
1. Auth
2. Get order GUIDs (3c)
3. Sample 10 orders (3d) — collect all item names + quantities
4. Aggregate and rank by frequency/revenue

### Online vs dine-in split
1. Auth
2. Revenue centers (3e) — get GUID for "Online Ordering" vs "Restaurant"
3. Sample orders (3d) — check each order's revenue center
4. Report percentages

### Average check size
1. Auth
2. Order GUIDs (3c) — get full list
3. Fetch ALL order details via batched script (or minimum 30 if >500 orders)
4. Calculate exact average from all fetched check totals

### Employee count / who's working
1. Auth
2. Employees (3h) — count and list
3. For "who's working": time entries (3j) with today's date range — filter for entries with no clockOut

### Menu with prices
1. Auth
2. Menus (3k) — parse items, prices, group names
3. Format as categorized list

### Stock status
1. Auth
2. Inventory (3l) — empty = all in stock, else list 86'd items

### Store comparison (order counts)
1. Auth
2. Batch Node.js script (section 4) hitting all relevant store GUIDs
3. Report as ranked list

### Cash drawer
1. Auth
2. Cash entries (3m) — list entries with amounts and reasons

## 6. Chart Integration

After presenting 3+ numeric data points, offer a chart button. Delegate to the **cobroker-charts** skill.

Recommended chart types for Toast data:
- **Store comparison** (order counts, revenue) → horizontal bar chart
- **Sales over time** (daily/weekly) → line chart
- **Menu item breakdown** → pie chart or bar chart
- **Online vs dine-in** → pie chart
- **Department/category split** → stacked bar or pie

## 7. Presentation Integration

After substantial multi-store analysis or trend reporting, offer to create a slide deck. Delegate to the **cobroker-presentations** skill for Gamma AI export.

## 8. Acknowledgment & Messaging Rules

1. **Acknowledge first** — before any API call, send via `message` tool:
   - "Pulling up the data..." or "Checking Toast now..."
2. **NO_REPLY during API calls** — output exactly `NO_REPLY` while running exec commands
3. **2-message discipline** — send at most 2 messages per response (1 acknowledgment + 1 results)
4. **Never show UUIDs** — always display store names and brand names
5. **Bullet/numbered lists only** — NO markdown tables (Telegram doesn't render them)
6. **Dollar amounts** — 2 decimal places, with commas (e.g., $1,234.56)
7. **Percentages** — 1 decimal place
8. **Data source note** — always state: "Data from Toast POS API" with the date range queried

## 9. Error Handling

- **Auth failure** (no token returned): "Unable to connect to Toast right now. Try again in a moment."
- **401 Unauthorized**: Token expired. Delete cache file and re-auth:
  ```bash
  rm -f /data/workspace/toast-token.json
  ```
  Then re-run auth from section 1.
- **403 Forbidden**: Endpoint not in scope. Tell the user that data isn't available through the current API access.
- **429 Rate Limited**: Wait 15 seconds, retry once. If still 429, tell the user to try again shortly.
- **Empty response** (orders): "No orders found for that date. The store may have been closed or the date may be in the future."
- **Network error**: "Having trouble reaching the Toast API. Let me try again." Retry once.

## 10. Large Date-Range Queries — Exact Totals (NOT estimates)

**CRITICAL: When the user asks for annual, yearly, quarterly, or any multi-month data — NEVER sample or estimate. Use this batched parallel method to query every single day.**

This applies to ANY Toast query across a large date range, not just sales:
- Annual/quarterly sales or revenue
- Order count trends over months
- Average check size over time
- Menu item popularity over a year
- Online vs dine-in split over time
- Any aggregation that needs every day's data

### Why this exists
The businessDate endpoint (3c) returns data for one day only. For a full year that's 365 calls per store. Calling them sequentially times out. Instead, batch all dates into a single Node.js script that runs them in parallel.

### IMPORTANT: Script execution pattern
Always write scripts to a temp file and run with `node /tmp/script.js`. Never use `node -e` for these long scripts — shell escaping breaks them.

### Step 1: Batch-query all days for a store (one exec call)

Write this script to /tmp/toast-annual.js, replacing TOKEN, GUID, START_DATE, END_DATE:

```bash
cat > /tmp/toast-annual.js << 'SCRIPT'
(async () => {
  const TOKEN = '<TOKEN>';
  const GUID = '<GUID>';
  const startDate = '<START_DATE>';
  const endDate = '<END_DATE>';
  const start = new Date(startDate);
  const end = new Date(endDate);
  const dates = [];
  for (let d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
    dates.push(d.toISOString().slice(0,10).replace(/-/g,''));
  }
  const BATCH = 20;
  const dailyCounts = {};
  for (let i = 0; i < dates.length; i += BATCH) {
    const batch = dates.slice(i, i + BATCH);
    const results = await Promise.all(batch.map(async (date) => {
      try {
        const r = await fetch('https://ws-api.toasttab.com/orders/v2/orders?businessDate=' + date, {
          headers: { 'Authorization': 'Bearer ' + TOKEN, 'Toast-Restaurant-External-ID': GUID }
        });
        if (!r.ok) return { date, count: 0 };
        const d = await r.json();
        return { date, count: Array.isArray(d) ? d.length : 0 };
      } catch { return { date, count: 0 }; }
    }));
    for (const r of results) dailyCounts[r.date] = r.count;
  }
  const totalOrders = Object.values(dailyCounts).reduce((a, b) => a + b, 0);
  console.log(JSON.stringify({ guid: GUID, totalOrders, daysQueried: dates.length, dailyCounts }));
})();
SCRIPT
node /tmp/toast-annual.js
```

Takes ~20-30 seconds per store. Run once per store.

### Step 2: Get average check from a broad sample (one exec call per store)

```bash
cat > /tmp/toast-avgcheck.js << 'SCRIPT'
(async () => {
  const TOKEN = '<TOKEN>';
  const GUID = '<GUID>';
  const dates = ['20250115','20250215','20250315','20250415','20250515','20250615','20250715','20250815','20250915','20251015','20251115','20251215'];
  let allGuids = [];
  for (const date of dates) {
    const r = await fetch('https://ws-api.toasttab.com/orders/v2/orders?businessDate=' + date, {
      headers: { 'Authorization': 'Bearer ' + TOKEN, 'Toast-Restaurant-External-ID': GUID }
    });
    const d = await r.json();
    if (Array.isArray(d)) allGuids.push(...d);
  }
  const sample = allGuids.sort(() => Math.random() - 0.5).slice(0, 120);
  let totals = [];
  for (let i = 0; i < sample.length; i += 10) {
    const batch = sample.slice(i, i + 10);
    const results = await Promise.all(batch.map(async (orderGuid) => {
      try {
        const r = await fetch('https://ws-api.toasttab.com/orders/v2/orders/' + orderGuid, {
          headers: { 'Authorization': 'Bearer ' + TOKEN, 'Toast-Restaurant-External-ID': GUID }
        });
        const o = await r.json();
        return o.checks?.reduce((sum, c) => sum + (c.totalAmount || 0), 0) || 0;
      } catch { return 0; }
    }));
    totals.push(...results.filter(t => t > 0));
  }
  const avgCheck = totals.length > 0 ? totals.reduce((a,b) => a+b, 0) / totals.length : 0;
  console.log(JSON.stringify({ avgCheck: avgCheck.toFixed(2), sampled: totals.length }));
})();
SCRIPT
node /tmp/toast-avgcheck.js
```

### Step 3: Calculate and report

```
Total Revenue = totalOrders * avgCheck
```

Run Step 1 + Step 2 for each store. Total: ~12 exec calls for 6 stores, completing in 3-5 minutes.

### Adapting for other query types

The dailyCounts object from Step 1 contains order counts per day. For queries beyond revenue:

- **Monthly trends**: Group dailyCounts by month, sum each month
- **Day-of-week analysis**: Group by weekday
- **Busiest days**: Sort dailyCounts by value
- **Growth rate**: Compare Q1 vs Q4 totals
- **Order details at scale**: Modify Step 1 to also collect the first N order GUIDs per day, then batch-fetch details in Step 2

For menu item analysis, employee patterns, or other detail-heavy queries across long periods, use the same batching pattern but fetch order details instead of just counts.

### When to use this method
- ANY query spanning more than 1 day → Use this method
- Annual, quarterly, monthly queries → Use this method
- There is NO sampling alternative — always use exact data
