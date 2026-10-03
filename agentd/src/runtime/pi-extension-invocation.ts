import { randomUUID } from "node:crypto";
import type { AgentSession } from "@earendil-works/pi-coding-agent";
import type { ExtensionUiBridge } from "./extension-ui-bridge.js";
import type { RuntimeExtensionCommandResult, RuntimeExtensionToolResult } from "./types.js";

/**
 * Runs extension commands and tools on the host's behalf, outside any agent turn.
 *
 * Picky uses this for housekeeping the user triggered through the HUD (managing scheduled
 * messages, for example). Nothing is journaled, so no user bubble or command receipt appears
 * in the conversation, and the extension's own `ctx.ui.notify` toasts are dropped for the
 * duration of the call: the HUD already reflects the outcome.
 */
export class PiExtensionInvoker {
  constructor(
    private readonly session: () => AgentSession,
    private readonly uiBridge: () => ExtensionUiBridge,
  ) {}

  /** Pi's own session id, which extensions key their persisted state on. */
  sessionId(): string | undefined {
    try {
      return this.session().sessionManager.getSessionId();
    } catch {
      return undefined;
    }
  }

  hasCommand(name: string): boolean {
    try {
      return this.session().extensionRunner.getRegisteredCommands().some((command) => command.invocationName === name);
    } catch {
      return false;
    }
  }

  hasTool(name: string): boolean {
    try {
      return Boolean(this.session().extensionRunner.getToolDefinition(name));
    } catch {
      return false;
    }
  }

  /**
   * Command handlers return nothing, so their outcome ends up in the `ctx.ui.notify` text
   * Picky suppresses. It is returned here because that text is the only way to tell, for
   * example, a cancelled schedule from one that had already fired.
   */
  async runCommand(name: string, args: string): Promise<RuntimeExtensionCommandResult> {
    const runner = this.session().extensionRunner;
    const command = runner.getRegisteredCommands().find((entry) => entry.invocationName === name);
    if (!command) throw new Error(`Extension command is not registered: /${name}`);
    const context = runner.createCommandContext();
    const { notifications } = await this.uiBridge().withCapturedNotifications(() => command.handler(args, context));
    return { notifications };
  }

  async runTool(name: string, params: Record<string, unknown>): Promise<RuntimeExtensionToolResult> {
    const runner = this.session().extensionRunner;
    const definition = runner.getToolDefinition(name);
    if (!definition) throw new Error(`Extension tool is not registered: ${name}`);
    // Tools receive the same context Pi builds for a model-issued call, so nested `ctx.tools` /
    // `ctx.executeTool` work exactly as during a turn. The call id marks it as Picky-initiated.
    const toolCallId = `picky-${randomUUID()}`;
    const context = runner.createToolContext(toolCallId, undefined);
    const result = await this.uiBridge().withSuppressedNotifications(() => (
      definition.execute(toolCallId, params, undefined, undefined, context)
    ));
    const firstBlock = result.content?.[0];
    return {
      isError: result.isError === true,
      text: firstBlock?.type === "text" ? firstBlock.text ?? "" : "",
      ...(result.details && typeof result.details === "object" ? { details: result.details as Record<string, unknown> } : {}),
    };
  }
}
