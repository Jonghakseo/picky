import type { PickyAgentSession } from "../protocol.js";
import { isTerminalStatus } from "../domain/session-status.js";
import { classificationFingerprint, type PickleClassificationEntry, type PickleStatisticsCategory } from "../domain/pickle-statistics.js";
import type { RuntimeTextCompleter } from "../runtime/types.js";
import type { HubStatisticsService } from "./hub-statistics-service.js";
import { logAgentd } from "../local-log.js";

const INITIAL_DELAY_MS = 30_000;
const INTERVAL_MS = 10 * 60_000;
const STALE_SESSION_MS = 24 * 60 * 60_000;
const BATCH_SIZE = 10;
const MAX_ATTEMPTS = 3;
const VALID_CATEGORIES = new Set<PickleStatisticsCategory>(["fix", "research", "create", "review"]);

interface ClassifierTextCompleter extends RuntimeTextCompleter {
  complete(input: { system: string; prompt: string; maxTokens?: number; signal?: AbortSignal }): Promise<string>;
}

export interface PickleClassifierOptions {
  statistics: HubStatisticsService;
  completer: ClassifierTextCompleter;
  now?: () => Date;
  logger?: (message: string, fields?: Record<string, string | number | undefined>) => void;
}

interface ClassificationCandidate {
  session: PickyAgentSession;
  input: string;
  fingerprint: string;
}

export class PickleClassifier {
  private initialTimer?: NodeJS.Timeout;
  private intervalTimer?: NodeJS.Timeout;
  private running = false;
  /** Invalidates late, uncancellable model completions after disable or shutdown. */
  private lifecycleGeneration = 0;
  private configurationGeneration = 0;
  private classificationEnabled = false;
  private activeAbortController?: AbortController;
  private readonly now: () => Date;
  private readonly logger: (message: string, fields?: Record<string, string | number | undefined>) => void;

  constructor(private readonly options: PickleClassifierOptions) {
    this.now = options.now ?? (() => new Date());
    this.logger = options.logger ?? logAgentd;
  }

  /** Resumes only from an explicitly persisted opt-in. */
  async start(): Promise<void> {
    const generation = this.configurationGeneration;
    await this.resumeIfPersisted(generation);
  }

  /** Called only after the server has durably accepted a consent update. */
  setClassificationEnabled(enabled: boolean): void {
    this.configurationGeneration += 1;
    this.stopScheduledWork();
    this.classificationEnabled = enabled;
    if (enabled) this.schedule();
  }

  stop(): void {
    this.configurationGeneration += 1;
    this.classificationEnabled = false;
    this.stopScheduledWork();
  }

  private async resumeIfPersisted(generation: number): Promise<void> {
    try {
      const state = await this.options.statistics.classificationState();
      if (generation !== this.configurationGeneration || !state.enabled) return;
      this.classificationEnabled = true;
      this.schedule();
    } catch (error) {
      this.logger("pickle classification consent unavailable", { error: messageOf(error) });
    }
  }

  private schedule(): void {
    if (!this.classificationEnabled || this.initialTimer || this.intervalTimer) return;
    this.lifecycleGeneration += 1;
    this.initialTimer = setTimeout(() => {
      this.initialTimer = undefined;
      void this.runOnce();
      if (!this.classificationEnabled) return;
      this.intervalTimer = setInterval(() => { void this.runOnce(); }, INTERVAL_MS);
      this.intervalTimer.unref();
    }, INITIAL_DELAY_MS);
    this.initialTimer.unref();
  }

  private stopScheduledWork(): void {
    this.lifecycleGeneration += 1;
    this.activeAbortController?.abort();
    this.activeAbortController = undefined;
    if (this.initialTimer) clearTimeout(this.initialTimer);
    if (this.intervalTimer) clearInterval(this.intervalTimer);
    this.initialTimer = undefined;
    this.intervalTimer = undefined;
  }

  async runOnce(): Promise<void> {
    if (this.running || !this.classificationEnabled) return;
    this.running = true;
    const lifecycleGeneration = this.lifecycleGeneration;
    const abortController = new AbortController();
    this.activeAbortController = abortController;
    const isCurrent = () => this.classificationEnabled && lifecycleGeneration === this.lifecycleGeneration && !abortController.signal.aborted;
    try {
      const [sessions, state] = await Promise.all([
        this.options.statistics.loadSessions(),
        this.options.statistics.classificationState(),
      ]);
      if (!isCurrent() || !state.enabled) return;
      const classifications = structuredClone(state.classifications);
      const candidates = sessions.flatMap((session) => {
        const input = buildPickleClassificationInput(session);
        const fingerprint = classificationFingerprint(input);
        const existing = classifications.entries[session.id];
        return shouldClassify(session, existing, fingerprint, this.now())
          ? [{ session, input, fingerprint }]
          : [];
      });
      let changed = false;
      for (let index = 0; index < candidates.length; index += BATCH_SIZE) {
        if (!isCurrent()) return;
        changed = (await this.classifyBatch(candidates.slice(index, index + BATCH_SIZE), classifications.entries, isCurrent, abortController.signal)) || changed;
      }
      if (changed && isCurrent()) {
        await this.options.statistics.commitClassifications(state.generation, classifications, isCurrent);
      }
    } catch (error) {
      this.logger("pickle classification skipped", { error: messageOf(error) });
    } finally {
      if (this.activeAbortController === abortController) this.activeAbortController = undefined;
      this.running = false;
    }
  }

  private async classifyBatch(
    candidates: readonly ClassificationCandidate[],
    entries: Record<string, PickleClassificationEntry>,
    isCurrent: () => boolean,
    signal: AbortSignal,
  ): Promise<boolean> {
    let response: string;
    try {
      response = await this.options.completer.complete({
        system: "Classify completed coding work. Reply with only a JSON array. Each item must be {\"id\": string, \"category\": \"fix\"|\"research\"|\"create\"|\"review\"}.",
        prompt: JSON.stringify(candidates.map((candidate) => ({ id: candidate.session.id, input: candidate.input }))),
        maxTokens: 300,
        signal,
      });
    } catch (error) {
      this.logger("pickle classification model unavailable", { error: messageOf(error), count: candidates.length });
      return false;
    }
    if (!isCurrent()) return false;

    const categories = parseClassificationResponse(response);
    for (const candidate of candidates) {
      const previous = entries[candidate.session.id];
      const category = categories.get(candidate.session.id) ?? "unclassified";
      entries[candidate.session.id] = {
        category,
        fingerprint: candidate.fingerprint,
        classifiedAt: this.now().toISOString(),
        attempts: (previous?.fingerprint === candidate.fingerprint ? previous.attempts : 0) + 1,
      };
    }
    return true;
  }
}

export function buildPickleClassificationInput(session: PickyAgentSession): string {
  const userMessages = (session.messageJournalAvailable === false ? [] : session.messages ?? [])
    .filter((message) => message.kind === "user_text" && typeof message.text === "string")
    .slice(0, 5)
    .map((message) => truncate(normalize(message.text!), 300));
  const toolCounts = new Map<string, number>();
  for (const tool of session.tools ?? []) toolCounts.set(tool.name, (toolCounts.get(tool.name) ?? 0) + 1);
  const topTools = [...toolCounts.entries()]
    .sort((lhs, rhs) => rhs[1] - lhs[1] || lhs[0].localeCompare(rhs[0]))
    .slice(0, 8)
    .map(([name, count]) => `${name}:${count}`)
    .join(",");
  const activity = session.activitySummary ?? { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 };
  const text = [
    `title=${truncate(normalize(session.title), 120)}`,
    `tools=${topTools || "none"}`,
    `activity=read:${activity.read},bash:${activity.bash},edit:${activity.edit},write:${activity.write},todo:${activity.todo ?? 0},subagent:${activity.subagent ?? 0},thinking:${activity.thinking},other:${activity.other}`,
    `changedFiles=${session.changedFiles?.length ?? 0}`,
    `subagents=${session.subagentRuns?.length ?? 0}`,
    `messages=${userMessages.join(" | ") || "none"}`,
  ].join("\n");
  return truncate(text, 600);
}

export function parseClassificationResponse(response: string): Map<string, PickleStatisticsCategory> {
  try {
    const parsed: unknown = JSON.parse(response);
    if (!Array.isArray(parsed)) return new Map();
    const result = new Map<string, PickleStatisticsCategory>();
    for (const item of parsed) {
      if (!isRecord(item) || typeof item.id !== "string" || !VALID_CATEGORIES.has(item.category as PickleStatisticsCategory)) continue;
      result.set(item.id, item.category as PickleStatisticsCategory);
    }
    return result;
  } catch {
    return new Map();
  }
}

function shouldClassify(
  session: PickyAgentSession,
  existing: PickleClassificationEntry | undefined,
  fingerprint: string,
  now: Date,
): boolean {
  if (session.status === "running") return false;
  const lastActivity = Date.parse(session.updatedAt);
  const stale = Number.isFinite(lastActivity) && now.getTime() - lastActivity >= STALE_SESSION_MS;
  if (!isTerminalStatus(session.status) && !stale) return false;
  if (existing?.fingerprint === fingerprint && existing.category !== "unclassified") return false;
  return !(existing?.fingerprint === fingerprint && existing.attempts > MAX_ATTEMPTS);
}

function normalize(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function truncate(value: string, maximum: number): string {
  return value.length > maximum ? `${value.slice(0, Math.max(0, maximum - 1))}…` : value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
