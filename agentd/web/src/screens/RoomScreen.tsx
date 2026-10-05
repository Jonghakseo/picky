/**
 * Binds the store to the conversation UI. Everything the room needs arrives as
 * a `RoomViewModel` plus `RoomActions`, so the conversation UI never touches
 * the transport (`src/room/contract.ts`).
 */
import { useEffect } from "preact/hooks";
import type { JSX } from "preact";
import { RoomView } from "picky:room";
import { MAIN_ROOM_ID } from "../../../src/remote/constants";
import type { RemoteRoom } from "../../../src/remote/protocol";
import type { RoomActions, RoomViewModel } from "../room/contract";
import { t } from "../app/i18n";
import { goBack, navigate } from "../app/navigation";
import type { AppStore } from "../app/store";

export function RoomScreen({ store, roomId, wide = false }: { store: AppStore; roomId: string; wide?: boolean }): JSX.Element {
  useEffect(() => {
    store.openRoom(roomId);
    return () => store.closeRoom(roomId);
  }, [roomId]);

  const runtime = store.runtime(roomId).value;
  const main = roomId === MAIN_ROOM_ID ? store.main.value : undefined;
  const room = store.room(roomId) ?? placeholderRoom(roomId, runtime.session?.title);

  const vm: RoomViewModel = {
    room,
    session: runtime.session,
    main,
    loading: roomId === MAIN_ROOM_ID ? runtime.loading && main === undefined : runtime.loading,
    macConnected: store.mac.value.connected,
    online: store.connection.value === "open",
    dictation: store.mac.value.dictation,
    locale: store.locale,
    layout: wide ? "wide" : "phone",
  };

  const actions: RoomActions = {
    command: (command) => store.command(command),
    query: (query) => store.query(query),
    upload: (file, name) => store.transport.upload(file, name),
    uploadUrl: (uploadId) => store.transport.uploadUrl(uploadId),
    dictate: (audio) => store.transport.dictate(audio),
    fileMeta: (path) => store.transport.fileMeta(roomId, path),
    fileUrl: (path) => store.transport.fileUrl(roomId, path),
    openFile: (path) => navigate({ name: "preview", roomId, path }),
    openExternal: (url) => {
      globalThis.open(url, "_blank", "noopener,noreferrer");
    },
    back: () => goBack({ name: "rooms" }),
    loadDraft: () => store.loadDraft(roomId),
    saveDraft: (text) => store.saveDraft(roomId, text),
    feedback: (kind) => {
      // Taptic Engine is not reachable from the web; vibration is the closest
      // thing browsers expose and iOS ignores it.
      const pattern = kind === "error" ? [12, 40, 12] : kind === "warning" ? [10, 30] : 10;
      globalThis.navigator?.vibrate?.(pattern);
    },
  };

  return <RoomView vm={vm} actions={actions} />;
}

/** A room opened by a link or a notification before the room list arrived. */
function placeholderRoom(roomId: string, title: string | undefined): RemoteRoom {
  const isMain = roomId === MAIN_ROOM_ID;
  return {
    id: roomId,
    kind: isMain ? "main" : "pickle",
    title: title ?? (isMain ? t("remote.room.main.title") : ""),
    status: isMain ? "idle" : "queued",
    unread: false,
    pinned: isMain,
    archived: false,
    groupIds: [],
    pendingQuestion: false,
    backgroundTasks: 0,
  };
}
