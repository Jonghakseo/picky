import type { InlineExtension } from "@earendil-works/pi-coding-agent";
import { applyFastModeToPayload, isFastModeSupported } from "../domain/fast-mode-policy.js";
import { logAgentd } from "../local-log.js";
import type { RuntimeFastModeState } from "./types.js";

export const PICKY_FAST_MODE_EXTENSION_NAME = "picky-fast-mode";

/**
 * Per-session switch for provider fast mode. One instance belongs to one runtime
 * handle (created in `PiSdkRuntime.createHandle`), so a Pickle's toggle can never
 * reach another Pickle's requests even when they share a daemon.
 *
 * The flag is read on every provider request, so a toggle applies from the next
 * request, including tool continuations of an in-flight turn.
 */
export class PickyFastModeSwitch {
  private enabled = false;

  setEnabled(enabled: boolean, sessionId: string): void {
    this.enabled = enabled;
    logAgentd("pi fast mode set", { sessionId, enabled: enabled ? 1 : 0 });
  }

  /** `model` is the session's current model as read by the Pi capability adapter. */
  state(model: { provider?: string; modelId?: string } | undefined): RuntimeFastModeState {
    const supported = model?.provider !== undefined && model.modelId !== undefined
      && isFastModeSupported({ provider: model.provider, id: model.modelId });
    return { enabled: this.enabled, supported };
  }

  get extension(): InlineExtension {
    return {
      name: PICKY_FAST_MODE_EXTENSION_NAME,
      hidden: true,
      factory: (pi) => {
        pi.on("before_provider_request", (event, ctx) => (
          this.enabled ? applyFastModeToPayload(event.payload, ctx.model) : undefined
        ));
      },
    };
  }
}
