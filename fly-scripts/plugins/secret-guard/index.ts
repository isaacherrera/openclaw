/**
 * secret-guard — OpenClaw plugin that prevents API keys from leaking in outbound messages.
 *
 * How it works:
 * 1. On startup, reads all sensitive env vars and stores their values.
 * 2. On every outbound message (message_sending hook), scans the text for:
 *    - Exact matches of known secret values (substring match)
 *    - Common API key patterns (sk-ant-, AIza, Bearer tokens, etc.)
 * 3. If a match is found, redacts the secret and logs the attempt.
 *
 * This runs in the gateway process — the agent cannot disable or bypass it.
 */

// Env var names that contain secrets we must never expose.
const SENSITIVE_ENV_KEYS = [
  "ANTHROPIC_API_KEY",
  "TELEGRAM_BOT_TOKEN",
  "OPENCLAW_GATEWAY_TOKEN",
  "OPENCLAW_LOG_SECRET",
  "GOOGLE_GEMINI_API_KEY",
  "PARALLEL_AI_API_KEY",
  "BRAVE_API_KEY",
  "COBROKER_AGENT_SECRET",
  "GOG_KEYRING_PASSWORD",
];

// Minimum length for an env var value to be considered a secret worth guarding.
// Very short values (e.g. "true", "1") would cause false positives.
const MIN_SECRET_LENGTH = 8;

// Regex patterns that match common API key formats (fallback for unknown keys).
const KEY_PATTERNS = [
  /sk-ant-api\S{10,}/gi,                  // Anthropic
  /sk-[a-zA-Z0-9]{20,}/gi,                // OpenAI-style
  /AIza[a-zA-Z0-9_-]{30,}/gi,             // Google
  /\d{8,13}:[A-Za-z0-9_-]{30,}/g,         // Telegram bot tokens
  /Bearer\s+[A-Za-z0-9._~+/=-]{20,}/gi,   // Bearer tokens in text
  /-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----[\s\S]*?-----END/gi, // PEM blocks
];

type PluginApi = {
  pluginConfig?: Record<string, unknown>;
  logger: {
    info?: (msg: string) => void;
    warn?: (msg: string) => void;
    error: (msg: string) => void;
  };
  on: (
    hookName: string,
    handler: (event: any, ctx: any) => any,
    opts?: { priority?: number },
  ) => void;
};

export default function register(api: PluginApi) {
  // ── Build the set of secret values to watch for ──
  const secretValues: string[] = [];

  for (const key of SENSITIVE_ENV_KEYS) {
    const val = process.env[key];
    if (val && val.length >= MIN_SECRET_LENGTH) {
      secretValues.push(val);
    }
  }

  api.logger.info?.(
    `[secret-guard] Loaded ${secretValues.length} secret values to guard`,
  );

  // ── message_sending hook — runs before every outbound message ──
  api.on(
    "message_sending",
    (
      event: { to: string; content: string; metadata?: Record<string, unknown> },
      ctx: { channelId: string },
    ) => {
      if (!event.content) return;

      let content = event.content;
      let redacted = false;

      // Check 1: Exact secret value matches (most reliable).
      for (const secret of secretValues) {
        if (content.includes(secret)) {
          // Redact: show first 4 chars + mask + last 4 chars
          const mask =
            secret.slice(0, 4) + "[***REDACTED***]" + secret.slice(-4);
          content = content.split(secret).join(mask);
          redacted = true;
        }
      }

      // Check 2: Regex pattern matches (catches keys we don't know about).
      for (const pattern of KEY_PATTERNS) {
        // Reset lastIndex for global regex
        pattern.lastIndex = 0;
        if (pattern.test(content)) {
          pattern.lastIndex = 0;
          content = content.replace(pattern, (match) => {
            redacted = true;
            return match.slice(0, 4) + "[***REDACTED***]" + match.slice(-4);
          });
        }
      }

      if (redacted) {
        api.logger.warn?.(
          `[secret-guard] BLOCKED secret leak in message to ${event.to} on ${ctx.channelId}`,
        );
        // Return modified content with secrets redacted.
        // We redact rather than cancel so the user still gets a response
        // (just with secrets replaced), and we can see what was attempted.
        return { content };
      }

      // No secrets found — pass through unchanged.
      return undefined;
    },
    { priority: 1000 }, // High priority — run before any other message_sending hooks.
  );
}
