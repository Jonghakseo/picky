/**
 * What actually leaves the gateway when a phone taps a Task or delegation
 * control in the Picky room's conversation.
 *
 * The stakes are the same as for session commands: a mistyped payload must
 * never reach the daemon, a Task control must arrive as the daemon command the
 * Mac would send, and an unreachable daemon must say so instead of silently
 * dropping the tap.
 */
import { describe, expect, it } from "vitest";

import type { AuditEvent, AuditLog } from "./audit.js";
import { executeCommand, RemoteCommandError, type CommandContext } from "./command-executor.js";
import type { DaemonCommand, DaemonLink } from "./daemon-link.js";
import { RemoteCommandSchema, type RemoteCommand } from "../remote/protocol.js";

const DEVICE = "device-1";

interface Harness {
  context: CommandContext;
  sent: DaemonCommand[];
  hub: unknown[];
  audit: AuditEvent[];
}

function harness(options: { primary?: boolean; sendFails?: string } = {}): Harness {
  const sent: DaemonCommand[] = [];
  const hub: unknown[] = [];
  const audit: AuditEvent[] = [];
  const primary = {
    send: async (command: DaemonCommand) => {
      if (options.sendFails) throw new Error(options.sendFails);
      sent.push(command);
    },
  } as unknown as DaemonLink;
  return {
    sent,
    hub,
    audit,
    context: {
      hubConnected: true,
      hubRequest: async (_deviceId: string, request: unknown) => {
        hub.push(request);
        return undefined;
      },
      ownerFor: () => undefined,
      primaryDaemon: () => (options.primary === false ? undefined : primary),
      resolveUploads: async () => [],
      waitForSession: async () => true,
      audit: { record: (event: AuditEvent) => audit.push(event) } as unknown as AuditLog,
      onMainSend: () => {},
      onMainSettled: () => {},
    },
  };
}

describe("main Task commands from a paired device", () => {
  it("reach the primary daemon as the daemon command, and never as a hub request", async () => {
    const { context, sent, hub } = harness();
    await executeCommand(context, DEVICE, { type: "main.task.control", taskId: "t1", action: "stop" });
    await executeCommand(context, DEVICE, { type: "main.delegation.resolve", decisionId: "d1", choice: "pickle" });
    expect(sent).toEqual([
      { type: "controlMainTask", taskId: "t1", action: "stop" },
      { type: "resolveMainDelegation", decisionId: "d1", choice: "pickle" },
    ]);
    // Nothing goes through the app, so a phone tap cannot capture the Mac
    // screen, change its selected conversation or start desktop speech.
    expect(hub).toEqual([]);
  });

  it("are recorded in the audit log against the Picky room", async () => {
    const { context, audit } = harness();
    await executeCommand(context, DEVICE, { type: "main.task.control", taskId: "t1", action: "resume" });
    expect(audit).toEqual([{ action: "command", deviceId: DEVICE, type: "main.task.control", sessionId: "main" }]);
  });

  it("report the Mac as offline rather than dropping the tap", async () => {
    const offlineHub = harness();
    offlineHub.context.hubConnected = false;
    await expect(executeCommand(offlineHub.context, DEVICE, { type: "main.task.control", taskId: "t1", action: "stop" }))
      .rejects.toMatchObject({ code: "macOffline" });

    const noPrimary = harness({ primary: false });
    await expect(executeCommand(noPrimary.context, DEVICE, { type: "main.delegation.resolve", decisionId: "d1", choice: "task" }))
      .rejects.toMatchObject({ code: "macOffline" });
  });

  it("surface a daemon refusal to the phone instead of reporting success", async () => {
    const { context } = harness({ sendFails: "unknown task" });
    const error = await executeCommand(context, DEVICE, { type: "main.task.control", taskId: "gone", action: "stop" })
      .catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(RemoteCommandError);
    expect((error as RemoteCommandError).toRemoteError()).toEqual({ code: "rejected", message: "unknown task" });
  });
});

describe("validation before anything reaches the daemon", () => {
  it("accepts the documented payloads and refuses everything else", () => {
    const valid: RemoteCommand[] = [
      { type: "main.task.control", taskId: "t1", action: "stop" },
      { type: "main.task.control", taskId: "t1", action: "resume" },
      { type: "main.delegation.resolve", decisionId: "d1", choice: "pickle" },
      { type: "main.delegation.resolve", decisionId: "d1", choice: "task" },
      { type: "main.delegation.resolve", decisionId: "d1", choice: "cancel" },
    ];
    for (const command of valid) expect(RemoteCommandSchema.safeParse(command).success).toBe(true);

    const invalid = [
      { type: "main.task.control", taskId: "t1", action: "pause" },
      { type: "main.task.control", taskId: "", action: "stop" },
      { type: "main.task.control", action: "stop" },
      { type: "main.delegation.resolve", decisionId: "d1", choice: "yes" },
      { type: "main.delegation.resolve", decisionId: "d1" },
      { type: "main.delegation.resolve", decisionId: "x".repeat(201), choice: "task" },
    ];
    for (const command of invalid) expect(RemoteCommandSchema.safeParse(command).success).toBe(false);
  });
});
