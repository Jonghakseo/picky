import { describe, expect, it } from "vitest";
import {
  NPM_COMMAND_FORCE_KILL_GRACE_MS,
  PACKAGE_PROCESS_FORCE_KILL_GRACE_MS,
  PARENT_EXIT_FORCE_SHUTDOWN_MS,
} from "./shutdown-policy.js";

describe("daemon shutdown policy", () => {
  it("gives each nested process owner time to reap before its parent exits", () => {
    expect(NPM_COMMAND_FORCE_KILL_GRACE_MS).toBeLessThan(PACKAGE_PROCESS_FORCE_KILL_GRACE_MS);
    expect(PACKAGE_PROCESS_FORCE_KILL_GRACE_MS).toBeLessThan(PARENT_EXIT_FORCE_SHUTDOWN_MS);
  });
});
