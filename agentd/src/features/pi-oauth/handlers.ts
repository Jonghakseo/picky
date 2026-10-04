import type { WebSocket } from "ws";
import { logAgentd } from "../../local-log.js";
import type { CommandHandlersFor, EventPayload } from "../slice-contract.js";
import type { PiOAuthProviderId, PiOAuthPromptOption } from "./schema.js";

export type PiOAuthCommandType =
  | "getPiOAuthStatus"
  | "signInPiOAuth"
  | "signOutPiOAuth"
  | "answerPiOAuthPrompt"
  | "cancelPiOAuth"
  | "reloadPiAuthentication";

export interface PiOAuthStatusResult {
  configured: boolean;
  source?: string;
  label?: string;
}

/** Login progress this slice renders. Other kinds are logged and not forwarded. */
export type PiOAuthNotification =
  | { type: "auth_url"; url: string; instructions?: string }
  | { type: "device_code"; userCode: string; verificationUri: string }
  | { type: "info" | "progress"; message: string };

/** A step the provider needs the user to answer. Mirrors the Pi SDK auth prompt. */
export type PiOAuthPrompt =
  | { type: "text" | "secret" | "manual_code"; message: string; placeholder?: string }
  | { type: "select"; message: string; options: readonly PiOAuthPromptOption[] };

/**
 * The provider authentication work this slice delegates. Implemented by
 * `runtime/pi-oauth-service.ts`, which owns the Pi SDK credential store.
 */
export interface PiOAuthPort {
  status(providerId: string): Promise<PiOAuthStatusResult>;
  login(request: {
    requestId: string;
    providerId: string;
    owner: object;
    onNotify(event: PiOAuthNotification): void;
    onPrompt(promptId: string, prompt: PiOAuthPrompt): void;
  }): Promise<PiOAuthStatusResult>;
  logout(providerId: string): Promise<PiOAuthStatusResult>;
  answerPrompt(answer: { owner: object; requestId: string; promptId: string; value?: string; cancelled?: boolean }): void;
  cancel(owner: object, requestId: string): boolean;
}

export interface PiOAuthFeatureContext {
  socket: WebSocket;
  /** Throws on a child daemon, which has no OAuth coordinator. */
  requirePiOAuth: () => PiOAuthPort;
  /** Narrow supervisor port: refreshes credentials on live runtime handles. */
  reloadAuthentication: () => Promise<number>;
  send: (socket: WebSocket, event: EventPayload) => void;
}

export function piOAuthCommandHandlers(ctx: PiOAuthFeatureContext): CommandHandlersFor<PiOAuthCommandType> {
  const sendStatus = (requestId: string, providerId: PiOAuthProviderId, status: PiOAuthStatusResult) => {
    ctx.send(ctx.socket, { type: "piOAuthStatus", requestId, providerId, ...status });
  };
  return {
    getPiOAuthStatus: async (command) => {
      sendStatus(command.id, command.providerId, await ctx.requirePiOAuth().status(command.providerId));
    },
    signInPiOAuth: async (command) => {
      const status = await ctx.requirePiOAuth().login({
        requestId: command.id,
        providerId: command.providerId,
        owner: ctx.socket,
        onNotify: (event) => {
          if (event.type === "auth_url") {
            ctx.send(ctx.socket, {
              type: "piOAuthUrlRequested",
              requestId: command.id,
              providerId: command.providerId,
              url: event.url,
              instructions: event.instructions,
            });
          } else if (event.type === "device_code") {
            ctx.send(ctx.socket, {
              type: "piOAuthUrlRequested",
              requestId: command.id,
              providerId: command.providerId,
              url: event.verificationUri,
              userCode: event.userCode,
            });
          } else {
            logAgentd("pi oauth progress", { requestId: command.id, providerId: command.providerId, eventType: event.type });
          }
        },
        onPrompt: (promptId, prompt) => ctx.send(ctx.socket, {
          type: "piOAuthPromptRequested",
          requestId: command.id,
          providerId: command.providerId,
          promptId,
          promptType: prompt.type,
          message: prompt.message,
          ...("placeholder" in prompt && prompt.placeholder ? { placeholder: prompt.placeholder } : {}),
          ...(prompt.type === "select" ? { options: [...prompt.options] } : {}),
        }),
      });
      sendStatus(command.id, command.providerId, status);
    },
    signOutPiOAuth: async (command) => {
      sendStatus(command.id, command.providerId, await ctx.requirePiOAuth().logout(command.providerId));
    },
    answerPiOAuthPrompt: (command) => ctx.requirePiOAuth().answerPrompt({
      owner: ctx.socket,
      requestId: command.requestId,
      promptId: command.promptId,
      value: command.value,
      cancelled: command.cancelled,
    }),
    cancelPiOAuth: (command) => { ctx.requirePiOAuth().cancel(ctx.socket, command.requestId); },
    reloadPiAuthentication: async (command) => {
      const reloadedHandleCount = await ctx.reloadAuthentication();
      ctx.send(ctx.socket, { type: "piAuthenticationReloaded", requestId: command.id, reloadedHandleCount });
    },
  };
}
