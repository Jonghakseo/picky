import { describe, expect, it } from "vitest";
import { parseLocation, routeHref, sameRoute } from "./router";

describe("parseLocation", () => {
  it("reads the room list", () => {
    expect(parseLocation("/").route).toEqual({ name: "rooms" });
  });

  it("reads a room id, including one with URL characters", () => {
    expect(parseLocation("/room/s-archive").route).toEqual({ name: "room", roomId: "s-archive" });
    expect(parseLocation("/room/main").route).toEqual({ name: "room", roomId: "main" });
    expect(parseLocation(`/room/${encodeURIComponent("s/with space")}`).route).toEqual({ name: "room", roomId: "s/with space" });
  });

  it("reads settings and pairing", () => {
    expect(parseLocation("/settings").route).toEqual({ name: "settings" });
    expect(parseLocation("/pair").route).toEqual({ name: "pair" });
  });

  it("reads a file preview with its room and path", () => {
    const location = parseLocation("/preview", "?room=s1&path=%2FUsers%2Fyou%2Fnotes.md");
    expect(location.route).toEqual({ name: "preview", roomId: "s1", path: "/Users/you/notes.md" });
  });

  it("falls back to the room list for a preview without a path and for unknown paths", () => {
    expect(parseLocation("/preview", "?room=s1").route).toEqual({ name: "rooms" });
    expect(parseLocation("/nope/at/all").route).toEqual({ name: "rooms" });
  });

  it("picks up a pairing code from the fragment on any route", () => {
    expect(parseLocation("/", "", "#pair=K4M9-TR2X").pairCode).toBe("K4M9-TR2X");
    expect(parseLocation("/room/s1", "", "#pair=K4M9TR2X").pairCode).toBe("K4M9TR2X");
    expect(parseLocation("/", "", "#other=1").pairCode).toBeUndefined();
  });
});

describe("routeHref", () => {
  it("round-trips every route", () => {
    for (const route of [
      { name: "rooms" },
      { name: "room", roomId: "s-archive" },
      { name: "settings" },
      { name: "pair" },
      { name: "preview", roomId: "s1", path: "/Users/you/notes.md" },
    ] as const) {
      const href = routeHref(route);
      const [pathname, search] = href.split("?");
      expect(parseLocation(pathname ?? "/", search ? `?${search}` : "").route).toEqual(route);
    }
  });

  it("tells screens apart", () => {
    expect(sameRoute({ name: "room", roomId: "a" }, { name: "room", roomId: "a" })).toBe(true);
    expect(sameRoute({ name: "room", roomId: "a" }, { name: "room", roomId: "b" })).toBe(false);
  });
});
