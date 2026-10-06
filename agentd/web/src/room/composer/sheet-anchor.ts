/**
 * Click handler for a `.sheet-anchor`. The anchor spans the whole reading
 * column (760px on wide screens) while the menu inside is narrower, so a blanket
 * stopPropagation would swallow clicks on the empty strip beside the menu and
 * the backdrop could never dismiss it. Only clicks inside the menu stay put.
 */
export function stopInsideMenu(event: MouseEvent): void {
  if (event.target !== event.currentTarget) event.stopPropagation();
}
