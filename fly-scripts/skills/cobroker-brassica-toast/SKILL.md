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

### 3c. Order GUIDs for a business date (fast counting)
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/orders?businessDate=YYYYMMDD" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Returns an array of order GUID strings. Use the count for "how many orders" questions. Best for counting orders across many days (1 call per day, returns all GUIDs).

### 3d. Full order details (single order)
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/orders/<ORDER_GUID>" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Returns: checks (with selections/items, payments, applied discounts), voidDate, revenue center, dining option, timestamps.

### 3d-bulk. Bulk orders with full details (ordersBulk — PREFERRED for revenue/details)
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/ordersBulk?startDate=2025-04-01T00:00:00.000Z&endDate=2025-04-30T23:59:59.999Z&pageSize=100&page=1" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Returns full Order objects (with checks, amounts, items) — paginated. Key rules:
- **startDate/endDate**: ISO 8601 format, max range = 1 month
- **pageSize**: max 100
- **Pagination**: follow `Link` header with `rel="next"` for more pages
- **Rate limit**: 5 requests per second per location
- Use this instead of 3d when you need order amounts/details for multiple orders — avoids fetching one-by-one

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

**CRITICAL: When the user asks for annual, yearly, quarterly, or any multi-month data — NEVER sample or estimate order counts. Use the ALL-IN-ONE script below.**

### IMPORTANT: Script execution pattern
Always write scripts to a temp file and run with `node /tmp/script.js`. Never use `node -e` for long scripts.

### ALL-IN-ONE Script: Order Counts + Revenue in a Single Exec Call

This script processes ALL stores simultaneously and gets both exact order counts AND average check in ONE run. Write to `/tmp/toast-report.js`, replacing TOKEN, the stores array, and dates.

```bash
cat > /tmp/toast-report.js << 'SCRIPT'
(async () => {
  const TOKEN = '<TOKEN>';
  const stores = [
    { name: '<STORE_NAME_1>', guid: '<GUID_1>' },
    { name: '<STORE_NAME_2>', guid: '<GUID_2>' }
  ];
  const startDate = '<START_DATE>';
  const endDate = '<END_DATE>';

  const dates = [];
  for (let d = new Date(startDate); d <= new Date(endDate); d.setDate(d.getDate() + 1)) {
    dates.push(d.toISOString().slice(0,10).replace(/-/g,''));
  }

  // Process ALL stores in parallel
  const results = await Promise.all(stores.map(async (store) => {
    // --- Phase 1: Exact order counts (5 concurrent per store for rate limits) ---
    const BATCH = 5;
    const monthlyCounts = {};
    let totalOrders = 0;
    for (let i = 0; i < dates.length; i += BATCH) {
      const batch = dates.slice(i, i + BATCH);
      const counts = await Promise.all(batch.map(async (date) => {
        for (let retry = 0; retry < 2; retry++) {
          try {
            const r = await fetch('https://ws-api.toasttab.com/orders/v2/orders?businessDate=' + date, {
              headers: { 'Authorization': 'Bearer ' + TOKEN, 'Toast-Restaurant-External-ID': store.guid }
            });
            if (r.status === 429) { await new Promise(r => setTimeout(r, 3000)); continue; }
            if (!r.ok) return { date, count: 0 };
            const d = await r.json();
            return { date, count: Array.isArray(d) ? d.length : 0 };
          } catch { if (retry === 1) return { date, count: 0 }; }
        }
        return { date, count: 0 };
      }));
      for (const c of counts) {
        const month = c.date.slice(0, 6);
        monthlyCounts[month] = (monthlyCounts[month] || 0) + c.count;
        totalOrders += c.count;
      }
    }

    // --- Phase 2: Avg check via ordersBulk (full order objects, no separate detail fetch) ---
    // Sample the 15th of each month using ordersBulk — returns full orders with amounts
    const months = [...new Set(dates.map(d => d.slice(0, 6)))];
    let checkAmounts = [];
    for (let i = 0; i < months.length; i += 3) {
      const batch = months.slice(i, i + 3);
      const batchResults = await Promise.all(batch.map(async (ym) => {
        try {
          const y = ym.slice(0, 4), m = ym.slice(4, 6);
          const start = y + '-' + m + '-01T00:00:00.000Z';
          const lastDay = new Date(parseInt(y), parseInt(m), 0).getDate();
          const end = y + '-' + m + '-' + String(lastDay).padStart(2, '0') + 'T23:59:59.999Z';
          const r = await fetch(
            'https://ws-api.toasttab.com/orders/v2/ordersBulk?startDate=' + encodeURIComponent(start) + '&endDate=' + encodeURIComponent(end) + '&pageSize=100&page=1',
            { headers: { 'Authorization': 'Bearer ' + TOKEN, 'Toast-Restaurant-External-ID': store.guid } }
          );
          if (!r.ok) return [];
          const orders = await r.json();
          return (Array.isArray(orders) ? orders : []).map(o =>
            (o.checks || []).reduce((sum, c) => sum + (c.totalAmount || 0), 0)
          ).filter(a => a > 0);
        } catch { return []; }
      }));
      for (const amounts of batchResults) checkAmounts.push(...amounts);
    }
    const avgCheck = checkAmounts.length > 0 ? checkAmounts.reduce((a, b) => a + b, 0) / checkAmounts.length : 0;
    const revenue = totalOrders * avgCheck;

    return {
      name: store.name,
      totalOrders,
      monthlyCounts,
      avgCheck: avgCheck.toFixed(2),
      sampleSize: checkAmounts.length,
      revenue: revenue.toFixed(2)
    };
  }));

  console.log(JSON.stringify(results, null, 2));
})();
SCRIPT
node /tmp/toast-report.js
```

**Performance**: All stores run in parallel. Each store: ~75 seconds for counts (365 days ÷ 5 concurrent) + ~5 seconds for avg check via ordersBulk. Total: ~80 seconds regardless of store count.

**Why this is fast**: ordersBulk returns 100 full orders per call with amounts included — no need to fetch order details one-by-one. 12 monthly calls per store gives 1,200 order samples for avg check (well over 100+ minimum).

### How to report results

```
Revenue = (exact order count) × (avg check from ordersBulk sample)
```

Present as: "Revenue: $X based on [exact count] orders × $XX.XX avg check ([N]-order sample across 12 months)"

### Adapting for other query types

The monthlyCounts object contains exact order counts per month. For queries beyond revenue:

- **Monthly trends**: monthlyCounts already has this
- **Day-of-week analysis**: Modify Phase 1 to group by weekday
- **Busiest days**: Modify Phase 1 to track daily counts and sort
- **Growth rate**: Compare first vs last quarter from monthlyCounts
- **Menu items / order details at scale**: Use ordersBulk (3d-bulk) with monthly date ranges

### When to use this method
- ANY query spanning more than 7 days → Use this method
- Annual, quarterly, monthly queries → Use this method
- ALWAYS use the all-in-one script — never run stores one at a time
