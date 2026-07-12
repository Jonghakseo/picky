import { describe, expect, it } from "vitest";
import { appendLiveBashOutput } from "./user-bash-format.js";

const liveOutputLimit = 8000;

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
