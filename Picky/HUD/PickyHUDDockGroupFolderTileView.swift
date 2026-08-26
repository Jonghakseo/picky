//
//  PickyHUDDockGroupFolderTileView.swift
//  Picky
//
//  Shared folder-tile composition used by the dock rail and offscreen render
//  gallery. The callers supply tile and header wrappers so the rail preserves
//  its picker, context-menu, and drag ownership around those visual surfaces.
//

import SwiftUI

struct PickyHUDDockGroupFolderTileView<Tile: View, Header: View>: View {
    let group: PickyDockGroup
    let metrics: PickyHUDDockMetrics
    let fontScale: CGFloat
    @ViewBuilder let tile: () -> Tile
    @ViewBuilder let header: (PickyHUDDockGroupHeader) -> Header

    var body: some View {
        VStack(spacing: metrics.groupHeaderContentSpacing) {
            tile()
            header(PickyHUDDockGroupHeader(group: group, metrics: metrics, fontScale: fontScale))
        }
        // The interaction frame follows the CJK-safe identity width, not just
        // the square tile, so the visible label is never outside its folder.
        .frame(
            width: PickyHUDDockGroupHeaderPresentation.labelWidth(
                metrics: metrics,
                fontScale: fontScale
            )
        )
    }
}
