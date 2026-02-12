import { createCanvas } from "@napi-rs/canvas";
import { Chart, registerables } from "chart.js";
import { writeFileSync } from "node:fs";

Chart.register(...registerables);

// ShadCN-inspired palette
const COLORS = [
  "hsl(12, 76%, 61%)",   // warm coral
  "hsl(173, 58%, 39%)",  // teal
  "hsl(197, 37%, 24%)",  // dark blue
  "hsl(43, 74%, 66%)",   // gold
  "hsl(27, 87%, 67%)",   // orange
  "hsl(215, 25%, 65%)",  // steel blue
];

const configJson = process.argv[2];
const outputPath = process.argv[3] || "/tmp/chart.png";

if (!configJson) {
  console.error("Usage: node generate-chart.mjs '<chart-config-json>' [output-path]");
  process.exit(1);
}

const config = JSON.parse(configJson);
const width = config.width || 800;
const height = config.height || 400;
delete config.width;
delete config.height;

const chartType = config.type || "bar";
const isPie = chartType === "pie" || chartType === "doughnut";

// Apply default colors to datasets
if (config.data?.datasets) {
  config.data.datasets.forEach((ds, i) => {
    if (isPie) {
      ds.backgroundColor = ds.backgroundColor || COLORS;
      ds.borderColor = ds.borderColor || "#fff";
      ds.borderWidth = ds.borderWidth ?? 2;
    } else {
      ds.backgroundColor = ds.backgroundColor || COLORS[i % COLORS.length];
      ds.borderColor = ds.borderColor || COLORS[i % COLORS.length];
      if (chartType === "bar") ds.borderRadius = ds.borderRadius ?? 6;
      if (chartType === "line") {
        ds.tension = ds.tension ?? 0.4;
        ds.pointRadius = ds.pointRadius ?? 4;
      }
    }
  });
}

// Global options defaults
config.options = config.options || {};
config.options.responsive = false;
config.options.animation = false;

if (!isPie) {
  config.options.scales = config.options.scales || {};
  for (const axis of ["x", "y"]) {
    config.options.scales[axis] = config.options.scales[axis] || {};
    config.options.scales[axis].grid = config.options.scales[axis].grid || { color: "rgba(255,255,255,0.1)" };
    config.options.scales[axis].ticks = config.options.scales[axis].ticks || { color: "#94a3b8" };
  }
}

config.options.plugins = config.options.plugins || {};
config.options.plugins.legend = config.options.plugins.legend || { labels: { color: "#e2e8f0" } };

// Dark background canvas
const canvas = createCanvas(width, height);
const ctx = canvas.getContext("2d");
ctx.fillStyle = "#0f172a";
ctx.fillRect(0, 0, width, height);

new Chart(ctx, config);

writeFileSync(outputPath, canvas.toBuffer("image/png"));
console.log(`Chart saved to ${outputPath}`);
