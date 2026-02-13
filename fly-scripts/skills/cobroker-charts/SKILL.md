---
name: cobroker-charts
description: >
  Generate professional chart images from any data and send via Telegram.
  Use when the user asks to visualize, chart, graph, or plot data.
  Also proactively offer charts when presenting numeric comparisons.
user-invocable: true
metadata:
  openclaw:
    emoji: "📈"
---

# Chart Generation

Generate professional chart images from data and send them as Telegram photos.

## When to Offer Charts

**Explicit** — user says "chart", "graph", "visualize", "plot", or clicks the chart button.

**Proactive** — after presenting **3+ numeric data points** in a comparison (revenue by store, monthly trends, category breakdowns), include a chart button in the SAME message:

```
buttons: [[{"text": "📊 Chart it", "callback_data": "chart_yes"}]]
```

## Callback Handling

When you receive `"chart_yes"` (button click) or the user says "chart it" / "graph it" / "visualize this":
1. Look at the data from your most recent analytical response
2. Build a Chart.js config
3. Generate and send the chart

## Chart Generation Steps

### 1. Pick chart type from data shape

| Data shape | Chart type |
|-----------|-----------|
| Named categories with values | `bar` |
| Time series / trend | `line` |
| Proportions / shares | `doughnut` |
| Volume / cumulative | `line` with `fill: true` |
| Long category labels | `bar` with `indexAxis: "y"` (horizontal) |
| Multiple series over categories | grouped `bar` or multi-`line` |

### 2. Build Chart.js config JSON

The renderer auto-applies colors and styling (white background, black text). You only need to provide the data structure.

### 3. Generate PNG via exec

```
exec: cd /data/chart-renderer && node generate-chart.mjs '<CONFIG_JSON>' /tmp/chart-<TIMESTAMP>.png
```

Use `Date.now()` or similar for the timestamp to avoid collisions.

**IMPORTANT**: The config JSON must be valid JSON passed as a single shell argument in single quotes. Keep it under 1KB. Escape any single quotes in labels.

### 4. Send the chart image

```
message: action=send, media=/tmp/chart-<TIMESTAMP>.png, message="📊 <brief insight about the data>"
```

## Template Configs

### Bar Chart
```json
{
  "type": "bar",
  "data": {
    "labels": ["Q1", "Q2", "Q3", "Q4"],
    "datasets": [{
      "label": "Revenue",
      "data": [12000, 19000, 15000, 22000]
    }]
  },
  "options": {
    "plugins": { "title": { "display": true, "text": "Quarterly Revenue", "color": "#000000" } }
  }
}
```

### Line Chart
```json
{
  "type": "line",
  "data": {
    "labels": ["Jan", "Feb", "Mar", "Apr", "May"],
    "datasets": [{
      "label": "Sales",
      "data": [65, 78, 90, 81, 95]
    }]
  },
  "options": {
    "plugins": { "title": { "display": true, "text": "Monthly Sales Trend", "color": "#000000" } }
  }
}
```

### Area Chart
```json
{
  "type": "line",
  "data": {
    "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"],
    "datasets": [{
      "label": "Volume",
      "data": [120, 190, 300, 250, 400],
      "fill": true,
      "backgroundColor": "rgba(59, 130, 246, 0.2)"
    }]
  },
  "options": {
    "plugins": { "title": { "display": true, "text": "Daily Volume", "color": "#000000" } }
  }
}
```

### Doughnut Chart
```json
{
  "type": "doughnut",
  "data": {
    "labels": ["Dine-in", "Takeout", "Delivery"],
    "datasets": [{
      "data": [55, 30, 15]
    }]
  },
  "options": {
    "plugins": { "title": { "display": true, "text": "Order Distribution", "color": "#000000" } }
  }
}
```

## Constraints

- **Max 12 data points** per chart — aggregate if more (top 10 + "Other")
- Always use `/tmp/chart-{timestamp}.png` as output path
- Use **K/M/B suffixes** for large numbers in labels (e.g. "$1.2M" not "$1,200,000")
- Keep chart titles short and descriptive
- Include a brief text insight when sending the chart image
- If exec fails, tell the user the chart couldn't be generated and present the data as text instead
