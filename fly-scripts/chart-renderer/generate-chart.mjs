import { createCanvas, GlobalFonts } from "@napi-rs/canvas";
import { Chart, registerables } from "chart.js";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
GlobalFonts.registerFromPath(join(__dirname, "fonts/Inter-Regular.ttf"), "Inter");
GlobalFonts.registerFromPath(join(__dirname, "fonts/Inter-SemiBold.ttf"), "Inter SemiBold");

Chart.register(...registerables);
Chart.defaults.font.family = "Inter";

// Blue-500 primary palette with complementary accents
const COLORS = [
  "#3b82f6",             // blue-500 (primary)
  "#60a5fa",             // blue-400
  "#93c5fd",             // blue-300
  "#2563eb",             // blue-600
  "#1d4ed8",             // blue-700
  "#bfdbfe",             // blue-200
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
      ds.borderColor = ds.borderColor || "#ffffff";
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
    config.options.scales[axis].grid = config.options.scales[axis].grid || { color: "rgba(0,0,0,0.1)" };
    config.options.scales[axis].ticks = config.options.scales[axis].ticks || { color: "#000000" };
  }
}

config.options.plugins = config.options.plugins || {};
config.options.plugins.legend = config.options.plugins.legend || { labels: { color: "#000000", font: { family: "Inter" } } };
if (config.options.plugins.title) {
  config.options.plugins.title.color = config.options.plugins.title.color || "#000000";
  config.options.plugins.title.font = config.options.plugins.title.font || { family: "Inter SemiBold", size: 16 };
}

// White background canvas
const canvas = createCanvas(width, height);
const ctx = canvas.getContext("2d");
ctx.fillStyle = "#ffffff";
ctx.fillRect(0, 0, width, height);

new Chart(ctx, config);

writeFileSync(outputPath, canvas.toBuffer("image/png"));
console.log(`Chart saved to ${outputPath}`);
