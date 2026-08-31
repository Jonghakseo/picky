export const PI_MODEL_SCOPE_CONFLICT_CODE = "picky_model_scope_conflict";
export const PI_MODEL_SCOPE_CONFLICT_PREFIX = "PICKY_MODEL_SCOPE_CONFLICT";

/** A stable protocol-facing conflict independent of Pi's human-readable error text. */
export class PiModelScopeConflictError extends Error {
  readonly code = PI_MODEL_SCOPE_CONFLICT_CODE;

  constructor() {
    super(`${PI_MODEL_SCOPE_CONFLICT_PREFIX}: stale enabledModels revision`);
    this.name = "PiModelScopeConflictError";
  }
}
