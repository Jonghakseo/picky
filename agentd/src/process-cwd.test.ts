import { describe, expect, it, vi } from "vitest";
import { cwdOrFallback, stabilizeProcessCwd } from "./process-cwd.js";

describe("process cwd stabilization", () => {
  it("falls back when the current working directory cannot be read", () => {
    expect(cwdOrFallback("/stable", () => {
      throw Object.assign(new Error("uv_cwd"), { code: "ENOENT" });
    })).toBe("/stable");
  });

  it("switches the daemon cwd to a stable directory", () => {
    const mkdir = vi.fn();
    const chdir = vi.fn();

    const result = stabilizeProcessCwd("/stable", {
      mkdir: mkdir as never,
      chdir,
      cwd: () => "/stable",
    });

    expect(result).toEqual({ ok: true, cwd: "/stable" });
    expect(mkdir).toHaveBeenCalledWith("/stable", { recursive: true });
    expect(chdir).toHaveBeenCalledWith("/stable");
  });

  it("still reports a fallback cwd if stabilization fails after the launch cwd disappeared", () => {
    const error = Object.assign(new Error("permission denied"), { code: "EACCES" });
    const onError = vi.fn();

    const result = stabilizeProcessCwd("/stable", {
      mkdir: () => { throw error; },
      chdir: vi.fn(),
      cwd: () => { throw Object.assign(new Error("uv_cwd"), { code: "ENOENT" }); },
      onError,
    });

    expect(result.ok).toBe(false);
    expect(result.cwd).toBe("/stable");
    expect(result.error).toBe(error);
    expect(onError).toHaveBeenCalledWith(error);
  });
});
