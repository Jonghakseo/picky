import { ArtifactStore, extractSessionLinkArtifacts } from "../artifact-store.js";
import type { PickyAgentSession, PickyArtifact } from "../protocol.js";
import { mergeArtifacts } from "../domain/artifacts.js";

export interface MaterializedTerminalArtifacts {
  artifacts: PickyArtifact[];
  emittedArtifacts: PickyArtifact[];
}

export class ArtifactMaterializer {
  constructor(private readonly artifactStore?: ArtifactStore) {}

  async materializeTerminalArtifacts(session: PickyAgentSession): Promise<MaterializedTerminalArtifacts | undefined> {
    if (!this.artifactStore) return undefined;
    const now = new Date().toISOString();
    const linkArtifacts = extractSessionLinkArtifacts([session.finalAnswer, session.lastSummary, ...session.logs, ...session.tools.map((tool) => tool.preview)].filter(Boolean).join("\n"), now)
      .filter((linkArtifact) => !session.artifacts.some((artifact) => artifact.url === linkArtifact.url));
    const report = await this.artifactStore.writeSessionReport({ ...session, artifacts: [...session.artifacts, ...linkArtifacts] });
    return {
      artifacts: mergeArtifacts([...session.artifacts, ...linkArtifacts], [report]),
      emittedArtifacts: [report, ...linkArtifacts],
    };
  }
}
