/**
 * Command ids and the pending map.
 *
 * The gateway remembers the last 1000 command ids per device and returns the
 * first result for a repeat (docs/remote-pwa-implementation.md 2.7). So a
 * command that was in flight when the socket dropped is resent with the same
 * id: either it never ran, or the gateway answers from its memory. Changing the
 * id would send a second follow-up.
 */
import type { RemoteCommand, RemoteError } from "../../../src/remote/protocol";

export type CommandResult = { ok: true; data?: unknown } | { ok: false; error: RemoteError };

const ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";
const ID_BODY_LENGTH = 16;

export function newCommandId(random: () => number = Math.random): string {
  let id = "c_";
  for (let index = 0; index < ID_BODY_LENGTH; index += 1) {
    id += ID_ALPHABET[Math.floor(random() * ID_ALPHABET.length)] ?? "0";
  }
  return id;
}

interface PendingCommand {
  id: string;
  command: RemoteCommand;
  settle(result: CommandResult): void;
  timer?: ReturnType<typeof setTimeout>;
}

/** A command gets this long to produce a result, across reconnects. */
export const COMMAND_TIMEOUT_MS = 60_000;

export class CommandRegistry {
  private readonly pending = new Map<string, PendingCommand>();

  constructor(
    private readonly transmit: (id: string, command: RemoteCommand) => void,
    private readonly timeoutMs = COMMAND_TIMEOUT_MS,
  ) {}

  get pendingCount(): number {
    return this.pending.size;
  }

  send(command: RemoteCommand, id = newCommandId()): Promise<CommandResult> {
    return new Promise<CommandResult>((resolve) => {
      const entry: PendingCommand = {
        id,
        command,
        settle: (result) => {
          const held = this.pending.get(id);
          if (held?.timer) clearTimeout(held.timer);
          this.pending.delete(id);
          resolve(result);
        },
      };
      entry.timer = setTimeout(() => {
        entry.settle({ ok: false, error: { code: "timeout", message: "command timed out" } });
      }, this.timeoutMs);
      this.pending.set(id, entry);
      this.transmit(id, command);
    });
  }

  /** `command.result` arrived. Unknown ids are ignored (a duplicate result, or ours timed out). */
  resolve(id: string, result: CommandResult): void {
    this.pending.get(id)?.settle(result);
  }

  /** After a reconnect: resend everything still unresolved, keeping each id. */
  resend(): void {
    for (const entry of this.pending.values()) this.transmit(entry.id, entry.command);
  }

  /** The connection is gone for good (revoked device): nothing will answer. */
  failAll(error: RemoteError): void {
    for (const entry of [...this.pending.values()]) entry.settle({ ok: false, error });
  }
}
