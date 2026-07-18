import type { PickyAnnotationOverlayRequest } from "../protocol.js";
import type { AnnotationInput, AnnotationMode } from "../domain/annotation-validation.js";

export interface PickyShowAnnotationsRequest {
  mode: AnnotationMode;
  screenId?: string;
  annotations: AnnotationInput[];
}

export interface PickyShowAnnotationsResult {
  request: PickyAnnotationOverlayRequest;
}
