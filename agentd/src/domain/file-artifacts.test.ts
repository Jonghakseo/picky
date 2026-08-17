import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { extractFileArtifactsFromAnswerText, fileArtifactFromWrite, isFileArtifactPath, normalizeFileArtifactPath } from "./file-artifacts.js";

describe("file artifacts", () => {
  it("creates a deterministic file artifact only for allowed non-source files", () => {
    const input = { filePath: "/workspace/reports/summary.md", fileExistedBefore: false, now: "2026-08-15T10:00:00.000Z" };

    expect(fileArtifactFromWrite(input)).toEqual({
      id: "file-04c0406d001b",
      kind: "file",
      title: "summary.md",
      path: "/workspace/reports/summary.md",
      updatedAt: input.now,
    });
    expect(fileArtifactFromWrite({ ...input, fileExistedBefore: true })).toMatchObject({ id: "file-04c0406d001b" });
    expect(fileArtifactFromWrite({ ...input, filePath: "/workspace/src/main.ts" })).toBeUndefined();
  });

  it("excludes hidden, dependency, build, temporary, and extension-less paths", () => {
    expect(isFileArtifactPath("/workspace/.cache/report.md")).toBe(false);
    expect(isFileArtifactPath("/workspace/node_modules/package/readme.md")).toBe(false);
    expect(isFileArtifactPath("/workspace/build/report.pdf")).toBe(false);
    expect(isFileArtifactPath("/workspace/dist/chart.png")).toBe(false);
    expect(isFileArtifactPath("/workspace/out/export.csv")).toBe(false);
    expect(isFileArtifactPath("/workspace/tmp/export.csv")).toBe(false);
    expect(isFileArtifactPath("/workspace/temp/export.csv")).toBe(false);
    expect(isFileArtifactPath("/private/picky-temporary/export.csv", ["/private/picky-temporary"])).toBe(false);
    expect(isFileArtifactPath("/workspace/report")).toBe(false);
    expect(isFileArtifactPath("/workspace/report.pdf")).toBe(true);
  });

  it("excludes temporary files from write capture and answer-text extraction", () => {
    const now = "2026-08-15T10:00:00.000Z";
    const systemTemporaryFile = join(tmpdir(), "transient-report.pdf");

    expect(fileArtifactFromWrite({ filePath: "/workspace/tmp/export.csv", now })).toBeUndefined();
    expect(fileArtifactFromWrite({ filePath: systemTemporaryFile, now })).toBeUndefined();
    expect(extractFileArtifactsFromAnswerText(
      `Created tmp/export.csv and ${systemTemporaryFile}.`,
      "/workspace",
      () => true,
    )).toEqual([]);
  });

  it("normalizes relative and home paths before checking answer artifacts", () => {
    expect(normalizeFileArtifactPath("reports/요약 파일.md", "/workspace/project")).toBe("/workspace/project/reports/요약 파일.md");
    expect(normalizeFileArtifactPath("~/Desktop/report.pdf", "/workspace/project")).toBe(join(homedir(), "Desktop/report.pdf"));
  });

  it("extracts existing explicit local file paths from answer text without URLs or duplicates", () => {
    const cwd = "/workspace/project";
    const relative = join(cwd, "reports/summary.md");
    const homePath = join(homedir(), "Desktop/chart.png");
    const existing = new Set([relative, homePath]);

    const artifacts = extractFileArtifactsFromAnswerText([
      "Created `reports/summary.md`.",
      "Saved ~/Desktop/chart.png.",
      "Created reports/summary.md again.",
      "See https://example.com/reports/ignored.pdf.",
      "Created missing.pdf.",
    ].join("\n"), cwd, (path) => existing.has(path));

    expect(artifacts).toHaveLength(2);
    expect(artifacts.map((artifact) => artifact.path)).toEqual([relative, homePath]);
    expect(artifacts.map((artifact) => artifact.title)).toEqual(["summary.md", "chart.png"]);
  });
});
