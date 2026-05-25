import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import type { BuiltPrompt } from "../prompt-builder.js";
import type { MainAgentRuntimeMode, PickyContextPacket } from "../protocol.js";
import type { AgentRuntime, MainRealtimeHistoryProvider, MainRealtimeRuntime, MainRealtimeUserMemoryProvider, RuntimeModelOption, RuntimeSessionHandle, ThinkingLevel } from "./types.js";

interface SelectableMainRuntimeOptions {
  initialMode: MainAgentRuntimeMode;
  piRuntime: AgentRuntime;
  realtimeRuntime: MainRealtimeRuntime;
}

/**
 * Code-level isolation boundary for Picky runtime selection.
 *
 * Pi remains the default delegate and sees exactly the same AgentRuntime calls as
 * before unless the user explicitly switches the mode to `openai-realtime`.
 * Realtime-only voice streaming methods are rejected while mode is `pi`, which
 * prevents accidental side effects on the existing Pi STT/TTS flow.
 */
export class SelectableMainRuntime implements MainRealtimeRuntime {
  private mode: MainAgentRuntimeMode;

  constructor(private readonly options: SelectableMainRuntimeOptions) {
    this.mode = options.initialMode;
  }

  getMainAgentRuntimeMode(): MainAgentRuntimeMode {
    return this.mode;
  }

  setMainAgentRuntimeMode(mode: MainAgentRuntimeMode): boolean {
    const changed = this.mode !== mode;
    this.mode = mode;
    return changed;
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.options.piRuntime.setThinkingLevel?.(level);
    this.options.realtimeRuntime.setThinkingLevel?.(level);
  }

  setModelPattern(pattern?: string): boolean {
    return this.options.piRuntime.setModelPattern?.(pattern) ?? false;
  }

  setCustomTools(tools: ToolDefinition[]): void {
    this.options.piRuntime.setCustomTools?.(tools);
  }

  listAvailableModels(options?: { cwd?: string }): Promise<RuntimeModelOption[]> {
    return this.options.piRuntime.listAvailableModels?.(options) ?? Promise.resolve([]);
  }

  create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    return this.currentRuntime().create(prompt, options);
  }

  prewarm(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    const runtime = this.currentRuntime();
    if (!runtime.prewarm) throw new Error("Selected main runtime cannot prewarm");
    return runtime.prewarm(options);
  }

  resume(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    const runtime = this.currentRuntime();
    if (!runtime.resume) throw new Error("Selected main runtime cannot resume");
    return runtime.resume(sessionFilePath, options);
  }

  configureMainRealtimeAuth(config: Parameters<MainRealtimeRuntime["configureMainRealtimeAuth"]>[0]): Promise<void> | void {
    return this.options.realtimeRuntime.configureMainRealtimeAuth(config);
  }

  async beginMainRealtimeVoiceTurn(turn: Parameters<MainRealtimeRuntime["beginMainRealtimeVoiceTurn"]>[0]): Promise<void> {
    this.assertRealtimeMode();
    return this.options.realtimeRuntime.beginMainRealtimeVoiceTurn(turn);
  }

  async appendMainRealtimeInputAudio(inputId: string, audioBase64: string): Promise<void> {
    this.assertRealtimeMode();
    return this.options.realtimeRuntime.appendMainRealtimeInputAudio(inputId, audioBase64);
  }

  async commitMainRealtimeVoiceTurn(inputId: string, context?: PickyContextPacket): Promise<void> {
    this.assertRealtimeMode();
    return this.options.realtimeRuntime.commitMainRealtimeVoiceTurn(inputId, context);
  }

  cancelMainRealtimeVoiceTurn(inputId?: string, playedAudioMs?: number): Promise<void> {
    if (this.mode !== "openai-realtime") return Promise.resolve();
    return this.options.realtimeRuntime.cancelMainRealtimeVoiceTurn(inputId, playedAudioMs);
  }

  setMainRealtimeHistoryProvider(provider: MainRealtimeHistoryProvider | undefined): void {
    this.options.realtimeRuntime.setMainRealtimeHistoryProvider?.(provider);
  }

  setMainRealtimeUserMemoryProvider(provider: MainRealtimeUserMemoryProvider | undefined): void {
    this.options.realtimeRuntime.setMainRealtimeUserMemoryProvider?.(provider);
  }

  refreshUserMemoryInstructions(): void {
    this.options.realtimeRuntime.refreshUserMemoryInstructions?.();
  }

  refreshConversationInstructions(): void {
    this.options.realtimeRuntime.refreshConversationInstructions?.();
  }

  refreshCodexQuota(): Promise<void> {
    return this.options.realtimeRuntime.refreshCodexQuota?.() ?? Promise.resolve();
  }

  setMainAgentTTSEnabled(enabled: boolean): void {
    this.options.realtimeRuntime.setMainAgentTTSEnabled?.(enabled);
  }

  private currentRuntime(): AgentRuntime {
    return this.mode === "openai-realtime" ? this.options.realtimeRuntime : this.options.piRuntime;
  }

  private assertRealtimeMode(): void {
    if (this.mode !== "openai-realtime") throw new Error("OpenAI Realtime main runtime is not selected");
  }
}
