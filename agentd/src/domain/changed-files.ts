import type { PickyAgentSession } from "../protocol.js";

export function mergeChangedFiles(existing: PickyAgentSession["changedFiles"], incoming: PickyAgentSession["changedFiles"]): PickyAgentSession["changedFiles"] {
  const byPath = new Map(existing.map((file) => [file.path, file]));
  for (const file of incoming) byPath.set(file.path, file);
  return [...byPath.values()];
}
