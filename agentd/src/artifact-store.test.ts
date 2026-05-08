import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { extractChangedFilesFromExplicitText, extractGithubPullRequestUrls, extractSessionLinkArtifacts, extractSessionLinks, githubPullRequestTitle } from "./artifact-store.js";
import { LogStore } from "./log-store.js";

describe("session link extraction", () => {
  it("extracts known work links and changed files only from explicit output", () => {
    expect(extractGithubPullRequestUrls("Created https://github.com/acme/repo/pull/42")).toEqual(["https://github.com/acme/repo/pull/42"]);
    expect(githubPullRequestTitle("https://github.com/acme/repo/issues/2777")).toBe("#2777");
    expect(extractSessionLinks([
      "GitHub https://github.com/acme/repo/issues/2777",
      "Slack https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249",
      "Notion https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226?source=copy_link",
      "Notion duplicate https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226",
      "Notion app https://app.notion.com/p/351d62c6956180498d13e3494b488192",
      "Jira https://creatrip.atlassian.net/browse/COM-123?focusedCommentId=1",
      "Sentry https://creatrip.sentry.io/issues/1234567890/?project=1",
      "Linear https://linear.app/acme/issue/ENG-456/fix-checkout",
      "Figma https://www.figma.com/design/abc123/Product?node-id=1-2",
      "Docs https://docs.google.com/document/d/doc123/edit",
      "Sheets https://docs.google.com/spreadsheets/d/sheet123/edit",
      "Slides https://docs.google.com/presentation/d/slide123/edit",
      "Drive https://drive.google.com/file/d/file123/view",
    ].join("\n"))).toEqual([
      { kind: "github", title: "#2777", url: "https://github.com/acme/repo/issues/2777" },
      { kind: "slack", title: "Slack", url: "https://creatrip.slack.com/archives/C012ZMHLPDW/p1777763920621249" },
      { kind: "notion", title: "Notion", url: "https://www.notion.so/creatrip/355d62c6956180cf8695dcdf5c4ff226" },
      { kind: "notion", title: "Notion", url: "https://app.notion.com/p/351d62c6956180498d13e3494b488192" },
      { kind: "jira", title: "COM-123", url: "https://creatrip.atlassian.net/browse/COM-123" },
      { kind: "sentry", title: "Sentry", url: "https://creatrip.sentry.io/issues/1234567890/" },
      { kind: "linear", title: "ENG-456", url: "https://linear.app/acme/issue/ENG-456/fix-checkout" },
      { kind: "figma", title: "Figma", url: "https://www.figma.com/design/abc123/Product" },
      { kind: "googleDocs", title: "Docs", url: "https://docs.google.com/document/d/doc123/edit" },
      { kind: "googleSheets", title: "Sheets", url: "https://docs.google.com/spreadsheets/d/sheet123/edit" },
      { kind: "googleSlides", title: "Slides", url: "https://docs.google.com/presentation/d/slide123/edit" },
      { kind: "googleDrive", title: "Drive", url: "https://drive.google.com/file/d/file123/view" },
    ]);
    expect(extractSessionLinkArtifacts("https://github.com/acme/repo/pull/42", "2026-05-01T00:00:00.000Z")[0]).toMatchObject({ kind: "github", title: "#42", url: "https://github.com/acme/repo/pull/42" });
    expect(extractGithubPullRequestUrls("I will open a PR later")).toEqual([]);
    expect(extractChangedFilesFromExplicitText("Changed file: M Picky/App.swift - updated HUD")).toEqual([{ status: "M", path: "Picky/App.swift", summary: "updated HUD" }]);
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
