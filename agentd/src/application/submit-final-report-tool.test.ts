import { describe, expect, it } from "vitest";
import type { PickyFinalReport } from "../protocol.js";
import { createPickySubmitFinalReportTool } from "./submit-final-report-tool.js";

describe("submit_final_report tool", () => {
  it("defines the required final report schema fields", () => {
    const tool = createPickySubmitFinalReportTool(async () => {});
    const parameters = tool.parameters as { required?: string[]; properties?: Record<string, unknown> };

    expect(tool.name).toBe("submit_final_report");
    expect(parameters.required).toEqual(expect.arrayContaining(["summary", "body", "status"]));
    expect(parameters.properties).toHaveProperty("artifacts");
  });

  it("normalizes optional artifacts and returns an acknowledgement", async () => {
    let received: PickyFinalReport | undefined;
    const tool = createPickySubmitFinalReportTool(async (report) => {
      received = report;
    });

    const result = await tool.execute(
      "tool-1",
      { summary: "Done", body: "## Completed\n- work", status: "success" } as never,
      undefined,
      undefined,
      {} as never,
    );

    expect(received).toEqual({ summary: "Done", body: "## Completed\n- work", status: "success", artifacts: [] });
    expect(result.content[0]).toEqual({ type: "text", text: "Final report recorded." });
    expect(result.details).toEqual({ report: received });
  });

  it("passes artifact metadata through unchanged", async () => {
    let received: PickyFinalReport | undefined;
    const tool = createPickySubmitFinalReportTool(async (report) => {
      received = report;
    });

    await tool.execute(
      "tool-1",
      { summary: "Blocked", body: "Needs access", status: "blocked", artifacts: [{ kind: "url", title: "Issue", url: "https://example.com/issue" }] } as never,
      undefined,
      undefined,
      {} as never,
    );

    expect(received?.artifacts).toEqual([{ kind: "url", title: "Issue", url: "https://example.com/issue" }]);
  });
});
