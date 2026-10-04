import type { WebSocket } from "ws";
import type { EventPayload } from "../slice-contract.js";
import type { PickyHubStatisticsSnapshot } from "./schema.js";

/** Local Pickle history aggregation. Primary-only; a child daemon has none. */
export interface HubStatisticsPort {
  snapshot(): Promise<PickyHubStatisticsSnapshot>;
  reset(): Promise<PickyHubStatisticsSnapshot>;
  configureClassification(enabled: boolean): Promise<PickyHubStatisticsSnapshot>;
}

/** Background classification that must stop the moment consent is withdrawn. */
export interface ClassificationConsentPort {
  setClassificationEnabled(enabled: boolean): void;
}

interface HubStatisticsBrokerDependencies {
  statistics?: HubStatisticsPort;
  classifier?: ClassificationConsentPort;
  send: (socket: WebSocket, event: EventPayload) => void;
}

const HUB_STATISTICS_UNAVAILABLE = "Hub statistics unavailable on this daemon";

/**
 * Owns the Hub statistics round trips and the serialization of consent changes:
 * configuration requests run one at a time, and only the newest one may hand the
 * classifier its enabled state.
 */
export class HubStatisticsBroker {
  private configuration: Promise<void> = Promise.resolve();
  private configurationGeneration = 0;

  constructor(private readonly dependencies: HubStatisticsBrokerDependencies) {}

  async sendSnapshot(socket: WebSocket, commandId: string, reset: boolean): Promise<void> {
    const statistics = this.dependencies.statistics;
    if (!statistics) {
      this.sendFailure(socket, commandId, HUB_STATISTICS_UNAVAILABLE);
      return;
    }
    try {
      const snapshot = reset ? await statistics.reset() : await statistics.snapshot();
      this.dependencies.send(socket, { type: "hubStatisticsResult", commandId, ok: true, errorMessage: null, snapshot });
    } catch (error) {
      this.sendFailure(socket, commandId, error instanceof Error ? error.message : String(error));
    }
  }

  async configure(socket: WebSocket, commandId: string, enabled: boolean): Promise<void> {
    const statistics = this.dependencies.statistics;
    if (!statistics) {
      this.sendFailure(socket, commandId, HUB_STATISTICS_UNAVAILABLE);
      return;
    }

    const generation = ++this.configurationGeneration;
    // Revoke immediately, even while an earlier opt-in is awaiting disk reads.
    if (!enabled) this.dependencies.classifier?.setClassificationEnabled(false);
    const operation = this.configuration.then(async () => {
      try {
        const snapshot = await statistics.configureClassification(enabled);
        if (generation === this.configurationGeneration) {
          this.dependencies.classifier?.setClassificationEnabled(enabled);
        }
        this.dependencies.send(socket, { type: "hubStatisticsResult", commandId, ok: true, errorMessage: null, snapshot });
      } catch (error) {
        // Never resume transmission after a failed withdrawal. The error tells
        // the caller the durable choice still needs retrying before a restart.
        this.sendFailure(socket, commandId, error instanceof Error ? error.message : String(error));
      }
    });
    this.configuration = operation.catch(() => undefined);
    await operation;
  }

  /** Stops an in-flight opt-in from applying after the daemon has shut down. */
  abandonPendingConfiguration(): void {
    this.configurationGeneration += 1;
  }

  private sendFailure(socket: WebSocket, commandId: string, errorMessage: string): void {
    this.dependencies.send(socket, { type: "hubStatisticsResult", commandId, ok: false, errorMessage });
  }
}
