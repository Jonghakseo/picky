/**
 * Pickle settings behind the composer chip.
 * Source: PickyConversationRuntimeControlsView.swift (sections, rows, toggles).
 * The keyboard shortcut hints (⌃P, ⌘N) are left out: a phone has no such keys.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import type { JSX } from "preact";

import type { ThinkingLevel } from "../../../../src/protocol";
import { ChevronRight } from "../icons";
import { useDialog } from "../../ui/use-dialog";
import { t } from "../i18n";
import { stopInsideMenu } from "./sheet-anchor";

export interface RuntimeModelOption {
  provider: string;
  modelId: string;
  displayName: string;
  fastModeSupported?: boolean;
}

export interface RuntimeOptions {
  models: RuntimeModelOption[];
  thinkingLevels: ThinkingLevel[];
}

export const THINKING_LEVELS: ThinkingLevel[] = ["off", "low", "medium", "high", "max"];

/** The HUD thinking picker lists `PickyMainAgentThinkingLevel.displayName`, not the raw level. */
const THINKING_LABEL_KEY = {
  off: "enum.thinking.off",
  minimal: "enum.thinking.minimal",
  low: "enum.thinking.low",
  medium: "enum.thinking.medium",
  high: "enum.thinking.high",
  xhigh: "enum.thinking.xhigh",
  max: "enum.thinking.max",
} satisfies Record<ThinkingLevel, string>;

/**
 * The gateway relays whatever the daemon answers for `session.runtimeOptions`.
 * Only the fields this sheet draws are required, so a daemon that adds fields
 * does not break the sheet and one that answers nothing still opens it.
 */
export function parseRuntimeOptions(data: unknown): RuntimeOptions {
  const record = (data ?? {}) as { models?: unknown; thinkingLevels?: unknown };
  const models: RuntimeModelOption[] = Array.isArray(record.models)
    ? record.models.flatMap((entry) => {
        const model = entry as Partial<RuntimeModelOption>;
        if (typeof model.provider !== "string" || typeof model.modelId !== "string") return [];
        return [
          {
            provider: model.provider,
            modelId: model.modelId,
            displayName: typeof model.displayName === "string" ? model.displayName : model.modelId,
            fastModeSupported: model.fastModeSupported === true,
          },
        ];
      })
    : [];
  const levels = Array.isArray(record.thinkingLevels)
    ? record.thinkingLevels.filter((level): level is ThinkingLevel =>
        THINKING_LEVELS.includes(level as ThinkingLevel),
      )
    : [];
  return { models, thinkingLevels: levels.length > 0 ? levels : THINKING_LEVELS };
}

export interface SettingsSheetProps {
  options: RuntimeOptions | null;
  model?: string;
  thinkingLevel?: ThinkingLevel;
  fastMode: boolean;
  fastModeSupported: boolean;
  notifyMain: boolean;
  notifyMacOS: boolean;
  onSelectModel: (model: RuntimeModelOption) => void;
  onSelectThinking: (level: ThinkingLevel) => void;
  onToggleFast: (enabled: boolean) => void;
  onToggleNotify: (target: "main" | "macos", enabled: boolean) => void;
  onDismiss: () => void;
}

type Page = "root" | "model" | "thinking";

export function SettingsSheet(props: SettingsSheetProps): JSX.Element {
  const [page, setPage] = useState<Page>("root");
  // Esc on a sub-page goes back to the settings list first, like the HUD menu.
  const dialog = useDialog<HTMLDivElement>({ onDismiss: () => (page === "root" ? props.onDismiss() : setPage("root")) });
  // A page change unmounts the focused row; start the new page at its first control.
  const firstRender = useRef(true);
  useEffect(() => {
    if (firstRender.current) {
      firstRender.current = false;
      return;
    }
    dialog.current?.querySelector<HTMLElement>("button:not(:disabled)")?.focus({ preventScroll: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page]);
  return (
    <div class="sheet-backdrop" onClick={props.onDismiss}>
      <div class="sheet-anchor is-leading" onClick={stopInsideMenu}>
        <div class="settings-menu" role="dialog" aria-modal="true" aria-label={t("hud.composer.settings.title")} ref={dialog}>
          {page === "root" ? <RootPage {...props} onOpen={setPage} /> : null}
          {page === "model" ? (
            <ListPage
              title={t("hud.composer.settings.model")}
              onBack={() => setPage("root")}
              rows={(props.options?.models ?? []).map((model) => ({
                id: `${model.provider}/${model.modelId}`,
                title: model.displayName,
                selected: props.model === model.modelId || props.model === `${model.provider}/${model.modelId}`,
                onSelect: () => {
                  props.onSelectModel(model);
                  setPage("root");
                },
              }))}
            />
          ) : null}
          {page === "thinking" ? (
            <ListPage
              title={t("hud.composer.settings.thinking")}
              onBack={() => setPage("root")}
              rows={(props.options?.thinkingLevels ?? THINKING_LEVELS).map((level) => ({
                id: level,
                title: t(THINKING_LABEL_KEY[level]),
                selected: props.thinkingLevel === level,
                onSelect: () => {
                  props.onSelectThinking(level);
                  setPage("root");
                },
              }))}
            />
          ) : null}
        </div>
      </div>
    </div>
  );
}

function RootPage(props: SettingsSheetProps & { onOpen: (page: Page) => void }): JSX.Element {
  return (
    <>
      <div class="settings-section">{t("hud.composer.settings.title")}</div>
      <button class="settings-row" type="button" onClick={() => props.onOpen("model")}>
        <span class="settings-row-title">{t("hud.composer.settings.model")}</span>
        <span class="settings-row-value">{compactModelName(props.model) ?? ""}</span>
        <span class="settings-row-chevron">
          <ChevronRight />
        </span>
      </button>
      <button class="settings-row" type="button" onClick={() => props.onOpen("thinking")}>
        <span class="settings-row-title">{t("hud.composer.settings.thinking")}</span>
        <span class="settings-row-value">{props.thinkingLevel ?? ""}</span>
        <span class="settings-row-chevron">
          <ChevronRight />
        </span>
      </button>
      {props.fastModeSupported ? (
        <ToggleRow
          title={t("hud.composer.settings.fast")}
          detail={t("hud.composer.settings.fast.detail")}
          on={props.fastMode}
          onToggle={() => props.onToggleFast(!props.fastMode)}
        />
      ) : null}
      <div class="settings-divider" role="separator" />
      <div class="settings-section">{t("hud.composer.settings.completion")}</div>
      <ToggleRow
        title={t("hud.composer.settings.notifyMain")}
        on={props.notifyMain}
        onToggle={() => props.onToggleNotify("main", !props.notifyMain)}
      />
      <ToggleRow
        title={t("hud.composer.settings.notifyMacOS")}
        on={props.notifyMacOS}
        onToggle={() => props.onToggleNotify("macos", !props.notifyMacOS)}
      />
    </>
  );
}

function ToggleRow({
  title,
  detail,
  on,
  onToggle,
}: {
  title: string;
  detail?: string;
  on: boolean;
  onToggle: () => void;
}): JSX.Element {
  return (
    <button class="settings-row is-toggle" type="button" role="switch" aria-checked={on} onClick={onToggle}>
      <span class="settings-row-text">
        <span class="settings-row-title">{title}</span>
        {detail ? <span class="settings-row-detail">{detail}</span> : null}
      </span>
      <span class={`switch${on ? " is-on" : ""}`} aria-hidden="true">
        <span class="switch-knob" />
      </span>
    </button>
  );
}

interface ListRow {
  id: string;
  title: string;
  selected: boolean;
  onSelect: () => void;
}

function ListPage({ title, rows, onBack }: { title: string; rows: ListRow[]; onBack: () => void }): JSX.Element {
  return (
    <>
      <button class="settings-row" type="button" onClick={onBack}>
        <span class="settings-row-title">{title}</span>
        <span class="settings-row-value">{t("hud.composer.settings.back.accessibilityLabel")}</span>
      </button>
      <div class="settings-divider" role="separator" />
      {rows.map((row) => (
        <button key={row.id} class="settings-row" type="button" onClick={row.onSelect}>
          <span class="settings-row-title">{row.title}</span>
          {row.selected ? <span class="settings-row-value">{t("common.selected")}</span> : null}
        </button>
      ))}
    </>
  );
}

/** Chip model name without the vendor prefix, like `PickyComposerRuntimePresentation`. */
export function compactModelName(identifier: string | undefined): string | undefined {
  if (!identifier) return undefined;
  const parts = identifier.split("/").filter((part) => part.length > 0);
  return parts[parts.length - 1] ?? identifier;
}
