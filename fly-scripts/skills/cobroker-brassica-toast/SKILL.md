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

17 restaurants across 3 brands: **Brassica** (9), **Northstar Cafe** (7), **Third & Hollywood** (1).

## 1. Authentication

Get a Bearer token (cached ~17h). Run FIRST before any API call:

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

Capture the output as TOKEN.

## 2. Restaurant GUIDs

### BRASSICA (9)
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

### NORTHSTAR CAFE (7)
| Location | GUID |
|----------|------|
| Easton | `2d24a02d-95cd-45a5-8376-4a07ac1f9bdd` |
| Short North | `2fc5f505-4c1c-40b2-b31f-d964af5bde43` |
| Westerville | `51481795-2bb8-434a-832a-bb483d33393c` |
| Liberty Center | `702e2a7c-5b20-4397-9e06-d2aa55ae6b1d` |
| Kenwood | `92f3d73b-8dd1-48c0-bbd1-745283e3d3b8` |
| Shaker Heights | `a07b0d10-5441-408b-afad-95a6ac573542` |
| Beechwold | `d285cba3-9b49-4230-9c1a-805b26d6a69d` |

### THIRD & HOLLYWOOD (1)
| Location | GUID |
|----------|------|
| Grandview | `1cccccc3-34a8-44d1-8291-b2e0f901d2a1` |

### Disambiguation
- "Short North", "Easton", "Shaker Heights" — default to Brassica
- Brand name only = all locations. "all stores" = all 17.

## 3. API Endpoints

All calls use `exec` with curl. Replace `<TOKEN>` and `<GUID>`.

### 3a. Order GUIDs for a business date
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/orders?businessDate=YYYYMMDD" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3b. Full order details (single order)
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/orders/<ORDER_GUID>" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3c. Bulk orders (ordersBulk — for revenue/details)
```bash
curl -s "https://ws-api.toasttab.com/orders/v2/ordersBulk?startDate=2025-04-01T00:00:00.000Z&endDate=2025-04-30T23:59:59.999Z&pageSize=100&page=1" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Max range = 1 month. Pagination: follow pages until `data.length < 100`.

### 3d. Restaurant details
```bash
curl -s "https://ws-api.toasttab.com/restaurants/v1/restaurants/<GUID>" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3e. Revenue centers
```bash
curl -s "https://ws-api.toasttab.com/config/v2/revenueCenters" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3f. Sales categories
```bash
curl -s "https://ws-api.toasttab.com/config/v2/salesCategories" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3g. Discounts
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
ISO format: `2026-03-04T00:00:00.000+0000`.

### 3k. Menus
```bash
curl -s "https://ws-api.toasttab.com/menus/v2/menus" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

### 3l. Stock/inventory
```bash
curl -s "https://ws-api.toasttab.com/stock/v1/inventory" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```
Empty = everything in stock. Non-empty = items marked out of stock.

### 3m. Cash drawer
```bash
curl -s "https://ws-api.toasttab.com/cashmgmt/v1/entries?businessDate=YYYYMMDD" \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Toast-Restaurant-External-ID: <GUID>"
```

## 4. Revenue/Sales Queries — EXACT SUMS, MAXIMUM PARALLELISM

**For ANY revenue/sales query spanning multiple days, use this script. ALL stores run in parallel. NEVER split into groups.**

This sums EVERY check amount directly via ordersBulk. All 12 months launch simultaneously per store. Concurrency limiter keeps requests at 8 in-flight per store. No averages, no estimates — exact totals.

Write to `/tmp/toast-report.js` and run with `node /tmp/toast-report.js`:

```bash
cat > /tmp/toast-report.js << 'SCRIPT'
(async () => {
  const TOKEN = '<TOKEN>';
  const stores = [
    { name: '<STORE_1>', guid: '<GUID_1>' },
    // add all requested stores
  ];
  const startYear = <YYYY>, endYear = <YYYY>, startMonth = <M>, endMonth = <M>;

  const allMonths = [];
  for (let y = startYear, m = startMonth; y < endYear || (y === endYear && m <= endMonth); m++) {
    if (m > 12) { m = 1; y++; }
    allMonths.push({ y, m });
  }

  const BASE = 'https://ws-api.toasttab.com';

  function limiter(max) {
    let active = 0; const queue = [];
    return (fn) => new Promise((res, rej) => {
      const run = async () => { active++; try { res(await fn()); } catch(e) { rej(e); } finally { active--; if (queue.length) queue.shift()(); } };
      active < max ? run() : queue.push(run);
    });
  }

  async function fetchRetry(url, headers, retries = 3) {
    for (let i = 0; i < retries; i++) {
      try {
        const r = await fetch(url, { headers });
        if (r.status === 429) { await new Promise(w => setTimeout(w, 2000 * (i + 1))); continue; }
        if (!r.ok) return null;
        return await r.json();
      } catch { await new Promise(w => setTimeout(w, 1000)); }
    }
    return null;
  }

  const results = await Promise.all(stores.map(async (store) => {
    const H = { 'Authorization': 'Bearer ' + TOKEN, 'Toast-Restaurant-External-ID': store.guid };
    const limit = limiter(8);
    let totalOrders = 0, totalRevenue = 0;
    const monthly = {};

    await Promise.all(allMonths.map(({ y, m }) => (async () => {
      const mm = String(m).padStart(2, '0');
      const lastDay = new Date(y, m, 0).getDate();
      const start = `${y}-${mm}-01T00:00:00.000Z`;
      const end = `${y}-${mm}-${String(lastDay).padStart(2,'0')}T23:59:59.999Z`;
      let page = 1, mOrd = 0, mRev = 0;
      while (true) {
        const p = page;
        const data = await limit(() => fetchRetry(
          `${BASE}/orders/v2/ordersBulk?startDate=${encodeURIComponent(start)}&endDate=${encodeURIComponent(end)}&pageSize=100&page=${p}`, H
        ));
        if (!data || !Array.isArray(data) || data.length === 0) break;
        for (const o of data) { mOrd++; mRev += (o.checks || []).reduce((s, c) => s + (c.totalAmount || 0), 0); }
        if (data.length < 100) break;
        page++;
      }
      monthly[y + mm] = { orders: mOrd, revenue: Math.round(mRev * 100) / 100 };
      totalOrders += mOrd; totalRevenue += mRev;
    })()));

    return {
      name: store.name, totalOrders,
      totalRevenue: Math.round(totalRevenue * 100) / 100,
      avgCheck: totalOrders > 0 ? Math.round((totalRevenue / totalOrders) * 100) / 100 : 0,
      monthly
    };
  }));

  let gT = 0, gO = 0;
  for (const r of results) { gT += r.totalRevenue; gO += r.totalOrders; }
  console.log(JSON.stringify({ stores: results, grandTotal: Math.round(gT * 100) / 100, grandOrders: gO }, null, 2));
})();
SCRIPT
node /tmp/toast-report.js
```

**Performance**: All stores × all 12 months launch simultaneously. 8 concurrent requests per store. Every check summed — no averages.

## 5. Common Query Patterns

### Today's sales (single store)
1. Auth → 2. ordersBulk for today's date range (single page usually) → 3. Sum check totals

### Top-selling items
1. Auth → 2. ordersBulk for date range → 3. Aggregate item names + quantities from selections → 4. Rank

### Online vs dine-in split
1. Auth → 2. Revenue centers (3e) → 3. Sample orders → 4. Check each order's revenue center → 5. Report %

### Employee count / who's working
1. Auth → 2. Employees (3h) for full list → 3. For "who's working now": Time entries (3j) with today's range, filter for no clockOut

### Menu with prices
1. Auth → 2. Menus (3k) → 3. Parse items, prices, group names → 4. Format as categorized list

### Stock status
1. Auth → 2. Inventory (3l) → Empty = all in stock, else list 86'd items

### Cash drawer
1. Auth → 2. Cash entries (3m) → List entries with amounts and reasons

### Multi-day revenue (any number of stores)
1. Auth → 2. Run the Section 4 script with all requested stores → 3. Report exact totals

## 6. Data Accuracy Rules

**CRITICAL:**
- All numbers from actual API responses. NEVER fabricate, estimate, or extrapolate.
- NEVER use "estimate", "est.", "approximate", or "~" for revenue or order figures.
- Revenue is exact — every check summed directly. Not an estimate.
- 0 orders = report 0. API error = "Data not available" with reason.
- Stores with no data likely aren't open or aren't connected.

## 7. Messaging Rules

1. Acknowledge before API calls: "Pulling up the data..."
2. NO_REPLY during exec commands
3. Max 2 messages per response
4. Never show UUIDs — use store/brand names
5. Bullet lists only — no markdown tables (Telegram doesn't render them)
6. Dollar amounts: $1,234.56 with commas
7. Always state: "Data from Toast POS API" with date range

## 8. Error Handling

- **Auth failure**: Delete `/data/workspace/toast-token.json`, re-auth
- **401**: Token expired — delete cache, re-auth
- **403**: Endpoint not in scope
- **429**: Built into script with exponential backoff
- **Empty response**: "No orders found" — store may be closed or not connected

## 9. Chart & Presentation Integration

After 3+ data points, offer chart via **cobroker-charts** skill.
After substantial analysis, offer slides via **cobroker-presentations** skill.
