import { describe, expect, it } from "vitest";
import { SHELL_AUDIT_PREVIEW_CHARS, summarizeShellCommand } from "./shell-audit.js";

describe("the audit trail of a phone's shell command", () => {
  it("keeps a harmless command readable and records its length", () => {
    expect(summarizeShellCommand("git status --short")).toEqual({
      shellCommand: "git status --short",
      shellCommandChars: 18,
    });
  });

  it.each([
    ["curl -H 'Authorization: Bearer abc123.def-456' https://x.test", "abc123.def-456"],
    ["export API_TOKEN=s3cr3tvalue && run", "s3cr3tvalue"],
    ["mysql --password hunter2 -e 'select 1'", "hunter2"],
    ["mysql --password=hunter2", "hunter2"],
    ["PASSWORD='two words' ./deploy", "two words"],
    ["curl -u admin:hunter2 https://x.test", "hunter2"],
    ["git clone https://me:hunter2@github.com/a/b.git", "hunter2"],
    ["echo ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_abcdefghij"],
    ["echo sk-abcdefghijklmnopqrstuvwx", "sk-abcdefghij"],
    ["aws s3 ls --profile x AKIAABCDEFGHIJKLMNOP", "AKIAABCDEFGHIJKLMNOP"],
  ])("masks the secret in %s", (command, secret) => {
    const { shellCommand } = summarizeShellCommand(command);
    expect(shellCommand).not.toContain(secret);
    expect(shellCommand).toContain("***");
  });

  it("cuts a long command after masking, so a secret at the cut leaves no fragment", () => {
    const secret = "hunter2hunter2hunter2";
    const command = `${"x".repeat(SHELL_AUDIT_PREVIEW_CHARS - 12)} password=${secret}`;
    const summary = summarizeShellCommand(command);
    expect(summary.shellCommandChars).toBe(command.length);
    expect(summary.shellCommand).not.toContain("hunter2");
    expect(summary.shellCommand.length).toBeLessThanOrEqual(SHELL_AUDIT_PREVIEW_CHARS + 1);
  });

  it("marks a command that was cut", () => {
    const { shellCommand, shellCommandChars } = summarizeShellCommand(`echo ${"a ".repeat(100)}`);
    expect(shellCommand.endsWith("…")).toBe(true);
    expect(shellCommandChars).toBeGreaterThan(SHELL_AUDIT_PREVIEW_CHARS);
  });
});
