#!/usr/bin/env node
/* eslint-disable no-console */

const fs = require("node:fs");
const path = require("node:path");

const policyRoot = path.resolve(__dirname, "..");
const sourceRoot = path.resolve(process.argv[2] ?? policyRoot);
const allowlistPath = path.resolve(process.argv[3] ?? path.join(policyRoot, "scripts", "eslint-suppressions.json"));
const allowlist = JSON.parse(fs.readFileSync(allowlistPath, "utf8"));
const allowedCounts = countEntries(allowlist);
const actual = collectSuppressions(path.join(sourceRoot, "agentd", "src"));
const actualCounts = countEntries(actual);
const errors = [];

for (const [key, count] of actualCounts) {
  const allowed = allowedCounts.get(key) ?? 0;
  if (count > allowed) {
    const entry = JSON.parse(key);
    errors.push(`${entry.path}: suppression is not allowlisted (${entry.directive})`);
  }
}

if (errors.length > 0) {
  for (const error of errors) console.error(`error: ${error}`);
  console.error(`ESLint suppression guard failed with ${errors.length} unexpected directive(s).`);
  process.exit(1);
}

const removedCount = [...allowedCounts.entries()].reduce((total, [key, count]) => total + Math.max(0, count - (actualCounts.get(key) ?? 0)), 0);
console.log(`ESLint suppression guard passed (${actual.length} allowlisted, ${removedCount} removed).`);

function collectSuppressions(sourceDir) {
  const entries = [];
  for (const file of walk(sourceDir)) {
    const relativePath = path.relative(sourceRoot, file).replaceAll(path.sep, "/");
    const lines = fs.readFileSync(file, "utf8").split("\n");
    for (const line of lines) {
      const directive = line.trim();
      if (/eslint-(?:disable|enable)(?:-next-line|-line)?\b/.test(directive)) {
        entries.push({ path: relativePath, directive });
      }
    }
  }
  return entries;
}

function countEntries(entries) {
  const counts = new Map();
  for (const entry of entries) {
    const key = JSON.stringify({ path: entry.path, directive: entry.directive });
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

function walk(directory) {
  if (!fs.existsSync(directory)) return [];
  const files = [];
  const stack = [directory];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(fullPath);
      else if (entry.isFile() && entry.name.endsWith(".ts")) files.push(fullPath);
    }
  }
  return files.sort();
}
