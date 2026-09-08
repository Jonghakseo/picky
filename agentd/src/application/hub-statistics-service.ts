import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import type { Dirent } from "node:fs";
import { mkdir, readFile, readdir, rename, stat, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { PickyAgentSessionSchema, PickyMainAgentStateSchema, type PickyAgentSession } from "../protocol.js";
import {
  aggregateUsageSamples,
  mergeUsageSamples,
  pickleStatisticsRecord,
  type PickleClassifications,
  type PickleStatisticsRecord,
  type PickleUsageSample,
  type PiUsageEntry,
} from "../domain/pickle-statistics.js";
import { logAgentd } from "../local-log.js";

export interface HubStatisticsSnapshot {
  generatedAt: string;
  records: PickleStatisticsRecord[];
  usageSamples: PickleUsageSample[];
  pendingClassificationCount: number;
  /** Explicit user consent for sending bounded Pickle metadata to a model. */
  classificationEnabled: boolean;
}

export interface HubStatisticsServiceLike {
  snapshot(): Promise<HubStatisticsSnapshot>;
  reset(): Promise<HubStatisticsSnapshot>;
  configureClassification(enabled: boolean): Promise<HubStatisticsSnapshot>;
}

interface CachedPiSessionUsage {
  mtimeMs: number;
  size: number;
  entries: PiUsageEntry[];
}

interface PersistedPiUsageDerivedRecord {
  version: 1;
  sourcePath: string;
  mtimeMs: number;
  size: number;
  entries: PiUsageEntry[];
}

export interface HubStatisticsServiceOptions {
  /** Test-only parser boundary. Production uses the streamed JSONL parser below. */
  parsePiUsageJsonl?: (filePath: string) => Promise<PiUsageEntry[]>;
}

interface UsageSource {
  filePath: string;
  project: string;
  /** Stable tie breaker when more than one Picky record owns one transcript. */
  owner: string;
}

export interface ClassificationState {
  generation: number;
  classifications: PickleClassifications;
  enabled: boolean;
}

interface ClassificationSettings {
  version: 1;
  classificationEnabled: boolean;
}

const EMPTY_CLASSIFICATIONS: PickleClassifications = { version: 1, entries: {} };
const DEFAULT_CLASSIFICATION_SETTINGS: ClassificationSettings = { version: 1, classificationEnabled: false };
const MAX_PI_USAGE_CACHE_ENTRIES = 64;
const PI_USAGE_DERIVED_CACHE_VERSION = "v1";
const PI_USAGE_DERIVED_RECORD_KEYS = new Set(["version", "sourcePath", "mtimeMs", "size", "entries"]);

export class HubStatisticsService implements HubStatisticsServiceLike {
  private readonly sessionsDir: string;
  private readonly classificationsPath: string;
  private readonly classificationSettingsPath: string;
  private readonly piUsageDerivedCacheDirectory: string;
  private readonly parsePiUsage: (filePath: string) => Promise<PiUsageEntry[]>;
  /** Insertion order is LRU order, with the oldest entry first. */
  private readonly piUsageCache = new Map<string, CachedPiSessionUsage>();
  private readonly piUsageReads = new Map<string, Promise<PiUsageEntry[]>>();
  /** Source paths retained only while an overlapping snapshot still examines them. */
  private readonly piUsageVisibleSources = new Map<string, number>();
  private classificationGeneration = 0;
  private classificationPersistence: Promise<void> = Promise.resolve();

  constructor(private readonly appSupportDir: string, options: HubStatisticsServiceOptions = {}) {
    this.sessionsDir = join(appSupportDir, "sessions");
    this.classificationsPath = join(appSupportDir, "Statistics", "classifications.json");
    this.classificationSettingsPath = join(appSupportDir, "Statistics", "classification-settings.json");
    this.piUsageDerivedCacheDirectory = join(appSupportDir, "Statistics", "pi-usage-cache", PI_USAGE_DERIVED_CACHE_VERSION);
    this.parsePiUsage = options.parsePiUsageJsonl ?? parsePiUsageJsonl;
  }

  async snapshot(): Promise<HubStatisticsSnapshot> {
    const [sessions, classifications, settings] = await Promise.all([
      this.loadSessions(),
      this.readClassifications(),
      this.readClassificationSettings(),
    ]);
    return await this.snapshotFor(sessions, classifications, settings.classificationEnabled);
  }

  /**
   * Reset invalidates every in-flight classifier result before serializing the unlink.
   * The returned snapshot is built from the empty state, so a new run cannot make the
   * reset acknowledgement look successful before its clear is observable.
   */
  async reset(): Promise<HubStatisticsSnapshot> {
    this.classificationGeneration += 1;
    await this.enqueueClassificationPersistence(async () => {
      try {
        await unlink(this.classificationsPath);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    });
    const [sessions, settings] = await Promise.all([this.loadSessions(), this.readClassificationSettings()]);
    return await this.snapshotFor(sessions, EMPTY_CLASSIFICATIONS, settings.classificationEnabled);
  }

  /**
   * Persists explicit consent separately from classifications. Missing or invalid
   * state is deliberately fail-closed, so legacy installs never transmit metadata.
   */
  async configureClassification(enabled: boolean): Promise<HubStatisticsSnapshot> {
    // Complete all potentially failing read work before mutating consent. The
    // server starts a classifier only after this method has resolved.
    const [sessions, classifications] = await Promise.all([this.loadSessions(), this.readClassifications()]);
    const snapshot = await this.snapshotFor(sessions, classifications, enabled);
    this.classificationGeneration += 1;
    await this.enqueueClassificationPersistence(async () => {
      await this.writeClassificationSettings({ version: 1, classificationEnabled: enabled });
    });
    return snapshot;
  }

  async classificationState(): Promise<ClassificationState> {
    const generation = this.classificationGeneration;
    const [classifications, settings] = await Promise.all([this.readClassifications(), this.readClassificationSettings()]);
    return { generation, classifications, enabled: settings.classificationEnabled };
  }

  /**
   * A classifier may only replace the file if it still belongs to the current
   * generation and is still alive when its turn reaches the persistence queue.
   */
  async commitClassifications(
    generation: number,
    classifications: PickleClassifications,
    isCurrent: () => boolean,
  ): Promise<boolean> {
    let committed = false;
    await this.enqueueClassificationPersistence(async () => {
      if (generation !== this.classificationGeneration || !isCurrent()) return;
      await this.writeClassifications(classifications);
      committed = true;
    });
    return committed;
  }

  async loadSessions(): Promise<PickyAgentSession[]> {
    let entries: Dirent<string>[];
    try {
      entries = await readdir(this.sessionsDir, { withFileTypes: true, encoding: "utf8" });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }

    const files = entries.flatMap((entry) => {
      if (entry.isFile() && entry.name.endsWith(".json")) return [join(this.sessionsDir, entry.name)];
      if (entry.isDirectory()) return [join(this.sessionsDir, entry.name, `${entry.name}.json`)];
      return [];
    });
    const loaded = await Promise.all(files.map((filePath) => this.readSession(filePath)));
    const byId = new Map<string, PickyAgentSession>();
    for (const session of loaded) {
      if (!session) continue;
      const previous = byId.get(session.id);
      if (!previous || (session.revision ?? 0) > (previous.revision ?? 0)) byId.set(session.id, session);
    }
    return [...byId.values()];
  }

  async readClassifications(): Promise<PickleClassifications> {
    try {
      const raw: unknown = JSON.parse(await readFile(this.classificationsPath, "utf8"));
      if (!isClassifications(raw)) throw new Error("invalid classifications schema");
      return raw;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        logAgentd("hub statistics classifications skipped", { path: this.classificationsPath, error: messageOf(error) });
      }
      return { version: 1, entries: {} };
    }
  }

  private async snapshotFor(
    sessions: readonly PickyAgentSession[],
    classifications: PickleClassifications,
    classificationEnabled: boolean,
  ): Promise<HubStatisticsSnapshot> {
    const records = sessions
      .map((session) => pickleStatisticsRecord(session, classifications.entries[session.id], { homeDir: homedir() }))
      .sort((lhs, rhs) => rhs.lastActivityAt.localeCompare(lhs.lastActivityAt));
    const usageSamples = mergeUsageSamples(await this.loadUsageSamples(sessions));
    return {
      generatedAt: new Date().toISOString(),
      records,
      usageSamples,
      pendingClassificationCount: records.filter((record) => record.category === "unclassified").length,
      classificationEnabled,
    };
  }

  private async readClassificationSettings(): Promise<ClassificationSettings> {
    try {
      const raw: unknown = JSON.parse(await readFile(this.classificationSettingsPath, "utf8"));
      if (!isClassificationSettings(raw)) throw new Error("invalid classification settings schema");
      return raw;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        logAgentd("hub statistics classification consent skipped", { path: this.classificationSettingsPath, error: messageOf(error) });
      }
      return DEFAULT_CLASSIFICATION_SETTINGS;
    }
  }

  private async writeClassificationSettings(settings: ClassificationSettings): Promise<void> {
    const directory = join(this.appSupportDir, "Statistics");
    await mkdir(directory, { recursive: true });
    const tempPath = join(directory, `.classification-settings.${process.pid}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(settings, null, 2), "utf8");
    await rename(tempPath, this.classificationSettingsPath);
  }

  private async writeClassifications(classifications: PickleClassifications): Promise<void> {
    const directory = join(this.appSupportDir, "Statistics");
    await mkdir(directory, { recursive: true });
    const tempPath = join(directory, `.classifications.${process.pid}.${randomUUID()}.tmp`);
    await writeFile(tempPath, JSON.stringify(classifications, null, 2), "utf8");
    await rename(tempPath, this.classificationsPath);
  }

  private async enqueueClassificationPersistence(operation: () => Promise<void>): Promise<void> {
    const next = this.classificationPersistence.then(operation, operation);
    this.classificationPersistence = next.catch(() => undefined);
    await next;
  }

  private async readSession(filePath: string): Promise<PickyAgentSession | undefined> {
    try {
      return PickyAgentSessionSchema.parse(JSON.parse(await readFile(filePath, "utf8")));
    } catch (error) {
      logAgentd("hub statistics session skipped", { path: filePath, error: messageOf(error) });
      return undefined;
    }
  }

  private async loadUsageSamples(sessions: readonly PickyAgentSession[]): Promise<PickleUsageSample[]> {
    const sources: UsageSource[] = sessions.flatMap((session) => session.piSessionFilePath ? [{
      filePath: normalizePiUsageSourcePath(session.piSessionFilePath),
      project: pickleStatisticsRecord(session, undefined, { homeDir: homedir() }).project,
      owner: `pickle:${session.id}`,
    }] : []);
    const mainSessionPath = await this.readMainAgentSessionPath();
    if (mainSessionPath) sources.push({ filePath: normalizePiUsageSourcePath(mainSessionPath), project: "Picky", owner: "main" });

    // First choose one deterministic owner per physical transcript. Then deduplicate
    // Pi's stable message IDs across copied fork transcripts.
    const ownedSources = [...new Map(sources
      .sort(compareUsageSources)
      .map((source) => [source.filePath, source] as const)).values()];
    this.retainPiUsageSources(ownedSources);
    try {
      const seenMessageIds = new Set<string>();
      const samples: PickleUsageSample[] = [];
      for (const source of ownedSources) {
        const uniqueEntries = (await this.readPiUsage(source.filePath)).filter((entry) => {
          if (seenMessageIds.has(entry.messageId)) return false;
          seenMessageIds.add(entry.messageId);
          return true;
        });
        samples.push(...aggregateUsageSamples(uniqueEntries, source.project));
      }
      await this.pruneMissingPiUsageDerivedRecords();
      return samples;
    } finally {
      this.releasePiUsageSources(ownedSources);
    }
  }

  private async readMainAgentSessionPath(): Promise<string | undefined> {
    const statePath = join(this.appSupportDir, "picky.json");
    try {
      const state = PickyMainAgentStateSchema.parse(JSON.parse(await readFile(statePath, "utf8")));
      return state.sessionFilePath;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        logAgentd("hub statistics main state skipped", { path: statePath, error: messageOf(error) });
      }
      return undefined;
    }
  }

  private async readPiUsage(filePath: string): Promise<PiUsageEntry[]> {
    const normalizedPath = normalizePiUsageSourcePath(filePath);
    const inFlight = this.piUsageReads.get(normalizedPath);
    if (inFlight) return await inFlight;

    const read = this.readPiUsageFresh(normalizedPath);
    this.piUsageReads.set(normalizedPath, read);
    try {
      return await read;
    } finally {
      if (this.piUsageReads.get(normalizedPath) === read) this.piUsageReads.delete(normalizedPath);
    }
  }

  private async readPiUsageFresh(filePath: string): Promise<PiUsageEntry[]> {
    try {
      const fileStat = await stat(filePath);
      const cached = this.piUsageCache.get(filePath);
      if (isPiUsageCacheMatch(cached, fileStat.mtimeMs, fileStat.size)) {
        this.cachePiUsage(filePath, cached);
        return cached.entries;
      }

      const derivedCached = await this.readPiUsageDerived(filePath);
      if (isPiUsageCacheMatch(derivedCached, fileStat.mtimeMs, fileStat.size)) {
        this.cachePiUsage(filePath, derivedCached);
        return derivedCached.entries;
      }

      const entries = await this.parsePiUsage(filePath);
      const value = { mtimeMs: fileStat.mtimeMs, size: fileStat.size, entries };
      this.cachePiUsage(filePath, value);
      await this.writePiUsageDerived(filePath, value);
      return entries;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        await this.removeMissingPiUsageDerived(filePath);
      } else {
        logAgentd("hub statistics Pi session skipped", { path: filePath, error: messageOf(error) });
      }
      return [];
    }
  }

  private cachePiUsage(filePath: string, value: CachedPiSessionUsage): void {
    this.piUsageCache.delete(filePath);
    this.piUsageCache.set(filePath, value);
    while (this.piUsageCache.size > MAX_PI_USAGE_CACHE_ENTRIES) {
      const oldest = this.piUsageCache.keys().next().value;
      if (!oldest) return;
      this.piUsageCache.delete(oldest);
    }
  }

  private async readPiUsageDerived(filePath: string): Promise<CachedPiSessionUsage | undefined> {
    const derivedPath = this.piUsageDerivedPath(filePath);
    try {
      const raw: unknown = JSON.parse(await readFile(derivedPath, "utf8"));
      if (!isPersistedPiUsageDerivedRecord(raw) || raw.sourcePath !== filePath) {
        throw new Error("invalid Pi usage derived record");
      }
      return raw;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        logAgentd("hub statistics Pi usage derived record skipped", { path: derivedPath, error: messageOf(error) });
      }
      return undefined;
    }
  }

  private async writePiUsageDerived(filePath: string, value: CachedPiSessionUsage): Promise<void> {
    const derivedPath = this.piUsageDerivedPath(filePath);
    const tempPath = join(this.piUsageDerivedCacheDirectory, `.${piUsageDerivedFileName(filePath)}.${process.pid}.${randomUUID()}.tmp`);
    try {
      await mkdir(this.piUsageDerivedCacheDirectory, { recursive: true });
      const record: PersistedPiUsageDerivedRecord = {
        version: 1,
        sourcePath: filePath,
        ...value,
      };
      await writeFile(tempPath, JSON.stringify(record), "utf8");
      await rename(tempPath, derivedPath);
    } catch (error) {
      logAgentd("hub statistics Pi usage derived record write skipped", { path: derivedPath, error: messageOf(error) });
      try {
        await unlink(tempPath);
      } catch (cleanupError) {
        const code = (cleanupError as NodeJS.ErrnoException).code;
        if (code !== "ENOENT" && code !== "ENOTDIR") {
          logAgentd("hub statistics Pi usage temporary record cleanup skipped", { path: tempPath, error: messageOf(cleanupError) });
        }
      }
    }
  }

  private async removeMissingPiUsageDerived(filePath: string): Promise<void> {
    // An overlapping snapshot may still have this source open or may be about to
    // replace its record, so only the sole visible reader may remove it.
    if ((this.piUsageVisibleSources.get(filePath) ?? 0) > 1) return;
    try {
      await unlink(this.piUsageDerivedPath(filePath));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        logAgentd("hub statistics Pi usage derived record removal skipped", { path: filePath, error: messageOf(error) });
      }
    }
  }

  private async pruneMissingPiUsageDerivedRecords(): Promise<void> {
    let entries: Dirent<string>[];
    try {
      entries = await readdir(this.piUsageDerivedCacheDirectory, { withFileTypes: true, encoding: "utf8" });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        logAgentd("hub statistics Pi usage derived cache prune skipped", { path: this.piUsageDerivedCacheDirectory, error: messageOf(error) });
      }
      return;
    }

    const visibleFiles = new Set([...this.piUsageVisibleSources.keys()].map(piUsageDerivedFileName));
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".json") || visibleFiles.has(entry.name)) continue;
      const derivedPath = join(this.piUsageDerivedCacheDirectory, entry.name);
      const record = await this.readPiUsageDerivedRecordForPruning(derivedPath);
      if (!record || this.piUsageVisibleSources.has(record.sourcePath)) continue;
      try {
        await stat(record.sourcePath);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT" && !this.piUsageVisibleSources.has(record.sourcePath)) {
          await this.removeMissingPiUsageDerived(record.sourcePath);
        }
      }
    }
  }

  private async readPiUsageDerivedRecordForPruning(derivedPath: string): Promise<PersistedPiUsageDerivedRecord | undefined> {
    try {
      const raw: unknown = JSON.parse(await readFile(derivedPath, "utf8"));
      if (!isPersistedPiUsageDerivedRecord(raw) || this.piUsageDerivedPath(raw.sourcePath) !== derivedPath) {
        throw new Error("invalid Pi usage derived record");
      }
      return raw;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        logAgentd("hub statistics Pi usage derived record prune skipped", { path: derivedPath, error: messageOf(error) });
      }
      return undefined;
    }
  }

  private piUsageDerivedPath(filePath: string): string {
    return join(this.piUsageDerivedCacheDirectory, piUsageDerivedFileName(filePath));
  }

  private retainPiUsageSources(sources: readonly UsageSource[]): void {
    for (const source of sources) {
      this.piUsageVisibleSources.set(source.filePath, (this.piUsageVisibleSources.get(source.filePath) ?? 0) + 1);
    }
  }

  private releasePiUsageSources(sources: readonly UsageSource[]): void {
    for (const source of sources) {
      const count = this.piUsageVisibleSources.get(source.filePath) ?? 0;
      if (count <= 1) this.piUsageVisibleSources.delete(source.filePath);
      else this.piUsageVisibleSources.set(source.filePath, count - 1);
    }
  }
}

export async function parsePiUsageJsonl(filePath: string): Promise<PiUsageEntry[]> {
  const entries: PiUsageEntry[] = [];
  const reader = createInterface({ input: createReadStream(filePath, { encoding: "utf8" }), crlfDelay: Infinity });
  for await (const line of reader) {
    try {
      const parsed: unknown = JSON.parse(line);
      const entry = piUsageEntry(parsed);
      if (entry) entries.push(entry);
    } catch {
      // A partial or malformed transcript line must not make Hub unavailable.
    }
  }
  return entries;
}

function piUsageEntry(value: unknown): PiUsageEntry | undefined {
  if (!isRecord(value) || value.type !== "message" || typeof value.id !== "string" || !isRecord(value.message) || value.message.role !== "assistant") return undefined;
  const message = value.message;
  const usage = isRecord(message.usage) ? message.usage : undefined;
  const provider = stringValue(message.provider);
  const model = stringValue(message.model);
  if (!usage || !provider || !model) return undefined;
  return {
    messageId: value.id,
    timestamp: timestampValue(message.timestamp) ?? timestampValue(value.timestamp),
    provider,
    model,
    inputTokens: numberValue(usage.input),
    outputTokens: numberValue(usage.output),
    cacheReadTokens: numberValue(usage.cacheRead),
    cacheWriteTokens: numberValue(usage.cacheWrite),
  };
}

function compareUsageSources(lhs: UsageSource, rhs: UsageSource): number {
  return lhs.filePath.localeCompare(rhs.filePath) || lhs.owner.localeCompare(rhs.owner);
}

function isPiUsageCacheMatch(
  value: CachedPiSessionUsage | undefined,
  mtimeMs: number,
  size: number,
): value is CachedPiSessionUsage {
  return Boolean(value && value.mtimeMs === mtimeMs && value.size === size);
}

function normalizePiUsageSourcePath(filePath: string): string {
  return resolve(filePath);
}

function piUsageDerivedFileName(filePath: string): string {
  return `${createHash("sha256").update(filePath).digest("hex")}.json`;
}

function isPersistedPiUsageDerivedRecord(value: unknown): value is PersistedPiUsageDerivedRecord {
  return isRecord(value)
    && hasOnlyKeys(value, PI_USAGE_DERIVED_RECORD_KEYS)
    && value.version === 1
    && typeof value.sourcePath === "string"
    && value.sourcePath === normalizePiUsageSourcePath(value.sourcePath)
    && typeof value.mtimeMs === "number"
    && Number.isFinite(value.mtimeMs)
    && typeof value.size === "number"
    && Number.isFinite(value.size)
    && Array.isArray(value.entries)
    && value.entries.every(isPiUsageEntry);
}

function isPiUsageEntry(value: unknown): value is PiUsageEntry {
  return isRecord(value)
    && typeof value.messageId === "string"
    && (typeof value.timestamp === "number" || typeof value.timestamp === "string" || value.timestamp === undefined)
    && typeof value.provider === "string"
    && typeof value.model === "string"
    && typeof value.inputTokens === "number"
    && Number.isFinite(value.inputTokens)
    && typeof value.outputTokens === "number"
    && Number.isFinite(value.outputTokens)
    && typeof value.cacheReadTokens === "number"
    && Number.isFinite(value.cacheReadTokens)
    && typeof value.cacheWriteTokens === "number"
    && Number.isFinite(value.cacheWriteTokens);
}

function isClassifications(value: unknown): value is PickleClassifications {
  if (!isRecord(value) || value.version !== 1 || !isRecord(value.entries)) return false;
  return Object.values(value.entries).every((entry) => (
    isRecord(entry)
    && isCategory(entry.category)
    && typeof entry.fingerprint === "string"
    && typeof entry.classifiedAt === "string"
    && typeof entry.attempts === "number"
  ));
}

function isClassificationSettings(value: unknown): value is ClassificationSettings {
  return isRecord(value) && value.version === 1 && typeof value.classificationEnabled === "boolean";
}

function isCategory(value: unknown): value is PickleClassifications["entries"][string]["category"] {
  return value === "fix" || value === "research" || value === "create" || value === "review" || value === "unclassified";
}

function hasOnlyKeys(value: Record<string, unknown>, allowedKeys: ReadonlySet<string>): boolean {
  return Object.keys(value).every((key) => allowedKeys.has(key));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function timestampValue(value: unknown): number | string | undefined {
  return typeof value === "number" || typeof value === "string" ? value : undefined;
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
