import { describe, expect, it } from "vitest";
import { summarizeProviderError } from "./provider-error-summary.js";

describe("summarizeProviderError", () => {
  it("keeps the status code and the provider message, dropping the JSON envelope and request id", () => {
    expect(summarizeProviderError(`429 {"type":"error","error":{"type":"rate_limit_error","message":"Usage credits are required for fast mode."},"request_id":"req_011Cfh8yJvQoPMuwdDwkznW4"}`))
      .toEqual({ code: "429", message: "Usage credits are required for fast mode." });
  });

  it("keeps a plain-text 5xx reason", () => {
    expect(summarizeProviderError("503 Service Unavailable")).toEqual({ code: "503", message: "Service Unavailable" });
  });

  it("reports errors without a status code as their first line", () => {
    expect(summarizeProviderError("fetch failed\n    at node:internal")).toEqual({ message: "fetch failed" });
  });

  it("does not treat a leading number that is part of a word as a status code", () => {
    expect(summarizeProviderError("5000ms timeout exceeded")).toEqual({ message: "5000ms timeout exceeded" });
  });
});
