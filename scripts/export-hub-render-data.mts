#!/usr/bin/env node
/**
 * Exports a real local Hub statistics snapshot without starting picky-agentd or
 * allowing HubStatisticsService's derived usage cache to touch live state.
 *
 * The output is the exact PickyHubStatisticsSnapshot wire shape consumed by
 * PickyHubRenderGalleryTests. Provenance is deliberately written separately so
 * the snapshot keeps its production decoder contract.
 */

import { createHash, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import type { Dirent } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, join, relative, resolve } from "node:path";
import { HubStatisticsService, type HubStatisticsSnapshot } from "../agentd/src/application/hub-statistics-service.js";
import { PickyAgentSessionSchema, PickyMainAgentStateSchema } from "../agentd/src/protocol.js";

const DEFAULT_OUTPUT = "/private/tmp/picky-dashboard-audit/live-statistics.json";
const DEFAULT_SOURCE = join(homedir(), "Library", "Application Support", "Picky");

interface Options {
  source: string;
  output: string;
  piSettings?: string;
}

interface ProjectionCounts {
  sessionMetadataCandidates: number;
  sessionMetadataCopied: number;
  sessionMetadataUnreadable: number;
  transcriptReferences: number;
  transcriptsCopied: number;
  transcriptsUnavailable: number;
  mainAgentTranscriptReferences: number;
  statisticsFilesCopied: number;
}

interface Provenance {
  schemaVersion: 1;
  exportStartedAt: string;
  exportCompletedAt: string;
  snapshotGeneratedAt: string;
  projection: "HubStatisticsService.snapshot() on an isolated temporary copy";
  sourceReadOnly: true;
  temporaryProjectionRemoved: true;
  counts: ProjectionCounts & {
    records: number;
    usageSamples: number;
    pendingClassificationCount: number;
  };
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  const source = await realpath(resolve(options.source));
  const output = await canonicalDestination(resolve(options.output));
  const provenancePath = join(
    dirname(output),
    `${basename(output, extname(output))}.provenance.json`,
  );
  assertOutsideSource(output, source, "output");
  assertOutsideSource(provenancePath, source, "provenance output");

  const sourceStats = await stat(source);
  if (!sourceStats.isDirectory()) throw new Error(`Picky app support path is not a directory: ${source}`);

  const startedAt = new Date().toISOString();
  // Do not trust TMPDIR: callers may point it at the source being audited.
  const temporaryParent = await realpath("/private/tmp");
  assertOutsideSource(temporaryParent, source, "temporary projection");
  const temporaryRoot = await mkdtemp(join(temporaryParent, "picky-hub-render-data-"));
  const counts: ProjectionCounts = {
    sessionMetadataCandidates: 0,
    sessionMetadataCopied: 0,
    sessionMetadataUnreadable: 0,
    transcriptReferences: 0,
    transcriptsCopied: 0,
    transcriptsUnavailable: 0,
    mainAgentTranscriptReferences: 0,
    statisticsFilesCopied: 0,
  };

  let temporaryProjectionRemoved = false;
  try {
    const projection = new LiveStatisticsProjection(source, temporaryRoot, counts);
    await projection.copyInputs();
    const snapshot = await new HubStatisticsService(temporaryRoot).snapshot();
    // The service may write a derived usage cache, but only under this root.
    // Remove it before publishing either artifact so the provenance claim is
    // true even if a later output write fails.
    await rm(temporaryRoot, { recursive: true, force: true });
    temporaryProjectionRemoved = true;
    const completedAt = new Date().toISOString();
    const provenance: Provenance = {
      schemaVersion: 1,
      exportStartedAt: startedAt,
      exportCompletedAt: completedAt,
      snapshotGeneratedAt: snapshot.generatedAt,
      projection: "HubStatisticsService.snapshot() on an isolated temporary copy",
      sourceReadOnly: true,
      temporaryProjectionRemoved: true,
      counts: {
        ...counts,
        records: snapshot.records.length,
        usageSamples: snapshot.usageSamples.length,
        pendingClassificationCount: snapshot.pendingClassificationCount,
      },
    };

    // The snapshot itself remains a bare production wire object for Swift's
    // PickyHubStatisticsSnapshot decoder. Keep audit metadata in the sidecar.
    await writeJSONAtomically(output, snapshot);
    await writeJSONAtomically(provenancePath, provenance);
    if (options.piSettings) {
      const settings = JSON.parse(await readFile(options.piSettings, "utf8")) as { packages?: unknown };
      const packagesPath = join(dirname(output), `${basename(output, extname(output))}.packages.json`);
      assertOutsideSource(await canonicalDestination(packagesPath), source, "package declarations");
      await writeJSONAtomically(packagesPath, { packages: Array.isArray(settings.packages) ? settings.packages : [] });
      console.log(`Package declarations only: ${packagesPath}`);
    }
    console.log(`Hub statistics snapshot: ${output}`);
    console.log(`Non-sensitive provenance: ${provenancePath}`);
  } finally {
    if (!temporaryProjectionRemoved) {
      await rm(temporaryRoot, { recursive: true, force: true });
    }
  }
}

class LiveStatisticsProjection {
  private readonly transcriptPaths = new Map<string, Promise<string>>();

  constructor(
    private readonly sourceRoot: string,
    private readonly temporaryRoot: string,
    private readonly counts: ProjectionCounts,
  ) {}

  async copyInputs(): Promise<void> {
    await Promise.all([
      this.copySessions(),
      this.copyOptionalStatisticsFile("classifications.json"),
      this.copyOptionalStatisticsFile("classification-settings.json"),
      this.copyMainAgentState(),
    ]);
  }

  private async copySessions(): Promise<void> {
    const sourceSessions = join(this.sourceRoot, "sessions");
    let entries: Dirent<string>[];
    try {
      entries = await readdir(sourceSessions, { withFileTypes: true, encoding: "utf8" });
    } catch (error) {
      if (nodeErrorCode(error) === "ENOENT") return;
      throw error;
    }

    await Promise.all(entries.flatMap((entry) => {
      if (entry.isFile() && entry.name.endsWith(".json")) {
        return [this.copySessionFile(join(sourceSessions, entry.name), join(this.temporaryRoot, "sessions", entry.name))];
      }
      if (entry.isDirectory()) {
        return [this.copySessionFile(
          join(sourceSessions, entry.name, `${entry.name}.json`),
          join(this.temporaryRoot, "sessions", entry.name, `${entry.name}.json`),
        )];
      }
      return [];
    }));
  }

  private async copySessionFile(sourcePath: string, destinationPath: string): Promise<void> {
    this.counts.sessionMetadataCandidates += 1;
    let raw: string;
    try {
      raw = await readFile(sourcePath, "utf8");
    } catch (error) {
      if (nodeErrorCode(error) === "ENOENT") return;
      this.counts.sessionMetadataUnreadable += 1;
      return;
    }

    let projected = raw;
    try {
      const session = PickyAgentSessionSchema.parse(JSON.parse(raw));
      const transcript = session.piSessionFilePath
        ? await this.copyTranscript(session.piSessionFilePath, false)
        : undefined;
      projected = JSON.stringify({
        ...session,
        ...(transcript ? { piSessionFilePath: transcript } : {}),
      });
    } catch {
      // HubStatisticsService itself skips malformed session metadata. Preserve it
      // in the isolated root so the production service makes that decision.
    }

    await writeFileWithParents(destinationPath, projected);
    this.counts.sessionMetadataCopied += 1;
  }

  private async copyMainAgentState(): Promise<void> {
    const sourcePath = join(this.sourceRoot, "picky.json");
    let raw: string;
    try {
      raw = await readFile(sourcePath, "utf8");
    } catch (error) {
      if (nodeErrorCode(error) === "ENOENT") return;
      throw error;
    }

    try {
      const state = PickyMainAgentStateSchema.parse(JSON.parse(raw));
      const transcript = state.sessionFilePath
        ? await this.copyTranscript(state.sessionFilePath, true)
        : undefined;
      // HubStatisticsService reads only sessionFilePath. Do not retain the main
      // agent conversation in the temporary projection.
      await writeFileWithParents(join(this.temporaryRoot, "picky.json"), JSON.stringify(
        transcript ? { sessionFilePath: transcript, messages: [] } : { messages: [] },
      ));
    } catch {
      // Match production behavior for malformed main state by supplying the
      // original bytes, which the service will parse-and-skip itself.
      await writeFileWithParents(join(this.temporaryRoot, "picky.json"), raw);
    }
  }

  private async copyOptionalStatisticsFile(fileName: string): Promise<void> {
    const sourcePath = join(this.sourceRoot, "Statistics", fileName);
    try {
      const raw = await readFile(sourcePath);
      await writeFileWithParents(join(this.temporaryRoot, "Statistics", fileName), raw);
      this.counts.statisticsFilesCopied += 1;
    } catch (error) {
      if (nodeErrorCode(error) !== "ENOENT") throw error;
    }
  }

  private async copyTranscript(sourcePath: string, isMainAgent: boolean): Promise<string> {
    if (isMainAgent) this.counts.mainAgentTranscriptReferences += 1;
    else this.counts.transcriptReferences += 1;
    const normalizedSource = resolve(sourcePath);
    const existing = this.transcriptPaths.get(normalizedSource);
    if (existing) return await existing;

    const destinationPath = join(
      this.temporaryRoot,
      "pi-transcripts",
      `${createHash("sha256").update(normalizedSource).digest("hex")}.jsonl`,
    );
    const copy = (async () => {
      try {
        const raw = await readFile(normalizedSource);
        await writeFileWithParents(destinationPath, raw);
        this.counts.transcriptsCopied += 1;
      } catch {
        // The service treats absent or unreadable transcript files as no usage.
        // Leave the isolated reference absent rather than ever falling back to
        // the source path.
        this.counts.transcriptsUnavailable += 1;
      }
      return destinationPath;
    })();
    this.transcriptPaths.set(normalizedSource, copy);
    return await copy;
  }
}

function parseOptions(arguments_: readonly string[]): Options {
  let source = process.env.PICKY_APP_SUPPORT_DIR || DEFAULT_SOURCE;
  let output = DEFAULT_OUTPUT;
  let piSettings: string | undefined;
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--source") {
      source = requiredValue(arguments_, ++index, "--source");
    } else if (argument === "--output") {
      output = requiredValue(arguments_, ++index, "--output");
    } else if (argument === "--pi-settings") {
      piSettings = requiredValue(arguments_, ++index, "--pi-settings");
    } else if (argument === "--help" || argument === "-h") {
      console.log("Usage: pnpm --dir agentd exec tsx ../scripts/export-hub-render-data.mts [--source <Picky app support dir>] [--output <snapshot.json>] [--pi-settings <Pi settings.json>]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return { source, output, piSettings };
}

function requiredValue(arguments_: readonly string[], index: number, option: string): string {
  const value = arguments_[index];
  if (!value || value.startsWith("-")) throw new Error(`${option} requires a path`);
  return value;
}

// Resolve existing ancestors before writing so symlinked output directories
// cannot route an otherwise harmless-looking path into live App Support.
async function canonicalDestination(path: string): Promise<string> {
  try { return await realpath(path); }
  catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
    return join(await canonicalDestination(dirname(path)), basename(path));
  }
}

function assertOutsideSource(candidate: string, source: string, label: string): void {
  const relativePath = relative(source, candidate);
  if (!relativePath || (relativePath !== ".." && !relativePath.startsWith("../"))) {
    throw new Error(`Refusing to write ${label} inside the live Picky app support directory`);
  }
}

async function writeFileWithParents(path: string, data: string | Uint8Array): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, data);
}

async function writeJSONAtomically(path: string, value: HubStatisticsSnapshot | Provenance | { packages: unknown[] }): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporaryPath = join(dirname(path), `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  try {
    await writeFile(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    await rename(temporaryPath, path);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
}

function nodeErrorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String(error.code)
    : undefined;
}

void main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
