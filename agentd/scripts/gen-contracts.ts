// Writes the artifacts generated from agentd/src/protocol-session-fields.ts.
// `--check` exits non-zero instead of writing when a committed file is stale.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { renderSessionFieldContracts } from "../src/codegen/session-field-contracts.js";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const check = process.argv.includes("--check");
let stale = 0;
for (const file of renderSessionFieldContracts()) {
  const target = join(repoRoot, file.path);
  let current: string | undefined;
  try { current = readFileSync(target, "utf8"); } catch { current = undefined; }
  if (current === file.content) continue;
  if (check) { console.error(`stale: ${file.path}`); stale += 1; continue; }
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, file.content);
  console.log(`wrote ${file.path}`);
}
if (stale > 0) {
  console.error("Run `pnpm --dir agentd run gen:contracts` and commit the result.");
  process.exit(1);
}
