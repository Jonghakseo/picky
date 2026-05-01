import { tmpdir } from "node:os";
import { join } from "node:path";
import { AgentdServer } from "./server.js";
import { SessionStore } from "./session-store.js";
import { SessionSupervisor } from "./session-supervisor.js";
import { MockRuntime } from "./runtime/mock-runtime.js";

const port = Number(process.env.PICKY_AGENTD_PORT ?? 17631);
const token = process.env.PICKY_AGENTD_TOKEN;
const appSupportDir = process.env.PICKY_APP_SUPPORT_DIR ?? join(tmpdir(), "PickyAgentd");

if (!token) {
  console.error("PICKY_AGENTD_TOKEN is required");
  process.exit(1);
}

const supervisor = new SessionSupervisor(new MockRuntime(), new SessionStore(appSupportDir));
await supervisor.load();
const server = new AgentdServer({ port, token, supervisor });
const boundPort = await server.start();
console.log(`picky-agentd listening on 127.0.0.1:${boundPort}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void server.stop().then(() => process.exit(0));
  });
}
