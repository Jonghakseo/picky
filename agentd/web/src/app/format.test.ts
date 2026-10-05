import { describe, expect, it } from "vitest";
import { fileName, formatBytes, formatRoomTime, roomTimeStyle } from "./format";

const now = new Date("2026-10-05T14:21:00+09:00");

describe("roomTimeStyle", () => {
  it("shows a clock time for today", () => {
    expect(roomTimeStyle(new Date("2026-10-05T09:12:00+09:00"), now).kind).toBe("time");
  });

  it("says yesterday for yesterday, even a minute ago by the clock", () => {
    expect(roomTimeStyle(new Date("2026-10-04T23:59:00+09:00"), now).kind).toBe("yesterday");
  });

  it("uses a weekday inside the last week and a date beyond it", () => {
    expect(roomTimeStyle(new Date("2026-10-01T10:00:00+09:00"), now).kind).toBe("weekday");
    expect(roomTimeStyle(new Date("2026-09-20T10:00:00+09:00"), now).kind).toBe("date");
  });
});

describe("formatRoomTime", () => {
  it("renders the yesterday label the caller supplies", () => {
    expect(formatRoomTime("2026-10-04T18:00:00+09:00", now, "ko", "어제")).toBe("어제");
  });

  it("renders nothing for a missing or broken timestamp", () => {
    expect(formatRoomTime(undefined, now, "ko", "어제")).toBe("");
    expect(formatRoomTime("not a date", now, "ko", "어제")).toBe("");
  });
});

describe("formatBytes", () => {
  it("keeps sizes short", () => {
    expect(formatBytes(512, "en")).toBe("512 B");
    expect(formatBytes(2048, "en")).toBe("2 KB");
    expect(formatBytes(1_572_864, "en")).toBe("1.5 MB");
  });
});

describe("fileName", () => {
  it("takes the last path component", () => {
    expect(fileName("/Users/you/Pickles/picky/docs/plan.md")).toBe("plan.md");
    expect(fileName("/Users/you/Pickles/picky/")).toBe("picky");
    expect(fileName("plan.md")).toBe("plan.md");
  });
});
