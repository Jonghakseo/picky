import { describe, expect, it } from "vitest";
import { canonicalizeSubagentMentions } from "./subagent-mention.js";

describe("canonicalizeSubagentMentions", () => {
  it("rewrites a Pi-expanded subagent mention back to the raw `>name` shorthand", () => {
    expect(canonicalizeSubagentMentions("응 그렇게 작업해줘 subagent:worker 에 위임"))
      .toBe("응 그렇게 작업해줘 >worker 에 위임");
  });

  it("leaves the raw `>name` shorthand unchanged so both sides converge", () => {
    expect(canonicalizeSubagentMentions("응 그렇게 작업해줘 >worker 에 위임"))
      .toBe("응 그렇게 작업해줘 >worker 에 위임");
  });

  it("canonicalizes a parenthesized mention", () => {
    expect(canonicalizeSubagentMentions("delegate (subagent:code-reviewer) now"))
      .toBe("delegate (>code-reviewer) now");
  });

  it("does not touch a `subagent:` fragment embedded in another word", () => {
    expect(canonicalizeSubagentMentions("mysubagent:worker stays put"))
      .toBe("mysubagent:worker stays put");
  });

  it("rewrites every occurrence", () => {
    expect(canonicalizeSubagentMentions("subagent:a and subagent:b"))
      .toBe(">a and >b");
  });
});
