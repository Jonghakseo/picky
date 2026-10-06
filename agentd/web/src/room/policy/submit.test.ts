import { describe, expect, it } from "vitest";

import { SingleFlightSubmitter, draftAfterFailedSend } from "./submit";

function deferred(): { promise: Promise<boolean>; resolve: (ok: boolean) => void } {
  let resolve: (ok: boolean) => void = () => {};
  const promise = new Promise<boolean>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe("composer single-flight send", () => {
  it("sends once when Return is pressed repeatedly while the Mac has not answered", async () => {
    const sent: string[] = [];
    const reply = deferred();
    let draft = "검증해봐";
    const submitter = new SingleFlightSubmitter();
    const press = () =>
      submitter.run({
        take: () => {
          if (draft.length === 0) return null;
          const text = draft;
          draft = "";
          return text;
        },
        send: (text) => {
          sent.push(text);
          return reply.promise;
        },
      });

    const first = press();
    // The composer's closure may still hold the old draft before it re-renders.
    draft = "검증해봐";
    const repeats = await Promise.all([press(), press(), press(), press(), press()]);
    reply.resolve(true);

    expect(await first).toBe("sent");
    expect(repeats).toEqual(["busy", "busy", "busy", "busy", "busy"]);
    expect(sent).toEqual(["검증해봐"]);
  });

  it("accepts the next send once the previous one settles", async () => {
    const submitter = new SingleFlightSubmitter();
    const sent: string[] = [];
    const attempt = (text: string) => ({ take: () => text, send: async (value: string) => (sent.push(value), true) });

    await submitter.run(attempt("하나"));
    await submitter.run(attempt("둘"));

    expect(sent).toEqual(["하나", "둘"]);
  });

  it("gives the draft back when the send fails, and reports busy only while waiting", async () => {
    const busy: boolean[] = [];
    const submitter = new SingleFlightSubmitter((value) => busy.push(value));
    let restored: string | null = null;

    const outcome = await submitter.run({
      take: () => "보낼 말",
      send: async () => {
        throw new Error("socket closed");
      },
      onSuccess: () => {
        restored = "unexpected";
      },
      onFailure: (text) => {
        restored = text;
      },
    });

    expect(outcome).toBe("failed");
    expect(restored).toBe("보낼 말");
    expect(busy).toEqual([true, false]);
    expect(submitter.busy).toBe(false);
  });

  it("does not send an empty composer", async () => {
    const submitter = new SingleFlightSubmitter();
    let calls = 0;
    const outcome = await submitter.run({ take: () => null, send: async () => (calls += 1, true) });
    expect(outcome).toBe("empty");
    expect(calls).toBe(0);
  });
});

describe("draft after a failed send", () => {
  it("restores the sent text into an empty composer", () => {
    expect(draftAfterFailedSend("", "보낸 말")).toBe("보낸 말");
    expect(draftAfterFailedSend("  ", "보낸 말")).toBe("보낸 말");
  });

  it("keeps text typed while waiting below the sent text", () => {
    expect(draftAfterFailedSend("새로 쓴 말", "보낸 말")).toBe("보낸 말\n새로 쓴 말");
  });
});
