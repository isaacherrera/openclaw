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

## 4. Smart Sampling — API Budget

You have a budget of **15 API calls per question** (excluding the auth call). Plan before calling.

**Counting rules:**
- Auth call = free (cached)
- Each curl = 1 API call
- Fetching order GUIDs = 1 call per restaurant
- Fetching order details = 1 call per order

**Sampling strategy:**
- **Order counts only**: Use endpoint 3c — returns GUIDs, count them. 1 call per store.
- **Order details needed**: Fetch GUIDs (1 call), then sample up to **10 random orders** from the list. Use `node -e` to pick random indices:
  ```bash
  node -e "const g=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); const s=[...g].sort(()=>Math.random()-.5).slice(0,10); console.log(JSON.stringify(s));"
  ```
- **Multi-store comparison**: Query order counts (1 call/store) rather than fetching details from every store. For 9 Brassica stores that's 9 calls — within budget.
- **All 17 stores**: Only fetch order counts (17 calls exceeds budget). Instead batch into a single Node.js script:
  ```bash
  node -e "
  const guids = { /* paste relevant GUIDs */ };
  const TOKEN = '<TOKEN>';
  Promise.all(Object.entries(guids).map(async ([name, guid]) => {
    const r = await fetch('https://ws-api.toasttab.com/orders/v2/orders?businessDate=YYYYMMDD', {
      headers: { 'Authorization': 'Bearer ' + TOKEN, 'Toast-Restaurant-External-ID': guid }
    });
    const d = await r.json();
    return { name, orders: Array.isArray(d) ? d.length : 0 };
  })).then(r => console.log(JSON.stringify(r, null, 2)));
  "
  ```
  This counts as 1 exec call but hits multiple endpoints. Use this for "all stores" queries.

## 5. Common Query Patterns

### Today's sales (single store)
1. Auth (section 1)
2. Get order GUIDs for today (3c) — count = total orders
3. Sample 10 order details (3d) — extract check totals
4. Extrapolate: `(sum of sampled totals / sampled count) * total orders`
5. Report estimate with sample size noted

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
2. Order GUIDs (3c) — count
3. Sample 10 orders (3d) — extract check totals
4. Average the sampled check totals

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
8. **Sampling disclaimer** — when extrapolating from a sample, note: "Based on a sample of N orders"

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
