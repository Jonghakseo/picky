import { describe, expect, it } from "vitest";
import { isNonSkillSlashCommand } from "./slash-commands.js";

describe("isNonSkillSlashCommand", () => {
  it("matches simple commands with and without arguments", () => {
    expect(isNonSkillSlashCommand("/diff")).toBe(true);
    expect(isNonSkillSlashCommand("/name new title")).toBe(true);
    expect(isNonSkillSlashCommand("  /compact")).toBe(true);
  });

  it("matches namespaced prompt commands", () => {
    expect(isNonSkillSlashCommand("/github:pr-merge")).toBe(true);
    expect(isNonSkillSlashCommand("/github:pr-merge --squash")).toBe(true);
    expect(isNonSkillSlashCommand("/a:b:c")).toBe(true);
  });

  it("rejects skill commands so they stay visible as user text", () => {
    expect(isNonSkillSlashCommand("/skill:context7-cli")).toBe(false);
    expect(isNonSkillSlashCommand("  /skill:context7-cli lookup react")).toBe(false);
  });

  it("rejects path-like and plain-text inputs", () => {
    expect(isNonSkillSlashCommand("/Users/foo")).toBe(false);
    expect(isNonSkillSlashCommand("/github:pr-merge/extra")).toBe(false);
    expect(isNonSkillSlashCommand("hello world")).toBe(false);
    expect(isNonSkillSlashCommand("say /diff")).toBe(false);
  });
});
