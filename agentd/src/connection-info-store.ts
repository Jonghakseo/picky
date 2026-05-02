import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { PROTOCOL_VERSION } from "./protocol.js";

export const CONNECTION_INFO_FILE_NAME = "agentd-connection.json";

export const PickyAgentdConnectionInfoSchema = z.object({
  protocolVersion: z.literal(PROTOCOL_VERSION),
  url: z.string().url(),
  token: z.string().min(1),
  port: z.number().int().positive(),
  pid: z.number().int().positive(),
  appSupportDir: z.string().min(1),
  defaultCwd: z.string().min(1),
  startedAt: z.string().datetime({ offset: true }),
});

export type PickyAgentdConnectionInfo = z.infer<typeof PickyAgentdConnectionInfoSchema>;

export function connectionInfoPath(appSupportDir: string): string {
  return join(appSupportDir, CONNECTION_INFO_FILE_NAME);
}

export async function writeConnectionInfo(appSupportDir: string, info: PickyAgentdConnectionInfo): Promise<string> {
  const path = connectionInfoPath(appSupportDir);
  PickyAgentdConnectionInfoSchema.parse(info);
  await mkdir(dirname(path), { recursive: true });
  const tempPath = join(dirname(path), `.${CONNECTION_INFO_FILE_NAME}.${process.pid}.${Date.now()}.${randomUUID()}.tmp`);
  await writeFile(tempPath, `${JSON.stringify(info, null, 2)}\n`, { mode: 0o600 });
  await chmod(tempPath, 0o600);
  await rename(tempPath, path);
  await chmod(path, 0o600);
  return path;
}

export async function readConnectionInfo(appSupportDir: string): Promise<PickyAgentdConnectionInfo> {
  return PickyAgentdConnectionInfoSchema.parse(JSON.parse(await readFile(connectionInfoPath(appSupportDir), "utf8")));
}

export async function removeConnectionInfo(appSupportDir: string): Promise<void> {
  await rm(connectionInfoPath(appSupportDir), { force: true });
}
