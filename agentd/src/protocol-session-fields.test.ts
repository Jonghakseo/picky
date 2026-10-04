import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { renderSessionFieldContracts } from "./codegen/session-field-contracts.js";
import { isClearableMetaPatchField, metaPatchFields, metadataMetaPatchFields } from "./protocol-session-fields.js";

const repoRoot = join(process.cwd(), "..");
const conformanceDir = join(repoRoot, "contracts", "projection", "conformance");

interface Scenario {
  events: Array<{ type: string; projection?: Record<string, unknown>; mutations?: Array<{ type: string; patch?: Record<string, unknown> }> }>;
  expect: { sections: { meta: { value: Record<string, unknown> } } };
}

function scenario(name: string): Scenario {
  return JSON.parse(readFileSync(join(conformanceDir, `${name}.json`), "utf8")) as Scenario;
}

function patches(value: Scenario): Record<string, unknown>[] {
  return value.events.flatMap((event) => event.mutations ?? []).flatMap((mutation) => mutation.patch ? [mutation.patch] : []);
}

describe("session field contracts", () => {
  it("keeps committed generated files in sync with the field table", () => {
    for (const file of renderSessionFieldContracts()) {
      const committed = readFileSync(join(repoRoot, file.path), "utf8");
      expect(committed, `${file.path} is stale; run \`pnpm run gen:contracts\``).toBe(file.content);
    }
  });

  // Both reducers run these scenarios, so covering every field here is what
  // turns "added a field but forgot a client step" into a failing scenario.
  it("covers every metaPatch field in the snapshot, set, and clear conformance scenarios", () => {
    const snapshot = scenario("meta-snapshot-every-field");
    const projection = snapshot.events[0]?.projection ?? {};
    const set = patches(scenario("meta-patch-every-field-set")).at(-1) ?? {};
    const clear = patches(scenario("meta-patch-every-field-clear")).at(-1) ?? {};

    for (const field of metaPatchFields) {
      expect(projection[field], `snapshot projection sets ${field}`).not.toBeUndefined();
      expect(set[field], `set patch sets ${field}`).not.toBeUndefined();
      expect(set[field], `set patch sets ${field}`).not.toBeNull();
      if (isClearableMetaPatchField(field)) expect(clear, `clear patch clears ${field}`).toHaveProperty(field, null);
      else expect(clear, `clear patch cannot clear ${field}`).not.toHaveProperty(field);
    }
    for (const field of metadataMetaPatchFields) {
      expect(snapshot.expect.sections.meta.value, `snapshot expectation lists ${field}`).toHaveProperty(field);
      expect(scenario("meta-patch-every-field-set").expect.sections.meta.value, `set expectation lists ${field}`).toHaveProperty(field);
      expect(scenario("meta-patch-every-field-clear").expect.sections.meta.value, `clear expectation lists ${field}`).toHaveProperty(field);
    }
  });
});
