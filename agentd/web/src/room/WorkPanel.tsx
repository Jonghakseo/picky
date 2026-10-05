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
import { onTablistKeyDown, useDialog } from "../ui/use-dialog";
import { t } from "./i18n";
import { changeCounts, diffLineKind, parseDiffResult, type DiffResult } from "./policy/diff";
import {
  changesTabCounts,
  compactWorkspacePath,
  gitSummaryPresentation,
  parseGitSummary,
  type GitMetricPair,
  type GitSummary,
} from "./policy/git-summary";
import { Branch, Checkmark, DocOnDoc, Folder } from "./icons";

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
  const [gitSummary, setGitSummary] = useState<GitSummary | null>(null);
  const dialog = useDialog<HTMLDivElement>({ onDismiss });

  // Refreshed when the Pickle changes state, which is when its work lands.
  // A daemon too old to answer leaves the summary empty; the folder row still shows.
  const sessionStatus = session?.status;
  useEffect(() => {
    let cancelled = false;
    void actions.query({ type: "session.gitSummary", sessionId }).then((result) => {
      if (cancelled) return;
      setGitSummary(result.ok ? parseGitSummary(result.data) : null);
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId, sessionStatus]);
  const tabCounts = changesTabCounts(gitSummary);

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
    <div class="sheet-backdrop work-sheet" onClick={onDismiss}>
      <div
        class="sheet-panel"
        role="dialog"
        aria-modal="true"
        aria-label={t("hud.utilityPanel.accessibilityLabel")}
        ref={dialog}
        onClick={(event: MouseEvent) => event.stopPropagation()}
      >
        <div class="sheet-head">
          <span class="sheet-title">{t("hud.utilityPanel.accessibilityLabel")}</span>
          <button class="sheet-close" type="button" onClick={onDismiss}>
            <span aria-hidden="true">✕</span>
            <span class="sr-only">{t("common.close")}</span>
          </button>
        </div>
        <GitSummarySection cwd={session?.cwd} summary={gitSummary} />
        <div class="panel-tabs" role="tablist" onKeyDown={onTablistKeyDown}>
          {(["artifacts", "changes"] as WorkTab[]).map((option) => (
            <button
              key={option}
              id={`work-tab-${option}`}
              class={`panel-tab${tab === option ? " is-selected" : ""}`}
              type="button"
              role="tab"
              aria-selected={tab === option}
              aria-controls="work-tabpanel"
              tabIndex={tab === option ? 0 : -1}
              onClick={() => setTab(option)}
            >
              {t(option === "artifacts" ? "hud.utilityPanel.tab.artifacts" : "hud.utilityPanel.tab.changes")}
              {option === "changes" && tabCounts ? (
                <span class="panel-tab-counts">
                  <span class="sr-only">, {t("remote.room.work.git.uncommitted")}</span>
                  <MetricPair pair={tabCounts} />
                </span>
              ) : null}
            </button>
          ))}
        </div>
        <div class="sheet-body" id="work-tabpanel" role="tabpanel" aria-labelledby={`work-tab-${tab}`}>
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

function GitSummarySection({ cwd, summary }: { cwd?: string; summary: GitSummary | null }): JSX.Element | null {
  const presentation = summary ? gitSummaryPresentation(summary) : undefined;
  const path = cwd?.trim();
  if (!presentation && !path) return null;
  return (
    <section class="work-git" aria-label={t("hud.context.details.accessibilityLabel")}>
      {presentation ? (
        <div class="work-git-row">
          <Branch size={14} class="work-git-icon" />
          {presentation.repositoryName ? <span class="work-git-repo">{presentation.repositoryName}</span> : null}
          {presentation.repositoryName && presentation.branchLabel ? (
            <span class="work-git-sep" aria-hidden="true">
              ·
            </span>
          ) : null}
          {presentation.branchLabel ? <span class="work-git-branch">{presentation.branchLabel}</span> : null}
          {presentation.ahead > 0 ? (
            <span class="work-git-position is-ahead" role="img" aria-label={t("remote.room.work.git.ahead", presentation.ahead)}>
              ↑{presentation.ahead}
            </span>
          ) : null}
          {presentation.behind > 0 ? (
            <span class="work-git-position is-behind" role="img" aria-label={t("remote.room.work.git.behind", presentation.behind)}>
              ↓{presentation.behind}
            </span>
          ) : null}
        </div>
      ) : null}
      {presentation?.total ? (
        <div class="work-git-metrics">
          <span>{t(presentation.total.isBranch ? "remote.room.work.git.branchTotal" : "remote.room.work.git.uncommitted")}</span>
          <MetricPair pair={presentation.total.pair} />
          {presentation.uncommitted ? (
            <>
              <span class="work-git-sep" aria-hidden="true">
                ·
              </span>
              <span>{t("remote.room.work.git.uncommitted")}</span>
              <MetricPair pair={presentation.uncommitted} dim />
            </>
          ) : null}
        </div>
      ) : null}
      {path ? <WorkspacePath path={path} /> : null}
    </section>
  );
}

function MetricPair({ pair, dim = false }: { pair: GitMetricPair; dim?: boolean }): JSX.Element {
  return (
    <span class={`work-git-pair${dim ? " is-dim" : ""}`}>
      {pair.insertions ? <span class="work-git-add">{pair.insertions}</span> : null}
      {pair.deletions ? <span class="work-git-del">{pair.deletions}</span> : null}
    </span>
  );
}

function WorkspacePath({ path }: { path: string }): JSX.Element {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1_500);
    return () => clearTimeout(timer);
  }, [copied]);
  const clipboard = globalThis.navigator?.clipboard;
  const label = t(copied ? "hud.context.workspace.copy.copied" : "hud.context.workspace.copy.help");
  return (
    <div class="work-git-path">
      <Folder size={14} class="work-git-icon" />
      <span class="work-git-path-text">{compactWorkspacePath(path)}</span>
      {clipboard ? (
        <button
          class={`work-git-copy${copied ? " is-copied" : ""}`}
          type="button"
          aria-label={label}
          title={label}
          onClick={() => {
            void clipboard.writeText(path).then(
              () => setCopied(true),
              () => setCopied(false),
            );
          }}
        >
          {copied ? <Checkmark size={14} /> : <DocOnDoc size={14} />}
        </button>
      ) : null}
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
      {/* A segmented choice that refetches, not a tab set with panels of its own. */}
      <div class="panel-tabs" role="group">
        {(["unstaged", "staged"] as PickySessionDiffView[]).map((option) => (
          <button
            key={option}
            class={`panel-tab${view === option ? " is-selected" : ""}`}
            type="button"
            aria-pressed={view === option}
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
