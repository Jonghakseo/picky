import { describe, expect, it, vi } from "vitest";
import {
  DEFAULT_REALTIME_SUMMARIZER_MODEL,
  RealtimeOutputSummarizer,
  type RealtimeSummarizerCompleter,
  type RealtimeSummarizerCompleterRequest,
} from "./realtime-output-summarizer.js";

function makeRecordingCompleter(reply: string): { completer: RealtimeSummarizerCompleter; calls: RealtimeSummarizerCompleterRequest[] } {
  const calls: RealtimeSummarizerCompleterRequest[] = [];
  const completer: RealtimeSummarizerCompleter = async (request) => {
    calls.push(request);
    return reply;
  };
  return { completer, calls };
}

describe("RealtimeOutputSummarizer", () => {
  it("uses the bash-shaped system prompt and forwards the captured output", async () => {
    const { completer, calls } = makeRecordingCompleter("Built successfully. 2 files changed.");
    const summarizer = new RealtimeOutputSummarizer({ completer });

    const result = await summarizer.summarize({
      kind: "bash",
      command: "npm test",
      cwd: "/repo",
      exitCode: 0,
      rawOutput: "lots of test output\n".repeat(200),
    });

    expect(result).toBe("Built successfully. 2 files changed.");
    expect(calls).toHaveLength(1);
    const [call] = calls;
    expect(call.model).toBe(DEFAULT_REALTIME_SUMMARIZER_MODEL);
    expect(call.systemPrompt).toContain("shell command");
    expect(call.userPrompt).toContain("Command: npm test");
    expect(call.userPrompt).toContain("Cwd: /repo");
    expect(call.userPrompt).toContain("Exit code: 0");
  });

  it("uses the read-shaped system prompt for kind=read", async () => {
    const { completer, calls } = makeRecordingCompleter("Config has 12 sections; entry point is index.ts.");
    const summarizer = new RealtimeOutputSummarizer({ completer });

    const result = await summarizer.summarize({
      kind: "read",
      path: "/repo/package.json",
      rawOutput: "{ \"foo\": 1, ... very long ... }",
    });

    expect(result).toBe("Config has 12 sections; entry point is index.ts.");
    expect(calls[0].systemPrompt).toContain("file contents");
    expect(calls[0].userPrompt).toContain("Path: /repo/package.json");
  });

  it("returns undefined when the completer throws", async () => {
    const summarizer = new RealtimeOutputSummarizer({
      completer: async () => { throw new Error("boom"); },
    });

    const result = await summarizer.summarize({ kind: "bash", rawOutput: "stuff" });
    expect(result).toBeUndefined();
  });

  it("returns undefined when the completer returns an empty string", async () => {
    const { completer } = makeRecordingCompleter("   \n  ");
    const summarizer = new RealtimeOutputSummarizer({ completer });

    const result = await summarizer.summarize({ kind: "bash", rawOutput: "non-empty" });
    expect(result).toBeUndefined();
  });

  it("returns undefined for empty rawOutput without invoking the completer", async () => {
    const { completer, calls } = makeRecordingCompleter("never-called");
    const summarizer = new RealtimeOutputSummarizer({ completer });

    const result = await summarizer.summarize({ kind: "bash", rawOutput: "   \n" });
    expect(result).toBeUndefined();
    expect(calls).toHaveLength(0);
  });

  it("aborts the completer on timeout and returns undefined", async () => {
    vi.useFakeTimers();
    let abortObserved = false;
    const completer: RealtimeSummarizerCompleter = ({ signal }) => new Promise<string>((_resolve, reject) => {
      signal.addEventListener("abort", () => {
        abortObserved = true;
        reject(new DOMException("aborted", "AbortError"));
      });
    });

    const summarizer = new RealtimeOutputSummarizer({ completer, timeoutMs: 50 });
    const promise = summarizer.summarize({ kind: "bash", rawOutput: "non-empty" });
    await vi.advanceTimersByTimeAsync(60);
    const result = await promise;

    expect(result).toBeUndefined();
    expect(abortObserved).toBe(true);
    vi.useRealTimers();
  });

  it("clamps very large raw outputs before sending to the completer", async () => {
    const { completer, calls } = makeRecordingCompleter("ok");
    const summarizer = new RealtimeOutputSummarizer({ completer, inputMaxBytes: 1024 });

    await summarizer.summarize({ kind: "bash", rawOutput: "x".repeat(8 * 1024) });

    const userPrompt = calls[0].userPrompt;
    const bodyStart = userPrompt.indexOf("---\n") + 4;
    const body = userPrompt.slice(bodyStart);
    expect(Buffer.byteLength(body, "utf8")).toBeLessThanOrEqual(1024);
  });

  it("honours model override via constructor and setter", async () => {
    const { completer, calls } = makeRecordingCompleter("ok");
    const summarizer = new RealtimeOutputSummarizer({ completer, model: "anthropic/claude-haiku" });
    await summarizer.summarize({ kind: "bash", rawOutput: "data" });
    expect(calls[0].model).toBe("anthropic/claude-haiku");

    summarizer.setModel("openai/gpt-4o-mini");
    await summarizer.summarize({ kind: "bash", rawOutput: "data" });
    expect(calls[1].model).toBe("openai/gpt-4o-mini");
  });
});
