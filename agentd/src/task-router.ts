import type { PickyContextPacket } from "./protocol.js";

export type TaskRouteDecision =
  | { route: "quick_reply"; reply: string }
  | { route: "handoff"; reason?: string };

export interface TaskRouter {
  route(context: PickyContextPacket): Promise<TaskRouteDecision>;
}

export class ConservativeMockTaskRouter implements TaskRouter {
  async route(context: PickyContextPacket): Promise<TaskRouteDecision> {
    const immediate = immediateQuickReply(context);
    if (immediate) return { route: "quick_reply", reply: immediate };
    return { route: "handoff", reason: "Mock router only answers trivial microphone/screen checks." };
  }
}


export function immediateQuickReply(context: PickyContextPacket): string | undefined {
  const text = context.transcript?.trim() ?? "";
  if (isScreenVisibilityCheck(text)) {
    const count = context.screenshots.length;
    if (count > 0) return `네, 현재 화면 캡처 ${count}장을 받고 있어요.`;
    return "아직 화면 캡처는 받지 못했어요. 화면 기록 권한이나 캡처 상태를 확인해볼게요.";
  }
  return undefined;
}

function isScreenVisibilityCheck(text: string): boolean {
  const normalized = text.replace(/[?？!.。~\s,，]/g, "").toLowerCase();
  if (!normalized) return false;
  if (/^(아+)?(내|제|이|현재)?화면(이)?(보여|보이나|보입니까|보여요|보여줘)$/.test(normalized)) return true;
  if (/^(아+)?(이거|이것|여기)(보여|보이나|보여요)$/.test(normalized)) return true;
  if (/^(canyousee|seemyscreen|screenvisible)/.test(normalized)) return true;
  return false;
}

