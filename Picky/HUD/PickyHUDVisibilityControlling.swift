//
//  PickyHUDVisibilityControlling.swift
//  Picky
//
//  Small seam used by fullscreen mode to make dock/fullscreen ownership
//  explicit without coupling the fullscreen coordinator to HUD internals.
//

@MainActor
protocol PickyHUDVisibilityControlling: AnyObject {
    var isHUDVisibleForFullscreen: Bool { get }
    func hideForFullscreen()
    func restoreAfterFullscreen()
}
