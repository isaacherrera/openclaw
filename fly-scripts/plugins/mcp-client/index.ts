/**
 * OpenClaw MCP Client Plugin
 *
 * Connects to MCP servers via raw HTTP (JSON-RPC 2.0) and exposes
 * a gateway tool (mcp_<serverName>) for each configured server.
 * Zero npm dependencies - uses only Node built-in fetch.
 */

interface McpServer {
  name: string;
  url: string;
  apiKeyEnv?: string;
}

interface McpTool {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: string;
  id: number;
  result?: Record<string, unknown>;
  error?: { code: number; message: string; data?: unknown };
}

// Cache discovered tools per server
const toolCaches = new Map<string, McpTool[]>();
const initializedServers = new Set<string>();
let requestId = 0;

function nextId(): number {
  return ++requestId;
}

function buildHeaders(server: McpServer): Record<string, string> {
  const h: Record<string, string> = { "Content-Type": "application/json" };
  if (server.apiKeyEnv) {
    const key = process.env[server.apiKeyEnv];
    if (key) {
      h["x-api-key"] = key;
    } else {
      console.warn(`[mcp-client] ${server.apiKeyEnv} env var not set for server ${server.name}`);
    }
  }
  return h;
}

async function rpc(
  server: McpServer,
  method: string,
  params?: Record<string, unknown>,
): Promise<JsonRpcResponse> {
  const body: Record<string, unknown> = {
    jsonrpc: "2.0",
    id: nextId(),
    method,
  };
  if (params) {
    body.params = params;
  }

  const res = await fetch(server.url, {
    method: "POST",
    headers: buildHeaders(server),
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`MCP ${server.name} ${method} HTTP ${res.status}: ${text}`);
  }

  return res.json() as Promise<JsonRpcResponse>;
}

async function ensureInitialized(server: McpServer): Promise<void> {
  if (initializedServers.has(server.name)) {
    return;
  }
  await rpc(server, "initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "openclaw-mcp-client", version: "1.0.0" },
  });
  // MCP protocol requires notifications/initialized after initialize
  // Notifications have no id field and expect no response
  await fetch(server.url, {
    method: "POST",
    headers: buildHeaders(server),
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/initialized",
    }),
  });
  initializedServers.add(server.name);
}

async function discoverTools(server: McpServer): Promise<McpTool[]> {
  const cached = toolCaches.get(server.name);
  if (cached) {
    return cached;
  }

  await ensureInitialized(server);
  const resp = await rpc(server, "tools/list");
  const tools = ((resp.result?.tools as McpTool[]) ?? []).map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: t.inputSchema,
  }));
  toolCaches.set(server.name, tools);
  return tools;
}

async function callTool(
  server: McpServer,
  toolName: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  await ensureInitialized(server);
  const resp = await rpc(server, "tools/call", {
    name: toolName,
    arguments: args,
  });
  if (resp.error) {
    throw new Error(`MCP tool ${toolName} error (${resp.error.code}): ${resp.error.message}`);
  }
  return resp.result;
}

// --- Plugin entry point ---

export default function register(api: {
  pluginConfig: { servers?: McpServer[] };
  registerTool: (
    factory: () => {
      name: string;
      description: string;
      parameters: Record<string, unknown>;
      execute: (params: Record<string, unknown>) => Promise<unknown>;
    },
  ) => void;
  onHook?: (hook: string, handler: () => void) => void;
}) {
  const servers = api.pluginConfig.servers ?? [];

  if (servers.length === 0) {
    console.warn("[mcp-client] No servers configured, skipping.");
    return;
  }

  for (const server of servers) {
    api.registerTool(() => ({
      name: `mcp_${server.name}`,
      description: `Gateway to ${server.name} MCP server. Use action "list" to discover tools, or "call" to invoke a tool by name.`,
      parameters: {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ["list", "call"],
            description:
              'Action to perform: "list" to discover available tools, "call" to invoke a tool.',
          },
          tool: {
            type: "string",
            description: 'Tool name to call (required when action is "call").',
          },
          arguments: {
            type: "object",
            description: 'Arguments to pass to the tool (used when action is "call").',
            additionalProperties: true,
          },
        },
        required: ["action"],
      },
      execute: async (params: Record<string, unknown>) => {
        const action = params.action as string;

        if (action === "list") {
          const tools = await discoverTools(server);
          return {
            server: server.name,
            tools: tools.map((t) => ({
              name: t.name,
              description: t.description,
            })),
          };
        }

        if (action === "call") {
          const toolName = params.tool as string;
          if (!toolName) {
            throw new Error('Missing "tool" parameter for call action.');
          }
          const args = (params.arguments as Record<string, unknown>) ?? {};
          return await callTool(server, toolName, args);
        }

        throw new Error(`Unknown action "${action}". Use "list" or "call".`);
      },
    }));

    console.log(`[mcp-client] Registered gateway tool: mcp_${server.name}`);
  }

  // Clear caches on gateway stop
  if (api.onHook) {
    api.onHook("gateway_stop", () => {
      toolCaches.clear();
      initializedServers.clear();
      requestId = 0;
      console.log("[mcp-client] Caches cleared on gateway stop.");
    });
  }
}
