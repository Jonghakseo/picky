//
//  PickyHUDDockGroupFolderTileView.swift
//  Picky
//
//  Shared square folder-tile composition used by the dock rail and offscreen
//  gallery. The title stays inside the tile's bottom edge while each caller
//  retains its picker, context-menu, and drag ownership.
//

import SwiftUI

struct PickyHUDDockGroupFolderTileView<Tile: View, Header: View>: View {
    let group: PickyDockGroup
    let metrics: PickyHUDDockMetrics
    let fontScale: CGFloat
    @ViewBuilder let tile: () -> Tile
    @ViewBuilder let header: (PickyHUDDockGroupHeader) -> Header

    var body: some View {
        tile()
            .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
            .overlay(alignment: .bottom) {
                header(PickyHUDDockGroupHeader(group: group, metrics: metrics, fontScale: fontScale))
                    .padding(.bottom, PickyHUDDockGroupHeaderPresentation.bottomInset(
                        metrics: metrics, fontScale: fontScale
                    ))
            }
            .frame(width: metrics.sessionTileWidth, height: metrics.sessionTileHeight)
    }
}
