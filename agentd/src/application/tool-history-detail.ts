import type { PickyAgentSession } from "../protocol.js";
import { piSessionFilePathForSession } from "../domain/pi-session-files.js";
import { PiToolHistoryReader, type ToolHistoryDetail, type ToolHistoryPart } from "./pi-tool-history-reader.js";

export interface ToolHistoryDetailRequest {
  sessionId: string;
  toolCallId: string;
  expectedSessionFile: string;
  part: ToolHistoryPart;
  cursor?: string;
}

export class ToolHistoryDetailService {
  private readonly reader = new PiToolHistoryReader();
  constructor(private readonly session: (id: string) => Promise<PickyAgentSession | undefined>) {}

  async read(request: ToolHistoryDetailRequest): Promise<ToolHistoryDetail> {
    if (request.toolCallId.startsWith("user-bash-")) return { status: "unsupported", reason: "userBash" };
    const before = await this.session(request.sessionId);
    if (!before) return { status: "unavailable", reason: "unknownSession" };
    const path = piSessionFilePathForSession(before);
    if (!path || path !== request.expectedSessionFile) return { status: "sourceChanged", reason: "sessionSourceChanged" };
    const tool = before.tools.find((entry) => entry.toolCallId === request.toolCallId);
    if (!tool) return { status: "unavailable", reason: "unknownTool" };
    const result = await this.reader.read(path, request.toolCallId, request.part, request.cursor);
    const after = await this.session(request.sessionId);
    if (!after || piSessionFilePathForSession(after) !== path || !after.tools.some((entry) => entry.toolCallId === request.toolCallId)) {
      return { status: "sourceChanged", reason: "sessionSourceChanged" };
    }
    if (result.status === "pending" && tool.status !== "running") {
      const ended = tool.endedAt ? Date.parse(tool.endedAt) : NaN;
      if (!Number.isFinite(ended) || Date.now() - ended > 10_000) return { status: "unavailable", reason: "notPersisted" };
    }
    return result;
  }
}
