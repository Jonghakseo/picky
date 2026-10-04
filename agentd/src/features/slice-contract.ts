import type { EventEnvelope, parseCommand } from "../protocol.js";

/**
 * The seam every feature slice plugs into.
 *
 * A slice owns `schema.ts` (its wire commands/events) and `handlers.ts` (a
 * `(ctx) => CommandHandlersFor<...>` factory). `server.ts` merges the factories
 * into one registry annotated with `CommandHandlerMap`, so a command without a
 * handler stays a compile error.
 *
 * These are type-only declarations; importing them never creates a module cycle
 * with `protocol.ts` or `server.ts`.
 */
export type ParsedCommand = ReturnType<typeof parseCommand>;

export type CommandHandlerMap = {
  [Type in ParsedCommand["type"]]: (command: Extract<ParsedCommand, { type: Type }>) => unknown;
};

/** The part of the registry a single slice owns. */
export type CommandHandlersFor<Type extends ParsedCommand["type"]> = Pick<CommandHandlerMap, Type>;

type RemoveEnvelope<T> = T extends unknown ? Omit<T, "id" | "protocolVersion" | "timestamp"> : never;

/** An event without the envelope fields the transport stamps on. */
export type EventPayload = RemoveEnvelope<EventEnvelope>;
