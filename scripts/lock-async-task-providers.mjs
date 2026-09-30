#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";

// Run only after the pack tarballs and extracted package contents have passed
// provider qualification. Review this output against A's tarball SHA256 manifest
// before checking it in; the packager never regenerates its own trusted lock.
const root = resolve(process.argv[2] ?? "");
if (!process.argv[2]) throw new Error("Usage: lock-async-task-providers.mjs <qualified-extracted-root>");
const packages = {};
for (const [id, expectedName, expectedVersion] of [
  ["bash-async", "@ryan_nookpi/pi-extension-bash-async", "0.2.4"],
  ["subagent", "@ryan_nookpi/pi-extension-subagent", "0.5.9"],
]) {
  const dir = join(root, "packages", id);
  const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  if (manifest.name !== expectedName || manifest.version !== expectedVersion || JSON.stringify(manifest.pi?.extensions) !== JSON.stringify(["./index.ts"])) throw new Error(`Unexpected ${id} package identity`);
  const files = {};
  const visit = (path) => {
    for (const name of readdirSync(path).sort()) {
      const target = join(path, name);
      const stat = lstatSync(target);
      if (stat.isDirectory()) visit(target);
      else if (stat.isFile()) files[relative(dir, target).split(sep).join("/")] = createHash("sha256").update(readFileSync(target)).digest("hex");
      else throw new Error(`Non-regular provider file: ${target}`);
    }
  };
  visit(dir);
  packages[id] = { name: expectedName, version: expectedVersion, files };
}
console.log(JSON.stringify({ packages }, null, 2));
