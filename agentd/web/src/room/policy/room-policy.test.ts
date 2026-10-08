import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { parseDiffResult, diffLineKind, changeCounts } from "./diff";
import { classifyLink } from "./links";
import { setLocale } from "../i18n";
import { activityCompletionText, isTruncated, truncatedMarkdown } from "./message";
import { delayMilliseconds, tomorrowPreset, TOMORROW_PRESET_HOUR } from "./schedule";
import { stopAlertActions, stopChoice } from "./stop";

describe("stop choice", () => {
  it("stops immediately when nothing runs in the background", () => {
    expect(stopChoice(0, "responding")).toBe("immediate");
  });

  it("asks what to stop while background work runs, and offers only the background when idle", () => {
    expect(stopChoice(2, "responding")).toBe("responseOrAll");
    expect(stopChoice(2, "idle")).toBe("backgroundOnly");
  });

  it("gives the response/all choice two stop actions plus cancel", () => {
    const actions = stopAlertActions("responseOrAll");
    expect(actions.flatMap((action) => (action.scope ? [action.scope] : []))).toEqual([
      "response",
      "all",
    ]);
    expect(actions.some((action) => action.role === "cancel")).toBe(true);
  });
});

describe("long message fold", () => {
  it("folds past 8 lines or 500 characters and leaves shorter text alone", () => {
    const nineLines = Array.from({ length: 9 }, (_, index) => `줄 ${index + 1}`).join("\n");
    expect(isTruncated(nineLines)).toBe(true);
    expect(truncatedMarkdown(nineLines).split("\n")).toHaveLength(8);
    expect(truncatedMarkdown(nineLines).endsWith("...")).toBe(true);

    const long = "가".repeat(501);
    expect(isTruncated(long)).toBe(true);
    expect([...truncatedMarkdown(long)].length).toBe(503);

    const short = "짧은 답\n두 줄";
    expect(isTruncated(short)).toBe(false);
    expect(truncatedMarkdown(short)).toBe(short);
  });
});

/** The duration strings, read from the Mac catalog so both surfaces share wording. */
function installDurationStrings(): void {
  const catalog = JSON.parse(readFileSync(new URL("../../../../../Picky/Resources/Localizable.xcstrings", import.meta.url), "utf8")) as {
    strings: Record<string, { localizations: Record<string, { stringUnit: { value: string } }> }>;
  };
  const tables: Record<string, Record<string, string>> = { ko: {}, en: {} };
  for (const key of [
    "hud.activity.summary.completedAfter",
    "hud.activity.summary.completedInstantly",
    "hud.activity.summary.duration.seconds",
    "hud.activity.summary.duration.minutes",
    "hud.activity.summary.duration.hours",
  ]) {
    for (const locale of ["ko", "en"]) {
      const value = catalog.strings[key]?.localizations[locale]?.stringUnit.value;
      if (value) tables[locale]![key] = value;
    }
  }
  (globalThis as { __STRINGS__?: unknown }).__STRINGS__ = tables;
}

describe("completed turn duration", () => {
  it('reads "instantly" up to 5 seconds, then the duration without zero parts', () => {
    installDurationStrings();
    setLocale("ko");
    expect(activityCompletionText(0)).toBe("즉시 완료");
    expect(activityCompletionText(5.9)).toBe("즉시 완료");
    expect(activityCompletionText(6)).toBe("6초 동안 완료");
    expect(activityCompletionText(59)).toBe("59초 동안 완료");
    expect(activityCompletionText(60)).toBe("1분 동안 완료");
    expect(activityCompletionText(125)).toBe("2분 5초 동안 완료");
    expect(activityCompletionText(1140)).toBe("19분 동안 완료");
    expect(activityCompletionText(3600)).toBe("1시간 동안 완료");
    expect(activityCompletionText(3605)).toBe("1시간 5초 동안 완료");
    expect(activityCompletionText(3725)).toBe("1시간 2분 5초 동안 완료");
    setLocale("en");
    expect(activityCompletionText(125)).toBe("Completed in 2m 5s");
    setLocale("ko");
  });
});

describe("link classification", () => {
  it("opens http(s) outside and local paths in the file preview", () => {
    expect(classifyLink("https://picky.app/docs")).toEqual({ kind: "external", url: "https://picky.app/docs" });
    expect(classifyLink("/Users/you/Pickles/picky/README.md")).toEqual({
      kind: "file",
      path: "/Users/you/Pickles/picky/README.md",
    });
    expect(classifyLink("docs/remote-pwa-plan.md")).toEqual({ kind: "file", path: "docs/remote-pwa-plan.md" });
  });

  it("refuses to act on other schemes and anchors", () => {
    expect(classifyLink("javascript:alert(1)")).toEqual({ kind: "plain" });
    expect(classifyLink("mailto:someone@example.com")).toEqual({ kind: "plain" });
    expect(classifyLink("#section")).toEqual({ kind: "plain" });
    expect(classifyLink("//evil.example.com")).toEqual({ kind: "plain" });
  });
});

describe("send timing", () => {
  it("has no delay for the rows that do not schedule", () => {
    const now = Date.parse("2026-10-05T14:00:00+09:00");
    expect(delayMilliseconds({ kind: "afterCurrentReply" }, now)).toBeNull();
    expect(delayMilliseconds({ kind: "custom" }, now)).toBeNull();
  });

  it("measures a preset delay from now and never schedules an absolute time in the past", () => {
    const now = Date.parse("2026-10-05T14:00:00+09:00");
    expect(delayMilliseconds({ kind: "delay", seconds: 300 }, now)).toBe(300_000);
    expect(delayMilliseconds({ kind: "at", at: now - 60_000 }, now)).toBe(1000);
  });

  it("puts the tomorrow preset at 9:00 local, even a minute after midnight", () => {
    const justAfterMidnight = new Date(2026, 9, 5, 0, 1, 0).getTime();
    const target = new Date(tomorrowPreset(justAfterMidnight));
    expect(target.getHours()).toBe(TOMORROW_PRESET_HOUR);
    expect(target.getMinutes()).toBe(0);
    expect(target.getDate()).toBe(6);
    expect(tomorrowPreset(justAfterMidnight) - justAfterMidnight).toBeGreaterThan(0);
  });
});

describe("diff payload", () => {
  it("keeps the files a daemon answered and drops entries without a path", () => {
    const parsed = parseDiffResult({
      isGitRepo: true,
      filesTruncated: true,
      files: [
        { path: "a.ts", status: "modified", additions: 4, deletions: 1, diff: "@@\n+a\n-b\n", truncated: false },
        { status: "modified" },
      ],
    });
    expect(parsed.files.map((file) => file.path)).toEqual(["a.ts"]);
    expect(parsed.filesTruncated).toBe(true);
  });

  it("survives a payload with nothing in it", () => {
    const parsed = parseDiffResult(undefined);
    expect(parsed.files).toEqual([]);
    expect(parsed.isGitRepo).toBe(true);
  });

  it("colors added and removed lines but not the hunk headers", () => {
    expect(diffLineKind("+added")).toBe("add");
    expect(diffLineKind("-removed")).toBe("remove");
    expect(diffLineKind("--- a/file.ts")).toBe("meta");
    expect(diffLineKind("+++ b/file.ts")).toBe("meta");
    expect(diffLineKind("@@ -1 +1 @@")).toBe("meta");
    expect(diffLineKind(" unchanged")).toBe("context");
    expect(changeCounts(4, 1)).toBe("+4 -1");
  });
});
