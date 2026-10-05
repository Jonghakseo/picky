import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
import { createTranslator, formatString, resolveLocale, type StringTables } from "./i18n";

describe("resolveLocale", () => {
  it("is ko for Korean browsers and en for the rest", () => {
    expect(resolveLocale("ko-KR")).toBe("ko");
    expect(resolveLocale("ko")).toBe("ko");
    expect(resolveLocale("en-US")).toBe("en");
    expect(resolveLocale("ja-JP")).toBe("en");
    expect(resolveLocale(undefined)).toBe("en");
  });
});

describe("formatString", () => {
  it("fills catalog specifiers in order", () => {
    expect(formatString("%@개 중 %lld개 완료", ["12", 4])).toBe("12개 중 4개 완료");
  });

  it("fills positional specifiers", () => {
    expect(formatString("%2$@를 %1$@에 보냈어요", ["Picky", "보고서"])).toBe("보고서를 Picky에 보냈어요");
  });

  it("keeps a literal percent", () => {
    expect(formatString("컨텍스트 %lld%% 사용", [24])).toBe("컨텍스트 24% 사용");
  });

  it("leaves a specifier without an argument visible", () => {
    expect(formatString("%@개 남음", [])).toBe("%@개 남음");
  });
});

describe("built PWA activity labels", () => {
  let tables: StringTables;

  beforeAll(() => {
    const output = mkdtempSync(join(tmpdir(), "picky-web-i18n-"));
    try {
      execFileSync(process.execPath, [fileURLToPath(new URL("../../build.mjs", import.meta.url)), "--out", output]);
      tables = JSON.parse(readFileSync(new URL("../../.generated/strings.json", import.meta.url), "utf8"));
    } finally {
      rmSync(output, { recursive: true, force: true });
    }
  });

  it.each([
    ["read", "읽기", "Read"],
    ["bash", "실행", "bash"],
    ["edit", "수정", "Edit"],
    ["write", "쓰기", "Write"],
    ["todo", "할 일", "Todo"],
    ["subagent", "서브에이전트", "Subagent"],
    ["other", "기타", "Other"],
  ])("translates %s from the shipped string tables in Korean and English", (category, korean, english) => {
    const key = `hud.activity.category.${category}`;
    expect(createTranslator(tables, "ko")(key)).toBe(korean);
    expect(createTranslator(tables, "en")(key)).toBe(english);
  });
});

describe("createTranslator", () => {
  const tables = { ko: { "hud.a": "실행 중" }, en: { "hud.a": "Running", "hud.b": "Only English" } };

  it("uses the requested locale", () => {
    expect(createTranslator(tables, "ko")("hud.a")).toBe("실행 중");
  });

  it("falls back to English, then to the key itself", () => {
    const t = createTranslator(tables, "ko");
    expect(t("hud.b")).toBe("Only English");
    expect(t("hud.missing")).toBe("hud.missing");
  });
});
