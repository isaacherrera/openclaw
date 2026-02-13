#!/usr/bin/env node
import Anthropic from "@anthropic-ai/sdk";
import { readFileSync } from "node:fs";
import { extname, basename } from "node:path";
import { parseArgs } from "node:util";

const MIME_MAP = {
  ".pdf":  { mime: "application/pdf",  block: "document" },
  ".txt":  { mime: "text/plain",       block: "document" },
  ".jpg":  { mime: "image/jpeg",       block: "image" },
  ".jpeg": { mime: "image/jpeg",       block: "image" },
  ".png":  { mime: "image/png",        block: "image" },
  ".gif":  { mime: "image/gif",        block: "image" },
  ".webp": { mime: "image/webp",       block: "image" },
  ".csv":  { block: "text_inline" },
  ".xlsx": { block: "convert_xlsx" },
  ".docx": { block: "convert_docx" },
};

const DEFAULT_PROMPT = `You are a commercial real estate document analyst. Extract all property data from this document.

Return a JSON object with these fields:
{
  "_document_type": "offering memo | flyer | brochure | spreadsheet | other",
  "_summary": "1-2 sentence summary of the document",
  "properties": [
    {
      "address": "Full street address, City, State ZIP",
      ...all other fields you can find (Price, Size, Cap Rate, NOI, Year Built, Tenants, Zoning, etc.)
    }
  ]
}

Rules:
- Extract EVERY property mentioned in the document
- Use human-readable field names (e.g. "Price" not "price_usd")
- Keep original formatting for values (e.g. "$1,500,000" not 1500000)
- Address MUST have at least 3 comma-separated parts (street, city, state+zip)
- If a single-property document, still return an array with one item
- If no specific address is found, use the best location info available
- Return ONLY valid JSON, no markdown fences or extra text`;

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    prompt: { type: "string", short: "p" },
    model:  { type: "string", short: "m" },
  },
});

const filePath = positionals[0];
if (!filePath) {
  console.error(JSON.stringify({ error: "Usage: node extract.mjs <file-path> [--prompt '...'] [--model '...']" }));
  process.exit(1);
}

const ext = extname(filePath).toLowerCase();
const info = MIME_MAP[ext];
if (!info) {
  console.error(JSON.stringify({ error: `Unsupported file type: ${ext}`, supported: Object.keys(MIME_MAP) }));
  process.exit(1);
}

const model = values.model || "claude-sonnet-4-5-20250929";
const prompt = values.prompt || DEFAULT_PROMPT;

try {
  const content = [];

  if (info.block === "document" || info.block === "image") {
    const data = readFileSync(filePath).toString("base64");
    // Check size — Anthropic limit is ~32MB base64
    if (data.length > 32 * 1024 * 1024) {
      console.error(JSON.stringify({ error: "File too large (>32MB)", file: basename(filePath) }));
      process.exit(1);
    }
    content.push({
      type: info.block,
      source: { type: "base64", media_type: info.mime, data },
    });
  } else if (info.block === "text_inline") {
    const text = readFileSync(filePath, "utf-8");
    content.push({
      type: "text",
      text: `Document content (${basename(filePath)}):\n\n${text}`,
    });
  } else if (info.block === "convert_xlsx") {
    const { read, utils } = await import("xlsx");
    const workbook = read(readFileSync(filePath));
    const sheets = [];
    for (const name of workbook.SheetNames) {
      const csv = utils.sheet_to_csv(workbook.Sheets[name]);
      sheets.push(`--- Sheet: ${name} ---\n${csv}`);
    }
    content.push({
      type: "text",
      text: `Spreadsheet content (${basename(filePath)}):\n\n${sheets.join("\n\n")}`,
    });
  } else if (info.block === "convert_docx") {
    const mammoth = await import("mammoth");
    const result = await mammoth.extractRawText({ path: filePath });
    content.push({
      type: "text",
      text: `Document content (${basename(filePath)}):\n\n${result.value}`,
    });
  }

  content.push({ type: "text", text: prompt });

  const client = new Anthropic();
  const response = await client.messages.create({
    model,
    max_tokens: 4096,
    messages: [{ role: "user", content }],
  });

  let text = response.content
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("");

  // Strip markdown fences if present (```json ... ```)
  text = text.replace(/^```(?:json)?\s*\n?/i, "").replace(/\n?```\s*$/i, "").trim();

  // Try to parse as JSON to validate
  const parsed = JSON.parse(text);
  console.log(JSON.stringify(parsed, null, 2));
} catch (err) {
  if (err instanceof SyntaxError) {
    // Claude returned non-JSON — output raw text wrapped in error
    console.error(JSON.stringify({ error: "Model returned non-JSON response", raw: err.message }));
  } else {
    console.error(JSON.stringify({ error: err.message, file: basename(filePath) }));
  }
  process.exit(1);
}
