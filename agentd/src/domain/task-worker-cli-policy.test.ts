import { describe, expect, it } from "vitest";
import { taskWorkerCliRefusal } from "./task-worker-cli-policy.js";

describe("taskWorkerCliRefusal", () => {
  it("refuses delegation and control commands inside a Task worker", () => {
    for (const command of ["pickle-create", "pickle-steer", "pickle-followup", "submit", "ptt", "settings-set", "pickle-archive"]) {
      expect(taskWorkerCliRefusal(command, { PICKY_TASK_WORKER: "1" })).toMatch(/not available inside a Picky Task/);
    }
  });

  it("keeps read-only inspection available to the worker and leaves other callers alone", () => {
    expect(taskWorkerCliRefusal("pickle-list", { PICKY_TASK_WORKER: "1" })).toBeUndefined();
    expect(taskWorkerCliRefusal("whoami", { PICKY_TASK_WORKER: "1" })).toBeUndefined();
    expect(taskWorkerCliRefusal("pickle-create", {})).toBeUndefined();
  });
});
