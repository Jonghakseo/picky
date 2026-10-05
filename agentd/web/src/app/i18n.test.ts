import { describe, expect, it } from "vitest";
import { createTranslator, formatString, resolveLocale } from "./i18n";

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
