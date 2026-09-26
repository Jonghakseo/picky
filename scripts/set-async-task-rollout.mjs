#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { lstat, rename, rm, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";

const [supportDir, mode] = process.argv.slice(2);
if (!supportDir || !["on", "drain"].includes(mode) || process.argv.length !== 4) {
  throw new Error("Usage: set-async-task-rollout.mjs <existing-Picky-AppSupport-dir> <on|drain>");
}
const root = resolve(supportDir);
if (!(await lstat(root)).isDirectory()) throw new Error("App Support root must be a directory");
const target = join(root, "async-task-rollout");
const temp = `${target}.${process.pid}.${randomUUID()}.tmp`;
try {
  await writeFile(temp, `${mode}\n`, { flag: "wx", mode: 0o600 });
  await rename(temp, target);
} finally {
  await rm(temp, { force: true });
}
console.log(`${target}: ${mode}`);
