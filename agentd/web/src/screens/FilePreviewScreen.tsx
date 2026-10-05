/**
 * Read-only preview of a file the conversation refers to (plan decision 7).
 * The gateway resolves the path like the HUD does and only serves paths the
 * session actually references, so this screen just renders what it gets.
 *
 * No editing, no "open on the Mac", and links inside a preview are not followed.
 */
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { JSX } from "preact";
import { Markdown } from "picky:markdown";
import type { RemoteFileMetaResponse } from "../../../src/remote/protocol";
import { fileName, formatBytes } from "../app/format";
import { t } from "../app/i18n";
import { goBack } from "../app/navigation";
import type { AppStore } from "../app/store";
import { ChevronLeftIcon, DocumentIcon, Spinner } from "../ui/icons";
import { TransportError } from "../app/transport";

type LoadState =
  | { kind: "loading" }
  | { kind: "loaded"; meta: RemoteFileMetaResponse }
  | { kind: "error"; title: string; help: string };

export function FilePreviewScreen({ store, roomId, path }: { store: AppStore; roomId: string; path: string }): JSX.Element {
  const state = useSignal<LoadState>({ kind: "loading" });

  useEffect(() => {
    let cancelled = false;
    state.value = { kind: "loading" };
    store.transport
      .fileMeta(roomId, path)
      .then((meta) => {
        if (!cancelled) state.value = { kind: "loaded", meta };
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        state.value = failureState(error);
      });
    return () => {
      cancelled = true;
    };
  }, [roomId, path]);

  const held = state.value;
  const title = held.kind === "loaded" ? held.meta.name : fileName(path);

  return (
    <div class="app-shell">
      <div class="app-topbar bordered app-side-inset">
        <button class="icon-button" type="button" aria-label={t("remote.room.back")} onClick={() => goBack()}>
          <ChevronLeftIcon size={17} />
        </button>
        <h1 class="app-topbar-title">{title}</h1>
      </div>

      <div class="app-scroll app-side-inset">
        {held.kind === "loading" && (
          <div class="loading-row">
            <Spinner />
            <span>{t("remote.loading")}</span>
          </div>
        )}

        {held.kind === "error" && (
          <div class="preview-unsupported">
            <DocumentIcon size={24} />
            <span class="preview-unsupported-title">{held.title}</span>
            <span class="preview-unsupported-body">{held.help}</span>
          </div>
        )}

        {held.kind === "loaded" && (
          <>
            <div class="preview-meta">
              <span class="preview-path">{held.meta.path}</span>
              <span class="preview-size">{formatBytes(held.meta.size, store.locale)}</span>
            </div>
            <PreviewBody store={store} roomId={roomId} path={path} meta={held.meta} />
          </>
        )}
      </div>
    </div>
  );
}

function PreviewBody({
  store,
  roomId,
  path,
  meta,
}: {
  store: AppStore;
  roomId: string;
  path: string;
  meta: RemoteFileMetaResponse;
}): JSX.Element {
  const url = store.transport.fileUrl(roomId, path);
  switch (meta.kind) {
    case "text":
      return (
        <>
          {meta.truncated && <div class="notice info">{t("remote.preview.truncated")}</div>}
          <pre class="preview-text">{meta.text ?? ""}</pre>
        </>
      );
    case "markdown":
      return (
        <>
          {meta.truncated && <div class="notice info">{t("remote.preview.truncated")}</div>}
          <div class="preview-markdown">
            <Markdown text={meta.text ?? ""} />
          </div>
        </>
      );
    case "image":
      return <img class="preview-image" src={url} alt={meta.name} />;
    case "pdf":
      return <iframe class="preview-frame" src={url} title={meta.name} />;
    case "html":
    case "svg":
      // The gateway serves these with a sandbox CSP; the sandbox attribute keeps
      // scripts and same-origin access off on this side too.
      return <iframe class="preview-frame" src={url} title={meta.name} sandbox="" />;
    case "directory":
      return (
        <div class="preview-unsupported">
          <DocumentIcon size={24} />
          <span class="preview-unsupported-title">{t("remote.preview.directory")}</span>
        </div>
      );
    case "binary":
      return (
        <div class="preview-unsupported">
          <DocumentIcon size={24} />
          <span class="preview-unsupported-title">{t("remote.preview.unsupported")}</span>
          <span class="preview-unsupported-body">{formatBytes(meta.size, store.locale)}</span>
        </div>
      );
  }
}

/** HUD copy for a missing file or an unresolvable path, with a phone-shaped next step. */
function failureState(error: unknown): LoadState {
  const status = error instanceof TransportError ? error.status : 0;
  if (status === 404) {
    return { kind: "error", title: t("hud.markdownLink.fileNotFound"), help: t("hud.markdownLink.fileNotFound.help") };
  }
  if (status === 403 || status === 400) {
    return { kind: "error", title: t("hud.markdownLink.cannotOpen"), help: t("hud.markdownLink.unresolvedPath.help") };
  }
  return { kind: "error", title: t("hud.markdownLink.cannotOpen"), help: t("remote.preview.cannotOpen.help") };
}
