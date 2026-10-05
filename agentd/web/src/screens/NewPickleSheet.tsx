/**
 * New Pickle: pick a folder the Mac already knows (pinned or recent). The phone
 * never browses the Mac's file system (docs/remote-pwa-plan.md "방 목록").
 */
import { useSignal } from "@preact/signals";
import type { JSX } from "preact";
import { t } from "../app/i18n";
import { navigate } from "../app/navigation";
import type { AppStore } from "../app/store";
import { FolderIcon, Spinner } from "../ui/icons";
import { fileName } from "../app/format";
import { useDialog } from "../ui/use-dialog";

export function NewPickleSheet({ store, onClose }: { store: AppStore; onClose: () => void }): JSX.Element {
  const busyPath = useSignal<string | undefined>(undefined);
  const error = useSignal<string | undefined>(undefined);
  const folders = store.folders.value;
  const pinned = folders.pinned;
  const recent = folders.recent.filter((path) => !pinned.includes(path));
  const dialog = useDialog<HTMLDivElement>({ onDismiss: onClose });

  async function create(cwd: string): Promise<void> {
    if (busyPath.value) return;
    busyPath.value = cwd;
    error.value = undefined;
    const result = await store.command({ type: "pickle.create", cwd });
    busyPath.value = undefined;
    if (!result.ok) {
      error.value = result.error.code === "macOffline" ? t("remote.mac.offline.title") : t("remote.newPickle.failed");
      return;
    }
    const sessionId = (result.data as { sessionId?: string } | undefined)?.sessionId;
    onClose();
    if (sessionId) navigate({ name: "room", roomId: sessionId });
  }

  return (
    <div class="sheet-scrim" onClick={onClose}>
      <div
        class="sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="new-pickle-title"
        ref={dialog}
        onClick={(event) => event.stopPropagation()}
      >
        <div class="sheet-head">
          <span class="sheet-title" id="new-pickle-title">{t("remote.roomList.newPickle")}</span>
          <button class="sheet-cancel tap-target" type="button" onClick={onClose}>
            {t("common.cancel")}
          </button>
        </div>
        <div class="sheet-body">
          {error.value && <div class="notice error" role="alert">{error.value}</div>}
          {pinned.length === 0 && recent.length === 0 && (
            <div class="app-empty">
              <span class="app-empty-title">{t("remote.newPickle.empty")}</span>
            </div>
          )}
          {pinned.length > 0 && (
            <>
              <div class="folder-section-title">{t("remote.newPickle.pinned")}</div>
              {pinned.map((path) => (
                <FolderRow key={path} path={path} busy={busyPath.value === path} onSelect={() => void create(path)} />
              ))}
            </>
          )}
          {recent.length > 0 && (
            <>
              <div class="folder-section-title">{t("remote.newPickle.recent")}</div>
              {recent.map((path) => (
                <FolderRow key={path} path={path} busy={busyPath.value === path} onSelect={() => void create(path)} />
              ))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function FolderRow({ path, busy, onSelect }: { path: string; busy: boolean; onSelect: () => void }): JSX.Element {
  return (
    <button class="folder-row" type="button" aria-busy={busy} onClick={onSelect}>
      <span class="folder-icon">
        <FolderIcon size={18} />
      </span>
      <span class="folder-main">
        <span class="folder-name">{fileName(path)}</span>
        <span class="folder-path">{path}</span>
      </span>
      {busy && <Spinner />}
    </button>
  );
}
