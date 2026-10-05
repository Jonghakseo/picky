/**
 * The work panel as a sheet: what the Pickle produced and what it changed.
 *
 * Source: the HUD utility panel (Picky/HUD/Artifacts/ and the changes tab).
 * The phone drops the terminal tab: a terminal needs a keyboard and a wide
 * window, and the HUD keeps that work on the Mac.
 */
import { useEffect, useState } from "preact/hooks";
import type { JSX } from "preact";

import type { PickyAgentSession } from "../../../src/protocol";
import type { PickySessionDiffView } from "../../../src/protocol";
import type { RoomActions } from "./contract";
import { t } from "./i18n";
import { changeCounts, diffLineKind, parseDiffResult, type DiffResult } from "./policy/diff";

export type WorkTab = "artifacts" | "changes";

export interface WorkPanelProps {
  sessionId: string;
  session?: PickyAgentSession;
  actions: RoomActions;
  onDismiss: () => void;
}

export function WorkPanel({ sessionId, session, actions, onDismiss }: WorkPanelProps): JSX.Element {
  const [tab, setTab] = useState<WorkTab>("artifacts");
  const [view, setView] = useState<PickySessionDiffView>("unstaged");
  const [diff, setDiff] = useState<DiffResult | null>(null);
  const [diffError, setDiffError] = useState<string | null>(null);

  useEffect(() => {
    if (tab !== "changes") return;
    let cancelled = false;
    setDiff(null);
    setDiffError(null);
    void actions.query({ type: "session.diff", sessionId, view }).then((result) => {
      if (cancelled) return;
      if (!result.ok) {
        setDiffError(result.error.message || t("hud.changes.error", ""));
        return;
      }
      setDiff(parseDiffResult(result.data));
    });
    return () => {
      cancelled = true;
    };
    // `actions` is rebuilt each render by the shell; the query inputs are the identity here.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, view, sessionId]);

  return (
    <div class="sheet-backdrop" onClick={onDismiss}>
      <div
        class="sheet-panel"
        role="dialog"
        aria-label={t("hud.utilityPanel.accessibilityLabel")}
        onClick={(event: MouseEvent) => event.stopPropagation()}
      >
        <div class="sheet-head">
          <span class="sheet-title">{t("hud.utilityPanel.accessibilityLabel")}</span>
          <button class="sheet-close" type="button" onClick={onDismiss}>
            <span aria-hidden="true">✕</span>
            <span class="sr-only">{t("common.close")}</span>
          </button>
        </div>
        <div class="panel-tabs" role="tablist">
          <button
            class={`panel-tab${tab === "artifacts" ? " is-selected" : ""}`}
            type="button"
            role="tab"
            aria-selected={tab === "artifacts"}
            onClick={() => setTab("artifacts")}
          >
            {t("hud.utilityPanel.tab.artifacts")}
          </button>
          <button
            class={`panel-tab${tab === "changes" ? " is-selected" : ""}`}
            type="button"
            role="tab"
            aria-selected={tab === "changes"}
            onClick={() => setTab("changes")}
          >
            {t("hud.utilityPanel.tab.changes")}
          </button>
        </div>
        <div class="sheet-body">
          {tab === "artifacts" ? (
            <Artifacts session={session} actions={actions} />
          ) : (
            <Changes
              session={session}
              view={view}
              onView={setView}
              diff={diff}
              error={diffError}
            />
          )}
        </div>
      </div>
    </div>
  );
}

function Artifacts({ session, actions }: { session?: PickyAgentSession; actions: RoomActions }): JSX.Element {
  const artifacts = session?.artifacts ?? [];
  if (artifacts.length === 0) return <div class="panel-empty">{t("hud.artifacts.empty")}</div>;
  return (
    <div class="panel-list">
      {artifacts.map((artifact) => {
        const url = artifact.url;
        const path = artifact.path;
        const open = (): void => {
          if (path) actions.openFile(path);
          else if (url) actions.openExternal(url);
        };
        return (
          <button class="panel-row" type="button" key={artifact.id} onClick={open} disabled={!path && !url}>
            <span class="panel-row-text">
              <span class="panel-row-title">{artifact.title}</span>
              <span class="panel-row-detail">{path ?? url ?? t("hud.artifactTray.missing")}</span>
            </span>
            <span class="panel-badge">{artifact.kind}</span>
          </button>
        );
      })}
    </div>
  );
}

function Changes({
  session,
  view,
  onView,
  diff,
  error,
}: {
  session?: PickyAgentSession;
  view: PickySessionDiffView;
  onView: (view: PickySessionDiffView) => void;
  diff: DiffResult | null;
  error: string | null;
}): JSX.Element {
  const changed = session?.changedFiles ?? [];
  return (
    <div class="panel-list">
      <div class="panel-tabs" role="tablist">
        {(["unstaged", "staged"] as PickySessionDiffView[]).map((option) => (
          <button
            key={option}
            class={`panel-tab${view === option ? " is-selected" : ""}`}
            type="button"
            role="tab"
            aria-selected={view === option}
            onClick={() => onView(option)}
          >
            {t(option === "staged" ? "hud.changes.view.staged" : "hud.changes.view.unstaged")}
          </button>
        ))}
      </div>
      {error ? <div class="panel-empty">{t("hud.changes.error", error)}</div> : null}
      {!error && diff === null ? <div class="panel-empty">{t("hud.changes.loading")}</div> : null}
      {diff && !diff.isGitRepo ? <div class="panel-empty">{t("hud.changes.notGitRepository")}</div> : null}
      {diff && diff.isGitRepo && diff.files.length === 0 ? (
        changed.length > 0 ? (
          changed.map((file) => (
            <div class="panel-row" key={file.path}>
              <span class="panel-row-text">
                <span class="panel-row-title">{file.path}</span>
                {file.summary ? <span class="panel-row-detail">{file.summary}</span> : null}
              </span>
              <span class="panel-badge">{file.status}</span>
            </div>
          ))
        ) : (
          <div class="panel-empty">{t("hud.changes.empty")}</div>
        )
      ) : null}
      {diff?.files.map((file) => (
        <div key={file.path}>
          <div class="panel-row">
            <span class="panel-row-text">
              <span class="panel-row-title">{file.path}</span>
              <span class="panel-row-detail">
                {file.renamedFrom ? `${file.renamedFrom} → ` : ""}
                {changeCounts(file.additions, file.deletions)}
              </span>
            </span>
            <span class="panel-badge">{file.status}</span>
          </div>
          <pre class="diff">
            {file.diff.split("\n").map((line, index) => (
              <span class={`diff-line is-${diffLineKind(line)}`} key={`${file.path}-${index}`}>
                {line === "" ? " " : line}
              </span>
            ))}
          </pre>
          {file.truncated ? <div class="panel-empty">{t("hud.changes.diffTruncated")}</div> : null}
        </div>
      ))}
      {diff?.filesTruncated ? <div class="panel-empty">{t("hud.changes.filesTruncated")}</div> : null}
    </div>
  );
}
