import {
type AgentSessionServices,
type CreateAgentSessionRuntimeFactory,
type CreateAgentSessionServicesOptions,
type ToolDefinition,
createAgentSessionFromServices,
createAgentSessionRuntime,
createAgentSessionServices,
createEventBus,
getAgentDir,
SessionManager
} from "@earendil-works/pi-coding-agent";
import type { BuiltPrompt } from "../prompt-builder.js";
import { type DialogMethod } from "../runtime/extension-ui-bridge.js";
import type { AgentRuntime,RuntimeGlobalModelScopeChange,RuntimeModelOption,RuntimeSessionHandle,ThinkingLevel } from "./types.js";
import { PiInputRewriteObserver } from "./pi-input-rewrite-observer.js";
import { logAgentd } from "../local-log.js";
import {
availableModelsFromServices,modelFromServices,
normalizeModelPattern,
runtimeModelOptionFromModel,scopedModelsFromServices,
synchronizeScopedModelsForCycling,
validateExactModelScope
} from "./pi-model-resolution.js";
import { PiGlobalSettingsCASStorage } from "./pi-global-settings-cas-storage.js";
import {
branchTranscriptFromEntries
} from "./pi-sdk-runtime-helpers.js";
import { writeFilePathFromRawArgs } from "./write-file-path.js";
import { PiSdkRuntimeSession } from "./pi-sdk-runtime-session.js";

// Re-exported so existing importers keep working.
export { branchTranscriptFromEntries, writeFilePathFromRawArgs };

// This is a deliberately narrow host-extension contract. Each PiSdkRuntime handle
// owns a separate EventBus, so a PTT pause can never affect another Pickle.
export const PICKY_EXTERNAL_DELIVERY_PAUSE_STATE_CHANNEL = "picky.external-delivery.pause-state";
export const PICKY_EXTERNAL_DELIVERY_PAUSE_QUERY_CHANNEL = "picky.external-delivery.pause-query";

interface PiSdkRuntimeOptions {
  agentDir?: string;
  createRuntime?: typeof createAgentSessionRuntime;
  createServices?: typeof createAgentSessionServices;
  createSessionFromServices?: typeof createAgentSessionFromServices;
  getAgentDir?: typeof getAgentDir;
  resourceLoaderOptions?: CreateAgentSessionServicesOptions["resourceLoaderOptions"];
  customTools?: ToolDefinition[];
  thinkingLevel?: ThinkingLevel;
  modelPattern?: string;
  disableBlockingDialogs?: boolean;
  allowedBlockingDialogMethods?: readonly DialogMethod[];
}

export class PiSdkRuntime implements AgentRuntime {
  private thinkingLevel?: ThinkingLevel;
  private modelPattern?: string;
  private customTools: ToolDefinition[];
  // One PiSdkRuntime owns the primary Pi settings manager. Queue the complete
  // reload/CAS/write/flush transaction so two popovers cannot both accept the
  // same revision between their independent reloads.
  private globalModelScopeWriteChain: Promise<void> = Promise.resolve();

  constructor(private readonly options: PiSdkRuntimeOptions = {}) {
    this.thinkingLevel = options.thinkingLevel;
    this.modelPattern = normalizeModelPattern(options.modelPattern);
    this.customTools = options.customTools ?? [];
  }

  setThinkingLevel(level: ThinkingLevel): void {
    this.thinkingLevel = level;
  }

  /// Replace the customTools list used at the next session creation. Existing
  /// sessions keep their original tools until the supervisor aborts and resets
  /// the main handle.
  setCustomTools(tools: ToolDefinition[]): void {
    this.customTools = tools;
  }

  setModelPattern(pattern?: string): boolean {
    const next = normalizeModelPattern(pattern);
    const changed = this.modelPattern !== next;
    this.modelPattern = next;
    return changed;
  }

  async listAvailableModels(options: { cwd?: string } = {}): Promise<RuntimeModelOption[]> {
    const services = await this.createServices(options.cwd);
    const available = await availableModelsFromServices(services);
    return available.map(runtimeModelOptionFromModel);
  }

  async setGlobalModelScope(change: RuntimeGlobalModelScopeChange): Promise<void> {
    const write = this.globalModelScopeWriteChain.then(() => this.persistGlobalModelScope(change));
    // A rejected mutation must not poison the queue for the next user action.
    this.globalModelScopeWriteChain = write.catch(() => {});
    return await write;
  }

  private async persistGlobalModelScope(change: RuntimeGlobalModelScopeChange): Promise<void> {
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();
    const patterns = change.mode === "all" ? undefined : validateExactModelScope(change.patterns ?? []);
    await new PiGlobalSettingsCASStorage(agentDir).setEnabledModels(change.expectedRevision, patterns);
  }

  private async createServices(cwd?: string): Promise<AgentSessionServices> {
    const createServices = this.options.createServices ?? createAgentSessionServices;
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();
    return await createServices({ cwd: cwd ?? process.cwd(), agentDir, resourceLoaderOptions: this.options.resourceLoaderOptions });
  }

  async create(prompt: BuiltPrompt, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime create", { sessionId: options.sessionId, cwd: options.cwd, promptChars: prompt.text.length, images: prompt.imagePaths?.length ?? 0 });
    const handle = await this.createHandle(options);
    handle.scheduleInitialPrompt(prompt);
    return handle;
  }

  async prewarm(options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime prewarm", { sessionId: options.sessionId, cwd: options.cwd });
    const handle = await this.createHandle(options);
    setTimeout(() => handle.reportDiagnostics(), 0);
    return handle;
  }

  async resume(sessionFilePath: string, options: { cwd?: string; sessionId?: string }): Promise<RuntimeSessionHandle> {
    logAgentd("pi runtime resume", { sessionId: options.sessionId, cwd: options.cwd, sessionFilePath });
    const handle = await this.createHandle({ ...options, sessionFilePath });
    setTimeout(() => handle.reportDiagnostics(), 0);
    return handle;
  }

  private async createHandle(options: { cwd?: string; sessionId?: string; sessionFilePath?: string }): Promise<PiSdkRuntimeSession> {
    const cwd = options.cwd ?? process.cwd();
    const sessionId = options.sessionId ?? "picky-pi-session";
    let sessionHandle: PiSdkRuntimeSession | undefined;
    const externalDeliveryEventBus = createEventBus();
    let externalDeliveryPaused = false;
    externalDeliveryEventBus.on(PICKY_EXTERNAL_DELIVERY_PAUSE_QUERY_CHANNEL, () => {
      externalDeliveryEventBus.emit(PICKY_EXTERNAL_DELIVERY_PAUSE_STATE_CHANNEL, { paused: externalDeliveryPaused });
    });
    const setExternalDeliveryPaused = (paused: boolean): void => {
      externalDeliveryPaused = paused;
      externalDeliveryEventBus.emit(PICKY_EXTERNAL_DELIVERY_PAUSE_STATE_CHANNEL, { paused });
    };
    const inputRewriteObserver = new PiInputRewriteObserver((deliveryID, finalText) => {
      sessionHandle?.recordExpectedInputAlias(deliveryID, finalText);
    });
    const createServices = this.options.createServices ?? createAgentSessionServices;
    const createSessionFromServices = this.options.createSessionFromServices ?? createAgentSessionFromServices;
    const createRuntimeImpl = this.options.createRuntime ?? createAgentSessionRuntime;
    const agentDir = this.options.agentDir ?? (this.options.getAgentDir ?? getAgentDir)();
    const customTools = this.customTools;

    const createRuntime: CreateAgentSessionRuntimeFactory = async ({ cwd: runtimeCwd, sessionManager, sessionStartEvent }) => {
      const resourceLoaderOptions = this.options.resourceLoaderOptions;
      const services = await createServices({
        cwd: runtimeCwd,
        agentDir,
        resourceLoaderOptions: {
          ...resourceLoaderOptions,
          // Do not inherit a process-level bus. External delivery policy belongs to
          // this exact Pi session and must survive extension reload through its own bus.
          eventBus: externalDeliveryEventBus,
          extensionFactories: [
            ...(resourceLoaderOptions?.extensionFactories ?? []),
            inputRewriteObserver.inlineExtension,
          ],
        },
      });
      // Picky defaults establish only a brand-new Pickle. Pi transcript restoration
      // is authoritative when resuming, including its model and thinking level.
      const appliesNewPickleDefaults = options.sessionFilePath === undefined;
      const fixedModel = appliesNewPickleDefaults
        ? await modelFromServices(services, this.modelPattern)
        : undefined;
      // Resolve Pi's effective scope independently of Picky's fresh-session
      // default. A fixed initial model must not shrink later model cycling.
      const scopedModels = await scopedModelsFromServices(services);
      const sessionResult = await createSessionFromServices({
        services,
        sessionManager,
        sessionStartEvent,
        customTools,
        ...(appliesNewPickleDefaults && this.thinkingLevel ? { thinkingLevel: this.thinkingLevel } : {}),
        // Explicitly pass [] for Pi's all-model semantics. This prevents a
        // fresh Picky default from becoming an accidental one-model scope.
        ...(appliesNewPickleDefaults ? { scopedModels } : {}),
        ...(fixedModel ? { model: fixedModel } : {}),
      });
      synchronizeScopedModelsForCycling(sessionResult.session, scopedModels);
      return {
        ...sessionResult,
        services,
        diagnostics: services.diagnostics,
      };
    };

    const runtime = await createRuntimeImpl(createRuntime, {
      cwd,
      agentDir,
      sessionManager: options.sessionFilePath ? SessionManager.open(options.sessionFilePath, undefined, cwd) : SessionManager.create(cwd),
      // A host-created handle for an existing JSONL is a documented Pi resume,
      // not a new startup. Extensions such as cron use this event to transfer a
      // same-process draining lease to the successor without opening a second
      // writer for the transcript.
      ...(options.sessionFilePath ? {
        sessionStartEvent: {
          type: "session_start" as const,
          reason: "resume" as const,
          previousSessionFile: options.sessionFilePath,
        },
      } : {}),
    });

    const handle = new PiSdkRuntimeSession(
      sessionId,
      runtime,
      options.sessionFilePath === undefined ? this.thinkingLevel : undefined,
      {
        disableBlockingDialogs: this.options.disableBlockingDialogs ?? false,
        allowedBlockingDialogMethods: this.options.allowedBlockingDialogMethods,
      },
      inputRewriteObserver,
      setExternalDeliveryPaused,
    );
    sessionHandle = handle;
    await handle.bindCurrentSession();
    return handle;
  }
}
