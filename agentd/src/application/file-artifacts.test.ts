import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { fileArtifactFromWrite, isFileArtifactPath, strictlyMonotonicUpdatedAt } from "./file-artifacts.js";

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

  it("keeps markdown written to temporary directories as an artifact", () => {
    expect(isFileArtifactPath("/tmp/handoff-image-cdn-longtail.md", ["/tmp"])).toBe(true);
    expect(isFileArtifactPath("/workspace/tmp/notes.markdown")).toBe(true);
    expect(fileArtifactFromWrite({ filePath: join(tmpdir(), "handoff.md"), now: "2026-08-15T10:00:00.000Z" })).toMatchObject({ kind: "file", title: "handoff.md" });
    expect(isFileArtifactPath("/tmp/node_modules/readme.md", ["/tmp"])).toBe(false);
    expect(isFileArtifactPath("/tmp/.cache/report.md", ["/tmp"])).toBe(false);
  });

  it("excludes both lexical macOS aliases for the system temporary directory", () => {
    const temporaryDirectory = tmpdir();
    const alias = temporaryDirectory.startsWith("/private/var/")
      ? temporaryDirectory.slice("/private".length)
      : temporaryDirectory.startsWith("/var/")
        ? `/private${temporaryDirectory}`
        : temporaryDirectory;

    expect(fileArtifactFromWrite({ filePath: join(temporaryDirectory, "transient-report.pdf"), now: "2026-08-15T10:00:00.000Z" })).toBeUndefined();
    expect(fileArtifactFromWrite({ filePath: join(alias, "transient-report.pdf"), now: "2026-08-15T10:00:00.000Z" })).toBeUndefined();
  });

  it("increments existing timestamps when the clock repeats or moves backward", () => {
    const existing = "2026-08-15T10:00:00.000Z";
    expect(strictlyMonotonicUpdatedAt(existing, existing)).toBe("2026-08-15T10:00:00.001Z");
    expect(strictlyMonotonicUpdatedAt("2026-08-15T09:59:59.000Z", existing)).toBe("2026-08-15T10:00:00.001Z");
    expect(strictlyMonotonicUpdatedAt("2026-08-15T10:00:01.000Z", existing)).toBe("2026-08-15T10:00:01.000Z");
  });
});
