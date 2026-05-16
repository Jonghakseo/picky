import type { PickyAgentSession } from "../protocol.js";

export function mergeArtifacts(existing: PickyAgentSession["artifacts"], incoming: PickyAgentSession["artifacts"]): PickyAgentSession["artifacts"] {
  const byId = new Map(existing.map((artifact) => [artifact.id, artifact]));
  for (const artifact of incoming) byId.set(artifact.id, artifact);
  return [...byId.values()];
}
