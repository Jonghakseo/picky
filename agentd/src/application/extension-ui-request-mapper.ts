import type { PickyExtensionUiRequest } from "../protocol.js";

export function mapExtensionUiRequest(rawRequest: Record<string, unknown>): PickyExtensionUiRequest {
  return rawRequest as PickyExtensionUiRequest;
}

export function extensionUiLogLine(request: PickyExtensionUiRequest): string {
  return `extension ui: ${request.method}${request.title ? ` ${request.title}` : ""}`;
}

export function extensionUiWaitingSummary(request: PickyExtensionUiRequest): string {
  return request.prompt ?? request.title ?? "Waiting for input";
}
