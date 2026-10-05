/**
 * The two seams the shell shares with the conversation UI (`src/room/`, built by
 * another worker). `web/build.mjs` resolves each alias to the real file when it
 * exists and to a stand-in in `src/screens/` when it does not, so the shell
 * builds either way and the types stay the ones `room/contract.ts` defines.
 */
declare module "picky:room" {
  import type { VNode } from "preact";
  import type { RoomViewProps } from "../room/contract";
  export function RoomView(props: RoomViewProps): VNode | null;
}

declare module "picky:markdown" {
  import type { VNode } from "preact";
  import type { MarkdownProps } from "../room/contract";
  export function Markdown(props: MarkdownProps): VNode | null;
}
