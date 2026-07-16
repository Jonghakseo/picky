import { extractSessionLinkArtifacts } from "../artifact-store.js";
import type { PickyAgentSession, PickyArtifact } from "../protocol.js";
import { mergeArtifacts } from "../domain/artifacts.js";

interface MaterializedTerminalArtifacts {
  artifacts: PickyArtifact[];
  emittedArtifacts: PickyArtifact[];
}

export class ArtifactMaterializer {
  async materializeTerminalArtifacts(session: PickyAgentSession): Promise<MaterializedTerminalArtifacts | undefined> {
    const now = new Date().toISOString();
    // Tool previews and logs can contain documentation examples or truncated URLs. Only
    // conversation content is authoritative enough to surface as a user-facing artifact.
    const linkArtifacts = extractSessionLinkArtifacts([
      session.finalAnswer,
      ...(session.messages ?? [])
        .filter((message) => message.kind === "user_text")
        .map((message) => message.text),
    ].filter(Boolean).join("\n"), now)
      .filter((linkArtifact) => !session.artifacts.some((artifact) => artifact.url === linkArtifact.url));
    if (linkArtifacts.length === 0) return undefined;
    return {
      artifacts: mergeArtifacts(session.artifacts, linkArtifacts),
      emittedArtifacts: linkArtifacts,
    };
  }
}
