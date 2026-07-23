import { describe, expect, it, vi } from "vitest";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { reloadModelRuntimeCredentials } from "./pi-capabilities.js";

describe("reloadModelRuntimeCredentials", () => {
  it("reloads the credential snapshot before refreshing model availability", async () => {
    const calls: string[] = [];
    const modelRuntime = {
      credentials: { store: { reload: () => calls.push("credentials") } },
      refresh: vi.fn(async (options) => {
        calls.push(`refresh:${String(options?.allowNetwork)}`);
        return { aborted: false, errors: new Map() };
      }),
    } as unknown as ModelRuntime;

    await reloadModelRuntimeCredentials(modelRuntime, "session-auth");

    expect(calls).toEqual(["credentials", "refresh:false"]);
  });

  it("fails visibly when the installed Pi runtime removes credential reload", async () => {
    const modelRuntime = {
      refresh: vi.fn(),
    } as unknown as ModelRuntime;

    await expect(reloadModelRuntimeCredentials(modelRuntime, "session-auth")).rejects.toThrow(
      "Installed Pi runtime cannot reload changed credentials",
    );
  });
});
