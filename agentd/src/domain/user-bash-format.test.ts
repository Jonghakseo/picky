import { describe, expect, it } from "vitest";
import {
  appendLiveBashOutput,
  formatUserBashFailureSystemMessage,
  formatUserBashRunningSystemMessage,
  formatUserBashSystemMessage,
} from "./user-bash-format.js";

const liveOutputLimit = 8000;

describe("user bash system message formatting", () => {
  it.each([
    ["completed", () => formatUserBashSystemMessage({ command: "echo output", excludeFromContext: false }, { output: "before\n```\nafter\n````", exitCode: 0, cancelled: false, truncated: false })],
    ["running", () => formatUserBashRunningSystemMessage({ command: "echo output", excludeFromContext: false }, "before\n```\nafter\n````", 0)],
    ["failed", () => formatUserBashFailureSystemMessage({ command: "echo output", excludeFromContext: false }, "command failed", "before\n```\nafter\n````")],
  ])("uses a fence longer than backtick runs in %s output", (_status, format) => {
    const message = format();
    const fence = "`".repeat(5);

    expect(message).toContain(`${fence}console\n`);
    expect(message).toContain(`\n${fence}`);
  });
});

describe("appendLiveBashOutput", () => {
  it("does not start truncated output in the middle of a surrogate pair", () => {
    const output = appendLiveBashOutput("", `a😀${"b".repeat(liveOutputLimit - 1)}`);

    expect(output).toHaveLength(liveOutputLimit - 1);
    const firstCodeUnit = output.charCodeAt(0);
    expect(firstCodeUnit >= 0xdc00 && firstCodeUnit <= 0xdfff).toBe(false);
  });

  it("keeps the output tail within the live output limit", () => {
    const output = appendLiveBashOutput("prefix", "x".repeat(liveOutputLimit));

    expect(output).toHaveLength(liveOutputLimit);
    expect(output).toBe("x".repeat(liveOutputLimit));
  });
});
