import { mkdirSync } from "node:fs";

type MkdirSync = typeof mkdirSync;
type Chdir = typeof process.chdir;
type Cwd = typeof process.cwd;

export interface ProcessCwdStabilizerOptions {
  mkdir?: MkdirSync;
  chdir?: Chdir;
  cwd?: Cwd;
  onError?: (error: unknown) => void;
}

export interface ProcessCwdStabilizerResult {
  ok: boolean;
  cwd: string;
  error?: unknown;
}

export function cwdOrFallback(fallback: string, cwd: Cwd = process.cwd): string {
  try {
    return cwd();
  } catch {
    return fallback;
  }
}

export function stabilizeProcessCwd(targetDir: string, options: ProcessCwdStabilizerOptions = {}): ProcessCwdStabilizerResult {
  const mkdir = options.mkdir ?? mkdirSync;
  const chdir = options.chdir ?? process.chdir;
  const cwd = options.cwd ?? process.cwd;

  try {
    mkdir(targetDir, { recursive: true });
    chdir(targetDir);
    return { ok: true, cwd: cwdOrFallback(targetDir, cwd) };
  } catch (error) {
    options.onError?.(error);
    return { ok: false, cwd: cwdOrFallback(targetDir, cwd), error };
  }
}
