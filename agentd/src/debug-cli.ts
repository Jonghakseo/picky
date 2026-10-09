import { Command, InvalidArgumentError } from "commander";
import { setTimeout as delay } from "node:timers/promises";
import { loadCliConnection, PickyCliDaemonNotRunningError } from "./cli/connection-loader.js";
import { DebugClient } from "./cli/debug-client.js";
import { debugTimeline, filterDebugTrace, type DebugTraceFilter } from "./cli/debug-timeline.js";
import { PickyCliConnectionError, PickyCliServerError, PickyCliTimeoutError } from "./cli/ws-client.js";

function integer(min: number, max: number) {
  return (value: string) => {
    const parsed = Number(value);
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
      throw new InvalidArgumentError(`Use an integer between ${min} and ${max}.`);
    }
    return parsed;
  };
}

const program = new Command()
  .exitOverride()
  .name("picky-debug")
  .description("Inspect live Picky input state and correlated audio/text transitions. JSON output; no transcripts or audio in traces.")
  .version("0.1.0")
  .option("--timeout <ms>", "Response timeout; a timeout does not undo a control", integer(100, 120_000), 20_000)
  .addHelpText("after", `
Examples:
  picky-debug state
  picky-debug watch --duration 30 > trace.jsonl
  picky-debug text "Reply briefly" --execute
  picky-debug ptt press --execute
  picky-debug ptt release --execute
  picky-debug timeline --input <input-id>

Controls use the app's normal input path and may capture desktop context, use
configured STT/model providers, or play speech. PTT uses the real microphone,
not an audio file. Do not retry an unconfirmed control automatically.
Observation does not capture context, change selection, or start an input.
The app and daemon must include debugControl support. No automatic app restart.
PICKY_APP_SUPPORT_DIR selects the directory containing agentd-connection.json.
Exit codes: 0 success, 1 daemon error, 2 disconnected, 3 timeout, 64 invalid usage.
`);

async function withClient(action: (client: DebugClient, timeout: number) => Promise<void>): Promise<void> {
  const timeout = program.opts<{ timeout: number }>().timeout;
  const client = await DebugClient.connect(await loadCliConnection(), timeout);
  try { await action(client, timeout); } finally { client.close(); }
}

function output(value: unknown): void { process.stdout.write(`${JSON.stringify(value)}\n`); }

program.command("state")
  .description("Read the current app snapshot without changing input, selection, or permissions")
  .action(async () => withClient(async (client, timeout) => {
    output(await client.request({ type: "debugApp", action: "snapshot" }, "debugAppResult", timeout));
  }));

interface TraceOptions extends DebugTraceFilter { after: number; limit: number }
function traceOptions(command: Command): Command {
  return command
    .option("--after <sequence>", "Exclusive daemon cursor (only valid for the same daemon instance)", integer(0, Number.MAX_SAFE_INTEGER), 0)
    .option("--limit <count>", "Maximum records per page", integer(1, 500), 200)
    .option("--input <id>", "Filter input ID")
    .option("--context <id>", "Filter context ID")
    .option("--session <id>", "Filter session ID")
    .option("--command <id>", "Filter debug command ID");
}

traceOptions(program.command("trace").description("Read one bounded page; filters do not change the returned continuation cursor"))
  .action(async (options: TraceOptions) => withClient(async (client, timeout) => {
    const page = await client.request({ type: "readDebugTrace", afterSequence: options.after, limit: options.limit }, "debugTrace", timeout);
    output({ ...page, records: filterDebugTrace(page.records, options) });
  }));

traceOptions(program.command("timeline").description("Read retained history and measure per-source durations using explicit ID links"))
  .action(async (options: TraceOptions) => withClient(async (client, timeout) => {
    const first = await client.request({ type: "readDebugTrace", afterSequence: options.after, limit: options.limit }, "debugTrace", timeout);
    const records = [...first.records];
    let page = first;
    // A bounded snapshot, not an endless catch-up when events arrive continuously.
    for (let count = 1; page.records.length === options.limit && count < 10; count += 1) {
      page = await client.request({ type: "readDebugTrace", afterSequence: page.nextSequence, limit: options.limit }, "debugTrace", timeout);
      if (page.instanceId !== first.instanceId) throw new PickyCliConnectionError("Daemon changed during timeline capture; capture again.");
      records.push(...page.records);
      if (page.truncated) first.truncated = true;
    }
    output({ ...first, nextSequence: page.nextSequence, captureLimitReached: page.records.length === options.limit,
      timing: "Durations use each source clock separately; receipt order is not cross-process causal order.",
      records: debugTimeline(records, options) });
  }));

traceOptions(program.command("watch").description("Stream bounded trace pages as JSONL, stopping on disconnect without replaying controls"))
  .option("--duration <seconds>", "Stop after this duration (0 waits for Ctrl-C)", integer(0, 86400), 0)
  .option("--interval <ms>", "Polling interval on the existing connection", integer(50, 60_000), 250)
  .action(async (options: TraceOptions & { duration: number; interval: number }) => withClient(async (client, timeout) => {
    const abort = new AbortController();
    const stop = () => { abort.abort(); client.close(); };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    const timer = options.duration > 0 ? setTimeout(stop, options.duration * 1000) : undefined;
    let after = options.after;
    let instance: string | undefined;
    try {
      while (!abort.signal.aborted) {
        const page = await client.request({ type: "readDebugTrace", afterSequence: after, limit: options.limit }, "debugTrace", timeout);
        if (instance && instance !== page.instanceId) throw new PickyCliConnectionError("Daemon instance changed; start a new watch with cursor 0.");
        if (!instance || page.records.length || page.truncated) output({ ...page, records: filterDebugTrace(page.records, options) });
        instance = page.instanceId;
        after = page.nextSequence;
        await delay(options.interval, undefined, { signal: abort.signal });
      }
    } catch (error) {
      if (!abort.signal.aborted) throw error;
    } finally {
      clearTimeout(timer);
      process.off("SIGINT", stop);
      process.off("SIGTERM", stop);
    }
  }));

function requireExecution(execute: boolean | undefined): void {
  if (!execute) {
    const error = new Error("This command changes the running app. Add --execute to send it.");
    Object.assign(error, { exitCode: 64 });
    throw error;
  }
}

program.command("text <text>")
  .description("Submit text through the app input pipeline (may capture desktop context and call the model)")
  .option("--execute", "Confirm sending this input to the running app")
  .action(async (text: string, options: { execute?: boolean }) => {
    requireExecution(options.execute);
    if (!text.trim() || text.length > 32000) throw Object.assign(new Error("Text must contain 1 to 32000 characters."), { exitCode: 64 });
    await withClient(async (client, timeout) => {
      output(await client.request({ type: "debugApp", action: "text", text }, "debugAppResult", timeout));
    });
  });

program.command("ptt <action>")
  .description("Press or release real microphone push-to-talk; release explicitly after press")
  .option("--execute", "Confirm changing microphone input state")
  .action(async (action: string, options: { execute?: boolean }) => {
    requireExecution(options.execute);
    if (action !== "press" && action !== "release") throw Object.assign(new Error("PTT action must be press or release."), { exitCode: 64 });
    await withClient(async (client, timeout) => {
      output(await client.request({ type: "debugApp", action: action === "press" ? "pttPress" : "pttRelease" }, "debugAppResult", timeout));
    });
  });

try {
  await program.parseAsync(process.argv);
} catch (error) {
  const failure = error as Error & { code?: string; exitCode?: number };
  if (failure.code === "commander.helpDisplayed" || failure.code === "commander.version") process.exitCode = 0;
  else {
    if (!failure.code?.startsWith("commander.")) process.stderr.write(`${JSON.stringify({ type: "debugError", code: failure.code ?? "debug_failed", message: failure.message })}\n`);
    process.exitCode = error instanceof PickyCliDaemonNotRunningError || error instanceof PickyCliConnectionError ? 2
      : error instanceof PickyCliTimeoutError ? 3
      : error instanceof PickyCliServerError ? 1
      : failure.code?.startsWith("commander.") ? 64 : failure.exitCode ?? 1;
  }
}
