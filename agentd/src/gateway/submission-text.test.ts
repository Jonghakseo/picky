/**
 * The text that reaches the daemon when the phone sends attachments. Port of
 * `PickyConversationComposerView.submissionText`, so the Mac composer and the
 * phone produce the same message for the same input.
 */
import { describe, expect, it } from "vitest";
import { appendAttachmentPaths, bashCommandIn, submissionTextWithAttachments } from "./submission-text.js";

describe("submission text with attachments", () => {
  it("puts each uploaded path on its own line after the draft", () => {
    expect(submissionTextWithAttachments("이 화면 좀 봐 줘", ["/tmp/a.png", "/tmp/b.png"]))
      .toBe("이 화면 좀 봐 줘\n/tmp/a.png\n/tmp/b.png");
  });

  it("sends only the paths when the draft is empty", () => {
    expect(submissionTextWithAttachments("   ", ["/tmp/a.png"])).toBe("/tmp/a.png");
  });

  it("leaves a draft without attachments untouched apart from trimming", () => {
    expect(submissionTextWithAttachments("  hello  ", [])).toBe("hello");
    expect(submissionTextWithAttachments("!ls", [])).toBe("!ls");
  });

  it("prefixes a space so an attached `!` draft never becomes a shell command", () => {
    // Without the leading space agentd would run `!중요` as a shell command with
    // the image paths as its arguments.
    expect(submissionTextWithAttachments("!중요", ["/tmp/a.png"])).toBe(" !중요\n/tmp/a.png");
    expect(submissionTextWithAttachments("!!ls", ["/tmp/a.png"])).toBe(" !!ls\n/tmp/a.png");
  });

  it("ignores blank upload paths", () => {
    expect(submissionTextWithAttachments("보고서", ["  ", "/tmp/a.png", ""])).toBe("보고서\n/tmp/a.png");
    // Parity with the Mac composer: the `!` guard keys off the attachment list
    // the user picked, not off how many paths survived trimming.
    expect(submissionTextWithAttachments("!ls", ["   "])).toBe(" !ls");
  });

  it("does not add a second newline when the draft already ends with one", () => {
    expect(appendAttachmentPaths("hello\n", ["/tmp/a.png"])).toBe("hello\n/tmp/a.png");
  });
});

describe("shell messages in the audit log", () => {
  it("reports the command behind `!` and `!!`", () => {
    expect(bashCommandIn("!git status")).toBe("git status");
    expect(bashCommandIn("!! rm -rf build")).toBe("rm -rf build");
    expect(bashCommandIn("  !ls -al  ")).toBe("ls -al");
  });

  it("reports nothing for ordinary messages or an empty shortcut", () => {
    expect(bashCommandIn("just a message")).toBeUndefined();
    expect(bashCommandIn("!")).toBeUndefined();
    expect(bashCommandIn("!!   ")).toBeUndefined();
    // The audit log is deliberately permissive: it still records the intent of a
    // draft the attachment rule disarmed with a leading space.
    expect(bashCommandIn(" !rm -rf build")).toBe("rm -rf build");
  });
});
