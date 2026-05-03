import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ArtifactStore, extractChangedFilesFromExplicitText, extractGithubPullRequestUrls, extractSessionLinkArtifacts, extractSessionLinks, githubPullRequestTitle, renderSessionReport } from "./artifact-store.js";
import { LogStore } from "./log-store.js";

describe("ArtifactStore", () => {
  it("writes, reads, and lists artifacts under injected app support root", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-artifacts-"));
    const store = new ArtifactStore(root);
    const artifact = await store.write("session-1", { id: "report", kind: "report", title: "Report", fileName: "report.md", content: "# Done" });

    expect(artifact.path).toContain(root);
    await expect(store.read("session-1", "report.md")).resolves.toEqual(Buffer.from("# Done"));
    await expect(store.list("session-1")).resolves.toEqual(["report.md"]);
  });

  it("generates neutral terminal reports for completed, failed, and cancelled sessions", async () => {
    for (const status of ["completed", "failed", "cancelled"] as const) {
      const markdown = renderSessionReport({
        id: `session-${status}`,
        title: "Final task",
        status,
        cwd: "/tmp/project",
        createdAt: "2026-05-01T00:00:00.000Z",
        updatedAt: "2026-05-01T00:00:01.000Z",
        lastSummary: "Final answer. PR: https://github.com/acme/repo/pull/42",
        logs: [],
        tools: [{ toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "tests passed" }],
        artifacts: [],
        changedFiles: [],
      });
      expect(markdown).toContain(`Status: \`${status}\``);
      expect(markdown).toContain("Final answer");
      expect(markdown).not.toContain("Verification passed");
    }
  });

  it("renders tool summary as tool call counts only", () => {
    const markdown = renderSessionReport({
      id: "session-tools",
      title: "Tool task",
      status: "completed",
      cwd: "/tmp/project",
      createdAt: "2026-05-01T00:00:00.000Z",
      updatedAt: "2026-05-01T00:00:01.000Z",
      logs: [],
      tools: [
        { toolCallId: "tool-1", name: "bash", status: "succeeded", preview: "tests passed" },
        { toolCallId: "tool-2", name: "bash", status: "failed", preview: "error output" },
        { toolCallId: "tool-3", name: "read", status: "succeeded", preview: "file contents" },
      ],
      artifacts: [],
      changedFiles: [],
    });

    expect(markdown).toContain("## Tool summary\n- `bash`: 2\n- `read`: 1");
    expect(markdown).not.toContain("tests passed");
    expect(markdown).not.toContain("error output");
    expect(markdown).not.toContain("succeeded");
    expect(markdown).not.toContain("failed");
  });

  it("extracts GitHub, Slack, Notion links and changed files only from explicit output", () => {
    expect(extractGithubPullRequestUrls("Created https://github.com/acme/repo/pull/42")).toEqual(["https://github.com/acme/repo/pull/42"]);
    expect(githubPullRequestTitle("https://github.com/acme/repo/issues/2777")).toBe("#2777");
    expect(extractSessionLinks([
      "GitHub https://github.com/acme/repo/issues/2777",
      "Slack https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249",
      "Notion https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226?source=copy_link",
      "Notion duplicate https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226",
      "Notion app https://app.notion.com/p/351d62c6956180498d13e3494b488192",
    ].join("\n"))).toEqual([
      { kind: "github", title: "#2777", url: "https://github.com/acme/repo/issues/2777" },
      { kind: "slack", title: "Slack", url: "https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249" },
      { kind: "notion", title: "Notion", url: "https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226" },
      { kind: "notion", title: "Notion", url: "https://app.notion.com/p/351d62c6956180498d13e3494b488192" },
    ]);
    expect(extractSessionLinkArtifacts("https://github.com/acme/repo/pull/42", "2026-05-01T00:00:00.000Z")[0]).toMatchObject({ kind: "github", title: "#42", url: "https://github.com/acme/repo/pull/42" });
    expect(extractGithubPullRequestUrls("I will open a PR later")).toEqual([]);
    expect(extractChangedFilesFromExplicitText("Changed file: M Picky/App.swift - updated HUD")).toEqual([{ status: "M", path: "Picky/App.swift", summary: "updated HUD" }]);
  });

  it("rejects path traversal artifact names and unsafe session ids", async () => {
    const store = new ArtifactStore(await mkdtemp(join(tmpdir(), "picky-artifacts-")));
    await expect(store.write("session-1", { id: "evil", kind: "report", title: "Evil", fileName: "../evil", content: "no" })).rejects.toThrow(/Unsafe artifact path/);
    await expect(store.write("../session", { id: "evil", kind: "report", title: "Evil", fileName: "ok.md", content: "no" })).rejects.toThrow(/Unsafe path segment/);
  });
});

describe("LogStore", () => {
  it("appends, reads, and lists durable session logs", async () => {
    const root = await mkdtemp(join(tmpdir(), "picky-logs-"));
    const store = new LogStore(root);
    const path = await store.append("session-1", "hello");
    expect(path).toContain(root);
    await store.append("session-1", "world");
    expect(await store.read("session-1")).toContain("hello");
    expect(await store.read("session-1")).toContain("world");
    await expect(store.list()).resolves.toEqual(["session-1.log"]);
  });

  it("rejects unsafe log session ids", async () => {
    const store = new LogStore(await mkdtemp(join(tmpdir(), "picky-logs-")));
    await expect(store.append("../evil", "nope")).rejects.toThrow(/Unsafe artifact path|Unsafe path segment/);
  });
});
