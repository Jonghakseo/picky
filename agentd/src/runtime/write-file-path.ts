import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { asRecord, stringValue } from "./pi-sdk-runtime-helpers.js";

export function writeFilePathFromRawArgs(args: unknown, cwd: string): string | undefined {
  const rawArgs = asRecord(args);
  const rawPath = stringValue(rawArgs.path)
    ?? stringValue(rawArgs.file_path)
    ?? stringValue(rawArgs.filePath)
    ?? stringValue(rawArgs.file);
  if (!rawPath || rawPath.includes("\0")) return undefined;
  const expanded = rawPath === "~" || rawPath.startsWith("~/")
    ? `${homedir()}${rawPath.slice(1)}`
    : rawPath;
  return resolve(isAbsolute(expanded) ? expanded : cwd, expanded);
}
