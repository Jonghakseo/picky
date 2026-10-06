import { describe, expect, it } from "vitest";
import { fileName, formatBytes, formatRoomTime, roomTimeStyle } from "./format";

const now = new Date("2026-10-05T14:21:00+09:00");

const labels = {
  justNow: "조금 전",
  minutes: (count: number) => `${count}분 전`,
  hours: (count: number) => `${count}시간 전`,
  yesterday: "어제",
};

describe("formatRoomTime", () => {
  it("says how long ago for the first day", () => {
    expect(formatRoomTime("2026-10-05T14:20:30+09:00", now, "ko", labels)).toBe("조금 전");
    expect(formatRoomTime("2026-10-05T14:09:00+09:00", now, "ko", labels)).toBe("12분 전");
    expect(formatRoomTime("2026-10-05T11:50:00+09:00", now, "ko", labels)).toBe("2시간 전");
    // Yesterday by the calendar but under a day ago: still hours.
    expect(formatRoomTime("2026-10-04T23:59:00+09:00", now, "ko", labels)).toBe("14시간 전");
  });

  it("treats a timestamp slightly ahead of the phone clock as just now", () => {
    expect(formatRoomTime("2026-10-05T14:22:00+09:00", now, "ko", labels)).toBe("조금 전");
  });

  it("falls back to yesterday, a weekday, then a date after a day", () => {
    expect(formatRoomTime("2026-10-04T09:00:00+09:00", now, "ko", labels)).toBe("어제");
    expect(roomTimeStyle(new Date("2026-10-01T10:00:00+09:00"), now).kind).toBe("weekday");
    expect(roomTimeStyle(new Date("2026-09-20T10:00:00+09:00"), now).kind).toBe("date");
  });

  it("renders nothing for a missing or broken timestamp", () => {
    expect(formatRoomTime(undefined, now, "ko", labels)).toBe("");
    expect(formatRoomTime("not a date", now, "ko", labels)).toBe("");
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
