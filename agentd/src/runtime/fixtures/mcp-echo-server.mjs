// Minimal stdio MCP server for tests: one `echo` tool that returns its server name.
import { createInterface } from "node:readline";

const serverName = process.argv[2] ?? "echo";
const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);

createInterface({ input: process.stdin }).on("line", (line) => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  if (request.id === undefined) return;
  switch (request.method) {
    case "initialize":
      send({ id: request.id, result: { protocolVersion: request.params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: serverName, version: "1.0.0" } } });
      return;
    case "tools/list":
      send({ id: request.id, result: { tools: [{ name: "echo", description: "Echo the server name", inputSchema: { type: "object", properties: {} } }] } });
      return;
    case "tools/call":
      send({ id: request.id, result: { content: [{ type: "text", text: `echo from ${serverName}` }] } });
      return;
    case "ping":
      send({ id: request.id, result: {} });
      return;
    default:
      send({ id: request.id, error: { code: -32601, message: `Method not found: ${request.method}` } });
  }
});
