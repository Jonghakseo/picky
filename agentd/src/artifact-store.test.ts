import { describe, expect, it } from "vitest";
import { extractChangedFilesFromExplicitText, extractGithubPullRequestUrls, extractSessionLinkArtifacts, extractSessionLinks, githubPullRequestTitle } from "./artifact-store.js";

const supportedSessionLinks = [
  { label: "GitHub", kind: "github", title: "#42", url: "https://github.com/acme/repo/pull/42" },
  { label: "Slack", kind: "slack", title: "Slack", url: "https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249" },
  { label: "Jira", kind: "jira", title: "COM-123", url: "https://example.atlassian.net/browse/COM-123" },
  { label: "Sentry", kind: "sentry", title: "Sentry", url: "https://example.sentry.io/issues/1234567890/" },
  { label: "Linear", kind: "linear", title: "ENG-456", url: "https://linear.app/acme/issue/ENG-456/fix-checkout" },
  { label: "Figma", kind: "figma", title: "Figma", url: "https://www.figma.com/design/abc123/Product" },
  { label: "Google Docs", kind: "googleDocs", title: "Docs", url: "https://docs.google.com/document/d/doc123/edit" },
  { label: "Google Sheets", kind: "googleSheets", title: "Sheets", url: "https://docs.google.com/spreadsheets/d/sheet123/edit" },
  { label: "Google Slides", kind: "googleSlides", title: "Slides", url: "https://docs.google.com/presentation/d/slide123/edit" },
  { label: "Google Drive", kind: "googleDrive", title: "Drive", url: "https://drive.google.com/file/d/file123/view" },
  { label: "Notion", kind: "notion", title: "Notion", url: "https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226" },
] as const;

describe("session link extraction", () => {
  it("extracts known work links and changed files only from explicit output", () => {
    expect(extractGithubPullRequestUrls("Created https://github.com/acme/repo/pull/42")).toEqual(["https://github.com/acme/repo/pull/42"]);
    expect(githubPullRequestTitle("https://github.com/acme/repo/issues/2777")).toBe("#2777");
    expect(extractSessionLinks([
      "GitHub https://github.com/acme/repo/issues/2777",
      "Slack https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249",
      "Notion https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226?source=copy_link",
      "Notion duplicate https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226",
      "Notion app https://app.notion.com/p/351d62c6956180498d13e3494b488192",
      "Jira https://example.atlassian.net/browse/COM-123?focusedCommentId=1",
      "Sentry https://example.sentry.io/issues/1234567890/?project=1",
      "Linear https://linear.app/acme/issue/ENG-456/fix-checkout",
      "Figma https://www.figma.com/design/abc123/Product?node-id=1-2",
      "Docs https://docs.google.com/document/d/doc123/edit",
      "Sheets https://docs.google.com/spreadsheets/d/sheet123/edit",
      "Slides https://docs.google.com/presentation/d/slide123/edit",
      "Drive https://drive.google.com/file/d/file123/view",
    ].join("\n"))).toEqual([
      { kind: "github", title: "#2777", url: "https://github.com/acme/repo/issues/2777" },
      { kind: "slack", title: "Slack", url: "https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249" },
      { kind: "notion", title: "Notion", url: "https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226" },
      { kind: "notion", title: "Notion", url: "https://app.notion.com/p/351d62c6956180498d13e3494b488192" },
      { kind: "jira", title: "COM-123", url: "https://example.atlassian.net/browse/COM-123" },
      { kind: "sentry", title: "Sentry", url: "https://example.sentry.io/issues/1234567890/" },
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

  it("extracts GitHub issue and pull request links with trailing slashes", () => {
    expect(extractGithubPullRequestUrls("Created https://github.com/acme/repo/pull/42/")).toEqual(["https://github.com/acme/repo/pull/42/"]);
    expect(githubPullRequestTitle("https://github.com/acme/repo/issues/2777/")).toBe("#2777");
    expect(extractSessionLinks("GitHub https://github.com/acme/repo/issues/2777/")).toEqual([
      { kind: "github", title: "#2777", url: "https://github.com/acme/repo/issues/2777/" },
    ]);
  });

  it("stops links before JSON delimiters and escaped newlines", () => {
    expect(extractSessionLinks([
      '{"url":"https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226","kind":"notion"}',
      'Transcript https://www.notion.so/example/451d62c6956180498d13e3494b488193\\nnext line',
      '{"url":"https://app.notion.com/p/351d62c6956180498d13e3494b488192"}',
    ].join("\n"))).toEqual([
      { kind: "notion", title: "Notion", url: "https://www.notion.so/example/355d62c6956180cf8695dcdf5c4ff226" },
      { kind: "notion", title: "Notion", url: "https://www.notion.so/example/451d62c6956180498d13e3494b488193" },
      { kind: "notion", title: "Notion", url: "https://app.notion.com/p/351d62c6956180498d13e3494b488192" },
    ]);
  });

  it("extracts every supported link kind from common JSON and log wrappers", () => {
    const wrappers = [
      (url: string, kind: string) => `{"url":"${url}","kind":"${kind}"}`,
      (url: string) => url.replaceAll("/", "\\/"),
      (url: string) => `&quot;${url}&quot;`,
      (url: string) => `artifact link=${url}, source=agentd`,
      (url: string) => `artifact link=${url}\nnext line`,
      (url: string) => `artifact link=${url}\\nnext line`,
    ];

    for (const link of supportedSessionLinks) {
      for (const wrap of wrappers) {
        expect(extractSessionLinks(wrap(link.url, link.kind))).toEqual([
          { kind: link.kind, title: link.title, url: link.url },
        ]);
      }
    }
  });

  it("extracts links from a synthetic agentd activity log fixture", () => {
    const log = [
      '[picky-agentd] session:event {"type":"artifact","url":"https://github.com/acme/repo/pull/42","kind":"github"}',
      '[picky-agentd] tool:stdout link=https:\\/\\/example.slack.com\\/archives\\/C012ZMHLPDW\\/p1777763920621249, status=ok',
      '[picky-agentd] assistant:message &quot;https://example.sentry.io/issues/1234567890/&quot;\\nrendered',
      '[picky-agentd] report:links https://www.figma.com/design/abc123/Product\nnext line',
    ].join("\n");

    expect(extractSessionLinks(log)).toEqual([
      { kind: "github", title: "#42", url: "https://github.com/acme/repo/pull/42" },
      { kind: "slack", title: "Slack", url: "https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249" },
      { kind: "sentry", title: "Sentry", url: "https://example.sentry.io/issues/1234567890/" },
      { kind: "figma", title: "Figma", url: "https://www.figma.com/design/abc123/Product" },
    ]);
  });

  it("extracts markdown-wrapped links without their closing parentheses", () => {
    expect(extractSessionLinks([
      "PR [#123](https://github.com/creatrip/picky/pull/123)",
      "Slack [thread](https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249)",
      "Sentry [issue](https://example.sentry.io/issues/1234567890/)",
      "Notion [page](https://www.notion.so/foo(bar))",
    ].join("\n"))).toEqual([
      { kind: "github", title: "#123", url: "https://github.com/creatrip/picky/pull/123" },
      { kind: "slack", title: "Slack", url: "https://example.slack.com/archives/C012ZMHLPDW/p1777763920621249" },
      { kind: "sentry", title: "Sentry", url: "https://example.sentry.io/issues/1234567890/" },
      { kind: "notion", title: "Notion", url: "https://www.notion.so/foo(bar)" },
    ]);
  });

  it("keeps URL-safe punctuation that can appear inside link paths", () => {
    expect(extractSessionLinks([
      "Notion https://www.notion.so/foo(bar)",
      "Docs https://docs.google.com/document/d/abc'def/edit",
      "Notion https://www.notion.so/foo`bar",
    ].join("\n"))).toEqual([
      { kind: "notion", title: "Notion", url: "https://www.notion.so/foo(bar)" },
      { kind: "googleDocs", title: "Docs", url: "https://docs.google.com/document/d/abc'def/edit" },
      { kind: "notion", title: "Notion", url: "https://www.notion.so/foo%60bar" },
    ]);
  });
});
