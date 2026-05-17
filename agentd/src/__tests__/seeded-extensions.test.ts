//
// seeded-extensions.test.ts
//
// Guarantees the TypeScript blobs embedded inside Picky's Swift workspace
// seeder (`Picky/App/PickyWorkspaceSeeder.swift`) stay valid under strict
// TypeScript. The Swift compiler treats those literals as opaque strings, so
// without this harness a typo in a seeded extension would only surface on the
// first user launch after release. Each entry below extracts a Swift raw
// string constant, applies Swift's leading-indent stripping, drops it into a
// scratch directory under `agentd/` (so Node's module resolution finds
// typebox + @earendil-works/pi-coding-agent), and runs `tsc --noEmit --strict`
// against it. Add new seeded extensions to `SEEDED_EXTENSIONS` so future
// additions are covered automatically.
//

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const require_ = createRequire(import.meta.url);

const AGENTD_DIR = resolve(__dirname, "../..");
const REPO_ROOT = resolve(AGENTD_DIR, "..");
const SEEDER_SWIFT_PATH = join(REPO_ROOT, "Picky/App/PickyWorkspaceSeeder.swift");

interface SeededExtension {
  filename: string;
  swiftConstant: string;
  /** Sanity checks that the extracted body actually carries the expected code. */
  mustContain: readonly string[];
}

const SEEDED_EXTENSIONS: readonly SeededExtension[] = [
  {
    filename: "picky-tell-plan.ts",
    swiftConstant: "defaultTellPlanExtensionSource",
    mustContain: [
      `import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";`,
      `import { Type } from "typebox";`,
      `pi.registerTool({`,
      `__pickyAgentd`,
      `block: true`,
      `pi.on("agent_start"`,
      `"picky_tell_plan"`,
    ],
  },
];

/**
 * Extracts a Swift `#"""..."""#` raw multiline literal assigned to a named
 * constant and reproduces the string Swift would synthesize. Swift strips the
 * leading whitespace equal to the indentation of the closing `"""#`; the
 * seeder writes its constants with the closing delimiter indented exactly four
 * spaces, so we strip the first four spaces from each line.
 */
function extractSwiftRawString(source: string, constantName: string): string {
  const marker = `${constantName}: String = #"""\n`;
  const start = source.indexOf(marker);
  if (start === -1) throw new Error(`marker not found in seeder Swift source: ${marker}`);
  const open = start + marker.length;
  const close = source.indexOf('"""#', open);
  if (close === -1) throw new Error(`closing #""" delimiter not found for ${constantName}`);
  const body = source.slice(open, close);
  return body
    .split("\n")
    .map((line) => (line.startsWith("    ") ? line.slice(4) : line))
    .join("\n");
}

describe("seeded picky extensions", () => {
  it.each(SEEDED_EXTENSIONS)(
    "$filename embedded in PickyWorkspaceSeeder type-checks under strict TypeScript",
    ({ filename, swiftConstant, mustContain }) => {
      const swift = readFileSync(SEEDER_SWIFT_PATH, "utf8");
      const ts = extractSwiftRawString(swift, swiftConstant);

      for (const needle of mustContain) {
        expect(ts, `extracted ${filename} is missing expected snippet: ${needle}`).toContain(needle);
      }

      // Scratch dir lives inside agentd/ so Node resolution walks up into
      // agentd/node_modules and finds typebox + @earendil-works/pi-coding-agent.
      const scratchRoot = mkdtempSync(join(AGENTD_DIR, "tmp-seed-check-"));
      try {
        writeFileSync(join(scratchRoot, filename), ts);
        const tsconfig = {
          compilerOptions: {
            target: "ES2022",
            module: "ESNext",
            moduleResolution: "Bundler",
            strict: true,
            noEmit: true,
            skipLibCheck: true,
            esModuleInterop: true,
            types: [],
          },
          include: [filename],
        };
        writeFileSync(join(scratchRoot, "tsconfig.json"), JSON.stringify(tsconfig));

        const tscBin = require_.resolve("typescript/bin/tsc");
        try {
          execFileSync(process.execPath, [tscBin, "-p", "tsconfig.json"], {
            cwd: scratchRoot,
            stdio: "pipe",
          });
        } catch (error) {
          const err = error as { stdout?: Buffer | string; stderr?: Buffer | string; message?: string };
          const stdout = err.stdout?.toString() ?? "";
          const stderr = err.stderr?.toString() ?? "";
          throw new Error(
            `tsc rejected seeded ${filename}.\n\n--- tsc stdout ---\n${stdout}\n--- tsc stderr ---\n${stderr}`.trim(),
          );
        }
      } finally {
        rmSync(scratchRoot, { recursive: true, force: true });
      }
    },
  );
});
