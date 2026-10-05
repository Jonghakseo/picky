/**
 * The four shapes a `system` message takes besides plain prose: an extension
 * notice, a tagged `role="custom"` payload, and the two compaction outcomes.
 *
 * Sources: Picky/HUD/Conversation/Bubbles/PickyAgentBubbleView.swift
 * (`PickyNotifyBubbleView`), Bubbles/PickyExtensionCustomMessageBubbleView.swift
 * and Bubbles/PickyCompactStatusViews.swift. The Mac expands these on hover or
 * click; here the whole header is the tap target.
 */
import { useState } from "preact/hooks";
import type { JSX } from "preact";

import type { PickySessionMessage } from "../../../../src/protocol";
import { ChevronDown, ChevronDownSmall, ChevronRight, ChevronUp, CheckCircle, NotifyError, NotifyInfo, NotifyWarning, Warning } from "../icons";
import { locale, t } from "../i18n";
import { Markdown } from "../markdown/Markdown";
import { isTruncated, truncatedMarkdown } from "../policy/message";
import type { ExtensionCustomMessagePresentation } from "../policy/system-message";
import {
  NOTIFY_PREVIEW_MAX_CHARACTERS,
  NOTIFY_PREVIEW_MAX_LINES,
  compactFailureDetail,
  compactSummaryPreview,
  compactTokenChangeText,
  notifyLevel,
  notifyLevelLabelKey,
  notifyText,
} from "../policy/system-message";

export interface NotifyBubbleProps {
  message: PickySessionMessage;
  onOpenExternal?: (url: string) => void;
  onOpenFile?: (path: string) => void;
}

/** `ctx.ui.notify` output: the extension label, a level chip, and short markdown. */
export function NotifyBubble({ message, onOpenExternal, onOpenFile }: NotifyBubbleProps): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const level = notifyLevel(message);
  const text = notifyText(message);
  const expandable = isTruncated(text, NOTIFY_PREVIEW_MAX_LINES, NOTIFY_PREVIEW_MAX_CHARACTERS);
  const body = expanded ? text : truncatedMarkdown(text, NOTIFY_PREVIEW_MAX_LINES, NOTIFY_PREVIEW_MAX_CHARACTERS);
  const Icon = level === "error" ? NotifyError : level === "warning" ? NotifyWarning : NotifyInfo;
  return (
    <div class="row row--agent">
      <div class={`notify notify--${level}`}>
        <div class="notify-head">
          <Icon />
          <span class="notify-label">{t("hud.extension.label")}</span>
          <span class="notify-level">{t(notifyLevelLabelKey(level))}</span>
        </div>
        <div class="notify-body">
          <Markdown text={body} onOpenExternal={onOpenExternal} onOpenFile={onOpenFile} />
        </div>
        {expandable ? (
          <button class="notify-expand" type="button" onClick={() => setExpanded((value) => !value)}>
            {expanded ? <ChevronUp size={10} /> : <ChevronDown size={10} />}
            <span>{t(expanded ? "common.collapse" : "common.expand")}</span>
          </button>
        ) : null}
      </div>
    </div>
  );
}

export interface ExtensionCustomMessageBubbleProps {
  presentation: ExtensionCustomMessagePresentation;
}

/** Pi's terminal keeps the `customType` label visible and folds the payload; so does this. */
export function ExtensionCustomMessageBubble({ presentation }: ExtensionCustomMessageBubbleProps): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const body = expanded ? presentation.fullText : presentation.previewLines.join("\n");
  const head = (
    <>
      {presentation.isCollapsible ? expanded ? <ChevronDown size={9} /> : <ChevronRight size={9} /> : null}
      <span class="xmsg-type">{presentation.customType}</span>
      {presentation.isCollapsible && !expanded ? (
        <span class="xmsg-more">{t("hud.extensionMessage.moreLines", presentation.hiddenLineCount)}</span>
      ) : null}
    </>
  );
  return (
    <div class="row row--agent">
      <div class="xmsg">
        {presentation.isCollapsible ? (
          <button
            class="xmsg-head"
            type="button"
            aria-expanded={expanded}
            aria-label={presentation.customType}
            onClick={() => setExpanded((value) => !value)}
          >
            {head}
          </button>
        ) : (
          <div class="xmsg-head">{head}</div>
        )}
        <pre class="xmsg-body">{body}</pre>
      </div>
    </div>
  );
}

/** "Conversation compacted", with the token change and the kept summary behind a tap. */
export function CompactCompletionRow({ message }: { message: PickySessionMessage }): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const tokenChange = compactTokenChangeText(message.compaction);
  const summary = compactSummaryPreview(message.compaction);
  return (
    <div class="compact-done">
      <button
        class="compact-done-head"
        type="button"
        aria-expanded={expanded}
        onClick={() => setExpanded((value) => !value)}
      >
        <CheckCircle />
        <span class="compact-done-title">{t("hud.compact.done.title")}</span>
        {tokenChange ? <span class="compact-done-tokens">{tokenChange}</span> : null}
        <span class="compact-done-chevron">{expanded ? <ChevronDownSmall size={9} /> : <ChevronRight size={9} />}</span>
      </button>
      {expanded ? (
        <div class="compact-done-detail">
          <p>{t("hud.compact.done.body")}</p>
          {summary ? <p class="compact-done-summary">{summary}</p> : null}
        </div>
      ) : null}
    </div>
  );
}

/** Auto-compaction gave up: what the summarizer said, then what it means. */
export function CompactFailureBubble({ message }: { message: PickySessionMessage }): JSX.Element {
  const detail = compactFailureDetailText(message);
  return (
    <div class="row row--agent">
      <div class="compact-failed">
        <div class="compact-failed-mark" aria-hidden="true">
          <Warning size={10} />
        </div>
        <div class="compact-failed-text">
          <div class="compact-failed-title">{t("hud.compact.failed.title")}</div>
          {detail ? <div class="compact-failed-detail">{detail}</div> : null}
        </div>
      </div>
    </div>
  );
}

/**
 * The failure body as one string. Typed parameters get the localized outcome
 * sentence; an older journal only contributes the lines below its title.
 */
export function compactFailureDetailText(message: PickySessionMessage): string | null {
  const parts = compactFailureDetail(message);
  if (!parts) return null;
  if (!parts.localized) return parts.detail;
  const usage = parts.usage
    ? t(
        "hud.compact.failed.usage",
        parts.usage.tokens === null ? t("hud.message.tokenCount.unknown") : formatTokens(parts.usage.tokens),
        formatTokens(parts.usage.windowTokens),
      )
    : null;
  const outcome = [t("hud.compact.failed.notReduced"), usage].filter(Boolean).join(" ");
  return parts.detail.length === 0 ? outcome : `${parts.detail}\n\n${outcome}`;
}

function formatTokens(value: number): string {
  return Math.round(value).toLocaleString(locale());
}
