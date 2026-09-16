import type { RuntimeCreateOptions, ThinkingLevel } from "../runtime/types.js";
import { logAgentd } from "../local-log.js";
import type { SettingsControlBroker } from "./settings-control-broker.js";

const thinkingLevels = new Set<string>(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);

/** Snapshot app defaults without changing the runtime shared by existing sessions. */
export async function readNewPickleRuntimeDefaults(settings: Pick<SettingsControlBroker, "request">): Promise<RuntimeCreateOptions> {
  const read = async (key: string): Promise<string | undefined> => {
    try {
      const result = await settings.request({ action: "get", key });
      if (typeof result.value === "string"
        && (key === "pickleAgent.model" || result.value === "automatic" || thinkingLevels.has(result.value))) {
        return result.value;
      }
      logAgentd("new Pickle runtime default missing or invalid; preserving startup default", { key });
    } catch (error) {
      logAgentd("new Pickle runtime default unavailable; preserving startup default", { key, message: error instanceof Error ? error.message : String(error) });
    }
    return undefined;
  };
  const [model, thinking] = await Promise.all([read("pickleAgent.model"), read("pickleAgent.thinkingLevel")]);
  return {
    ...(model !== undefined ? { modelPattern: model.trim() || null } : {}),
    ...(thinking !== undefined ? { thinkingLevel: thinking === "automatic" ? null : thinking as ThinkingLevel } : {}),
  };
}
