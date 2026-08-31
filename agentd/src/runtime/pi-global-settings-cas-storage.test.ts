import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { modelScopeRevision } from "./pi-model-resolution.js";
import { PiGlobalSettingsCASStorage } from "./pi-global-settings-cas-storage.js";
import { PI_MODEL_SCOPE_CONFLICT_CODE, PI_MODEL_SCOPE_CONFLICT_PREFIX, PiModelScopeConflictError } from "./model-scope-errors.js";

describe("PiGlobalSettingsCASStorage", () => {
  it("does not let a stale Picky write overwrite a competing official SettingsManager writer", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-pi-settings-cas-"));
    const agentDir = join(root, "agent");
    const settingsPath = join(agentDir, "settings.json");
    try {
      const initial = SettingsManager.create(root, agentDir);
      initial.setEnabledModels(["anthropic/claude-sonnet"]);
      await initial.flush();
      const staleRevision = modelScopeRevision(["anthropic/claude-sonnet"]);

      // Queue the official Pi writer first, then start Picky's stale mutation in
      // the same event-loop turn. Pi's synchronous storage lock wins this race.
      const officialWriter = SettingsManager.create(root, agentDir);
      officialWriter.setEnabledModels(["openai-codex/gpt-5.5"]);
      const officialWrite = officialWriter.flush();
      await Promise.resolve();

      const pickyWrite = new PiGlobalSettingsCASStorage(agentDir).setEnabledModels(
        staleRevision,
        ["google/gemini-pro"],
      );
      await officialWrite;
      try {
        await pickyWrite;
        expect.unreachable("Expected the stale Picky write to conflict");
      } catch (error) {
        expect(error).toBeInstanceOf(PiModelScopeConflictError);
        expect((error as PiModelScopeConflictError).code).toBe(PI_MODEL_SCOPE_CONFLICT_CODE);
        expect((error as Error).message).toContain(PI_MODEL_SCOPE_CONFLICT_PREFIX);
      }

      const persisted = JSON.parse(await readFile(settingsPath, "utf8")) as { enabledModels?: string[] };
      expect(persisted.enabledModels).toEqual(["openai-codex/gpt-5.5"]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
