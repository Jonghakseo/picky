import { ArtifactStore, extractGithubPullRequestUrls } from "../artifact-store.js";
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
    const prArtifacts = extractGithubPullRequestUrls([session.finalAnswer, session.lastSummary, ...session.logs, ...session.tools.map((tool) => tool.preview)].filter(Boolean).join("\n"))
      .filter((url) => !session.artifacts.some((artifact) => artifact.url === url))
      .map((url, index) => ({ id: `pr-${index + 1}`, kind: "pr", title: "GitHub PR", url, updatedAt: now }));
    const report = await this.artifactStore.writeSessionReport({ ...session, artifacts: [...session.artifacts, ...prArtifacts] });
    return {
      artifacts: mergeArtifacts([...session.artifacts, ...prArtifacts], [report]),
      emittedArtifacts: [report, ...prArtifacts],
    };
  }
}
