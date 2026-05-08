import { extractSessionLinkArtifacts } from "../artifact-store.js";
import type { PickyAgentSession, PickyArtifact } from "../protocol.js";
import { mergeArtifacts } from "../domain/artifacts.js";

export interface MaterializedTerminalArtifacts {
  artifacts: PickyArtifact[];
  emittedArtifacts: PickyArtifact[];
}

export class ArtifactMaterializer {
  async materializeTerminalArtifacts(session: PickyAgentSession): Promise<MaterializedTerminalArtifacts | undefined> {
    const now = new Date().toISOString();
    const linkArtifacts = extractSessionLinkArtifacts([session.finalAnswer, session.lastSummary, ...session.logs, ...session.tools.map((tool) => tool.preview)].filter(Boolean).join("\n"), now)
      .filter((linkArtifact) => !session.artifacts.some((artifact) => artifact.url === linkArtifact.url));
    if (linkArtifacts.length === 0) return undefined;
    return {
      artifacts: mergeArtifacts(session.artifacts, linkArtifacts),
      emittedArtifacts: linkArtifacts,
    };
  }
}
