/**
 * What a stop ends when background (async) tasks are running.
 * Port of `PickyComposerStopPolicy.choice` (Picky/HUD/Conversation/PickyComposerStopPolicy.swift)
 * and the alert in `PickyStopChoiceAlert.swift`.
 */
import type { PickyAgentSession } from "../../../../src/protocol";

export type StopChoice = "immediate" | "responseOrAll" | "backgroundOnly";
export type AbortScope = "response" | "all";

export type AgentPhase = "idle" | "responding" | "compacting" | "settled";

export function stopChoice(activeBackgroundTaskCount: number, agentPhase: AgentPhase | undefined): StopChoice {
  if (activeBackgroundTaskCount <= 0) return "immediate";
  switch (agentPhase) {
    case "responding":
    case "compacting":
      return "responseOrAll";
    case "idle":
    case "settled":
    case undefined:
      return "backgroundOnly";
  }
}

export function activeBackgroundTaskCount(session: Pick<PickyAgentSession, "asyncWorkSummary">): number {
  return session.asyncWorkSummary?.activeRootCount ?? 0;
}

export function stopChoiceForSession(
  session: Pick<PickyAgentSession, "asyncWorkSummary" | "agentCycle">,
): StopChoice {
  return stopChoice(activeBackgroundTaskCount(session), session.agentCycle?.phase);
}

export interface StopAlertAction {
  /** `null` dismisses the sheet without stopping anything. */
  scope: AbortScope | null;
  titleKey: string;
  role: "default" | "destructive" | "cancel";
}

/** Buttons for the stop sheet, in the order the HUD alert lists them. */
export function stopAlertActions(choice: Exclude<StopChoice, "immediate">): StopAlertAction[] {
  if (choice === "responseOrAll") {
    return [
      { scope: "response", titleKey: "hud.stopChoice.stopResponse", role: "default" },
      { scope: "all", titleKey: "hud.stopChoice.stopAll", role: "destructive" },
      { scope: null, titleKey: "hud.stopChoice.cancel", role: "cancel" },
    ];
  }
  return [
    { scope: "all", titleKey: "hud.stopChoice.stopBackground", role: "destructive" },
    { scope: null, titleKey: "hud.stopChoice.cancel", role: "cancel" },
  ];
}

export function stopAlertMessageKey(choice: Exclude<StopChoice, "immediate">): string {
  return choice === "responseOrAll" ? "hud.stopChoice.message" : "hud.stopChoice.backgroundOnly.message";
}
