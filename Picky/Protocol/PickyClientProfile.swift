//
//  PickyClientProfile.swift
//  Picky
//

import Foundation

/// What a connected client can render, mirroring agentd's `PickyClientProfile`
/// (`agentd/src/domain/client-profile.ts`).
///
/// - `core`: platform-neutral session control, such as the `picky` CLI.
/// - `desktop`: a macOS Picky.app process that owns overlay windows, the cursor
///   narration surface and the embedded terminal.
///
/// Picky.app declares `desktop` on `registerAppCapabilities` so the daemon gates
/// macOS-only broadcasts on an explicit claim. The field stays optional on the
/// wire: a client that omits it is classified from its bridge capabilities,
/// which is the fallback for app builds that predate this declaration.
enum PickyClientProfile: String, Codable, Equatable {
    case core, desktop
}
