import { appendFile, mkdir, readFile, readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { defaultAppSupportRoot, safeRelativeName } from "./artifact-store.js";

export class LogStore {
  readonly root: string;

  constructor(appSupportRoot = defaultAppSupportRoot()) {
    this.root = resolve(appSupportRoot, "logs");
  }

  async append(sessionId: string, line: string): Promise<string> {
    const path = this.pathFor(sessionId);
    await mkdir(dirname(path), { recursive: true });
    await appendFile(path, `${new Date().toISOString()} ${line}\n`);
    return path;
  }

  async read(sessionId: string): Promise<string> {
    try {
      return await readFile(this.pathFor(sessionId), "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return "";
      throw error;
    }
  }

  async list(): Promise<string[]> {
    try {
      return (await readdir(this.root)).filter((name) => name.endsWith(".log"));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }
  }

  pathFor(sessionId: string): string {
    return resolve(this.root, safeRelativeName(`${sessionId}.log`));
  }
}
