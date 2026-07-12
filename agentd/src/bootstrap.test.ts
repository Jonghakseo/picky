import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { composeAgentdServices, createSingleUseSessionIdFactory, parseAgentdConfig, primeSessionIdFactoryForResume, type AgentdConfig } from "./bootstrap.js";
import { MockRuntime } from "./runtime/mock-runtime.js";
import type { PickyContextPacket } from "./protocol.js";

function tmpAppSupportDir(): string {
  return mkdtempSync(join(tmpdir(), "picky-agentd-bootstrap-"));
}

function envFor(partial: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  return {
    PICKY_AGENTD_TOKEN: "test-token",
    PICKY_AGENTD_RUNTIME: "mock",
    PICKY_APP_SUPPORT_DIR: tmpAppSupportDir(),
    ...partial,
  };
}

describe("parseAgentdConfig", () => {
  it("requires the auth token", () => {
    expect(() => parseAgentdConfig({})).toThrow(/PICKY_AGENTD_TOKEN/);
  });

  it("defaults to primary mode and port 17631", () => {
    const config = parseAgentdConfig(envFor());
    expect(config.mode).toBe("primary");
    expect(config.port).toBe(17631);
    expect(config.sessionId).toBeUndefined();
    expect(config.sessionCwd).toBeUndefined();
  });

  it("requires sessionId and sessionCwd in child mode", () => {
    expect(() => parseAgentdConfig(envFor({ PICKY_AGENTD_MODE: "child" }))).toThrow(/PICKY_AGENTD_SESSION_ID/);
    expect(() => parseAgentdConfig(envFor({ PICKY_AGENTD_MODE: "child", PICKY_AGENTD_SESSION_ID: "abc" }))).toThrow(/PICKY_AGENTD_SESSION_CWD/);
  });

  it("derives child config and defaults port to 0", () => {
    const config = parseAgentdConfig(envFor({
      PICKY_AGENTD_MODE: "child",
      PICKY_AGENTD_SESSION_ID: "pickle-123",
      PICKY_AGENTD_SESSION_CWD: "/tmp/workspace",
      PICKY_AGENTD_PRIMARY_URL: "ws://127.0.0.1:17631",
    }));
    expect(config.mode).toBe("child");
    expect(config.sessionId).toBe("pickle-123");
    expect(config.sessionCwd).toBe("/tmp/workspace");
    expect(config.defaultCwd).toBe("/tmp/workspace");
    expect(config.port).toBe(0);
    expect(config.primaryUrl).toBe("ws://127.0.0.1:17631");
  });

  it("ignores an inherited PICKY_AGENTD_PORT in child mode so children never reuse a primary's pinned port", () => {
    const config = parseAgentdConfig(envFor({
      PICKY_AGENTD_MODE: "child",
      PICKY_AGENTD_SESSION_ID: "pickle-123",
      PICKY_AGENTD_SESSION_CWD: "/tmp/workspace",
      PICKY_AGENTD_PORT: "12345",
    }));
    expect(config.port).toBe(0);
  });

  it("rejects unknown PICKY_AGENTD_MODE values", () => {
    expect(() => parseAgentdConfig(envFor({ PICKY_AGENTD_MODE: "worker" }))).toThrow(/Unknown PICKY_AGENTD_MODE/);
    expect(() => parseAgentdConfig(envFor({ PICKY_AGENTD_MODE: "Child" }))).toThrow(/Unknown PICKY_AGENTD_MODE/);
  });

  it("rejects malformed PICKY_AGENTD_PORT in primary mode", () => {
    expect(() => parseAgentdConfig(envFor({ PICKY_AGENTD_PORT: "abc" }))).toThrow(/Invalid PICKY_AGENTD_PORT/);
    expect(() => parseAgentdConfig(envFor({ PICKY_AGENTD_PORT: "999999" }))).toThrow(/Invalid PICKY_AGENTD_PORT/);
  });

  it("parses optional Pickle model and thinking overrides", () => {
    const config = parseAgentdConfig(envFor({
      PICKY_PICKLE_MODEL: " anthropic/claude-sonnet-4-5 ",
      PICKY_PICKLE_THINKING_LEVEL: "high",
    }));
    expect(config.pickleModelPattern).toBe("anthropic/claude-sonnet-4-5");
    expect(config.pickleThinkingLevel).toBe("high");
  });

  it("falls back to global Pickle defaults when Pickle thinking is absent or invalid", () => {
    expect(parseAgentdConfig(envFor()).pickleThinkingLevel).toBeUndefined();
    expect(parseAgentdConfig(envFor({ PICKY_PICKLE_THINKING_LEVEL: "invalid" })).pickleThinkingLevel).toBeUndefined();
  });
});

describe("createSingleUseSessionIdFactory", () => {
  it("returns the configured id once and then throws", () => {
    const factory = createSingleUseSessionIdFactory("pickle-xyz");
    expect(factory()).toBe("pickle-xyz");
    expect(() => factory()).toThrow(/already issued/);
  });
});

describe("composeAgentdServices", () => {
  function baseConfig(overrides: Partial<AgentdConfig> = {}): AgentdConfig {
    return {
      mode: "primary",
      port: 0,
      token: "test-token",
      appSupportDir: tmpAppSupportDir(),
      defaultCwd: "/tmp",
      mainAgentCwd: "/tmp",
      mainAgentThinkingLevel: "medium",
      useMockRuntime: true,
      ...overrides,
    };
  }

  it("constructs a main runtime in primary mode (non-mock)", () => {
    const mainFactory = vi.fn(() => new MockRuntime());
    const result = composeAgentdServices(baseConfig({ useMockRuntime: false }), {
      runtimeFactory: () => new MockRuntime(),
      mainRuntimeFactory: mainFactory,
    });
    expect(result.mainRuntime).toBeDefined();
    expect(mainFactory).toHaveBeenCalledOnce();
    expect(result.cwdStabilization).toBeUndefined();
  });

  it("does not stabilize cwd or build a main runtime in primary mode", () => {
    const stabilizeCwd = vi.fn();
    const mainFactory = vi.fn();
    const result = composeAgentdServices(baseConfig({ useMockRuntime: true }), { stabilizeCwd, mainRuntimeFactory: mainFactory });
    expect(result.mainRuntime).toBeUndefined();
    expect(stabilizeCwd).not.toHaveBeenCalled();
    expect(mainFactory).not.toHaveBeenCalled();
  });

  it("skips main runtime and registers stabilizeProcessCwd in child mode", () => {
    const stabilizeCwd = vi.fn(() => ({ ok: true, cwd: "/tmp/workspace" }));
    const mainFactory = vi.fn(() => new MockRuntime());
    const result = composeAgentdServices(
      baseConfig({
        mode: "child",
        sessionId: "pickle-xyz",
        sessionCwd: "/tmp/workspace",
        useMockRuntime: false,
      }),
      {
        runtimeFactory: () => new MockRuntime(),
        mainRuntimeFactory: mainFactory,
        stabilizeCwd,
      },
    );
    expect(stabilizeCwd).toHaveBeenCalledWith("/tmp/workspace");
    expect(result.cwdStabilization).toEqual({ ok: true, cwd: "/tmp/workspace" });
    expect(result.mainRuntime).toBeUndefined();
    expect(mainFactory).not.toHaveBeenCalled();
  });

  it("supervisor in child mode has no mainRuntime wired", () => {
    const stabilizeCwd = vi.fn(() => ({ ok: true, cwd: "/tmp/workspace" }));
    const result = composeAgentdServices(
      baseConfig({
        mode: "child",
        sessionId: "pickle-xyz",
        sessionCwd: "/tmp/workspace",
        useMockRuntime: true,
      }),
      { stabilizeCwd },
    );
    // supervisor.prewarmMainAgent is a no-op when mainRuntime is absent — exercise that path.
    return result.supervisor.prewarmMainAgent("/tmp").then(() => {
      expect(result.mainRuntime).toBeUndefined();
    });
  });

  it("throws when child cwd stabilization fails", () => {
    const stabilizeCwd = vi.fn(() => ({ ok: false, cwd: "/tmp/workspace", error: new Error("permission denied") }));
    expect(() => composeAgentdServices(
      baseConfig({
        mode: "child",
        sessionId: "pickle-xyz",
        sessionCwd: "/tmp/workspace",
        useMockRuntime: true,
      }),
      { stabilizeCwd },
    )).toThrow(/Failed to stabilize child cwd/);
  });

  it("primes the single-use factory when a scoped session is rehydrated on restart", async () => {
    const appSupportDir = tmpAppSupportDir();
    // Boot a child once, create a session, persist it, then re-compose to simulate restart.
    const first = composeAgentdServices(
      baseConfig({
        mode: "child",
        sessionId: "pickle-resume",
        sessionCwd: appSupportDir,
        appSupportDir,
        useMockRuntime: true,
      }),
      { stabilizeCwd: () => ({ ok: true, cwd: appSupportDir }) },
    );
    const context: PickyContextPacket = {
      id: "ctx-1", source: "text", capturedAt: new Date().toISOString(),
      screenshots: [], inkMarks: [], warnings: [], browser: undefined,
      transcript: "persist me", cwd: appSupportDir,
    };
    await first.supervisor.create(context);

    const second = composeAgentdServices(
      baseConfig({
        mode: "child",
        sessionId: "pickle-resume",
        sessionCwd: appSupportDir,
        appSupportDir,
        useMockRuntime: true,
      }),
      { stabilizeCwd: () => ({ ok: true, cwd: appSupportDir }) },
    );
    await second.supervisor.load();
    expect(primeSessionIdFactoryForResume(second)).toBe("consumed");
    // A second createTask after restart must fail loudly rather than overwrite the persisted session.
    await expect(second.supervisor.create(context)).rejects.toThrow(/already issued/);
  });

  it("in child mode the supervisor uses PICKY_AGENTD_SESSION_ID for the first session", async () => {
    const appSupportDir = tmpAppSupportDir();
    const result = composeAgentdServices(
      baseConfig({
        mode: "child",
        sessionId: "pickle-fixed",
        sessionCwd: appSupportDir,
        appSupportDir,
        useMockRuntime: true,
      }),
      { stabilizeCwd: () => ({ ok: true, cwd: appSupportDir }) },
    );
    const context: PickyContextPacket = {
      id: "ctx-1",
      source: "text",
      capturedAt: new Date().toISOString(),
      screenshots: [],
      inkMarks: [],
      warnings: [],
      browser: undefined,
      transcript: "hello child",
      cwd: appSupportDir,
    };
    const session = await result.supervisor.create(context);
    expect(session.id).toBe("pickle-fixed");
    // The scoped store should have written under sessions/<sessionId>/<sessionId>.json.
    expect(existsSync(join(appSupportDir, "sessions", "pickle-fixed", "pickle-fixed.json"))).toBe(true);
  });
});
