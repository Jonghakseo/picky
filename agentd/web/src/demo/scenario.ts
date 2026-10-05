/**
 * `?demo=1&state=<name>`: the few screens that a demo session cannot reach by
 * tapping, because they depend on who this device is (not paired yet, on iOS
 * outside the Home Screen app) or on what the Mac sent (no Pickles, Mac
 * asleep). Review builds and the screenshot sweep use these; the real app
 * never reads them, because `state` only matters inside the `demo` branch.
 */
import type { PlatformFacts } from "../app/platform";
import type { AppStore } from "../app/store";
import type { DemoOptions } from "./demo-transport";

export type DemoScenario = "unpaired" | "install" | "revoked" | "offline" | "empty" | "ios";

const SCENARIOS = new Set<string>(["unpaired", "install", "revoked", "offline", "empty", "ios"]);

export function readScenario(value: string | null): DemoScenario | undefined {
  return value && SCENARIOS.has(value) ? (value as DemoScenario) : undefined;
}

/** What the fake Mac sends for this scenario. */
export function scenarioTransportOptions(scenario: DemoScenario | undefined): DemoOptions {
  return {
    macConnected: scenario !== "offline",
    noPickles: scenario === "empty",
  };
}

/** An iPhone in Safari: no Home Screen app, so pairing and push are both blocked. */
export function scenarioPlatform(scenario: DemoScenario | undefined, platform: PlatformFacts): PlatformFacts {
  if (scenario !== "install" && scenario !== "ios") return platform;
  return { ...platform, ios: true, standalone: false, deviceName: "iPhone" };
}

/** Where the shell starts: paired unless the scenario is about getting paired. */
export function scenarioPairing(scenario: DemoScenario | undefined): AppStore["pairing"]["value"] {
  if (scenario === "unpaired" || scenario === "install") return "unpaired";
  if (scenario === "revoked") return "revoked";
  return "paired";
}
