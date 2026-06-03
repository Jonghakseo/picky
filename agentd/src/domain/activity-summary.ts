import type { PickyActivitySummary } from "../protocol.js";

export function zeroActivitySummary(): PickyActivitySummary {
  return { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 };
}

export function activityTotal(summary: PickyActivitySummary): number {
  return summary.read + summary.bash + summary.edit + summary.write + summary.thinking + summary.other;
}

export function hasActivity(summary: PickyActivitySummary): boolean {
  return activityTotal(summary) > 0;
}
