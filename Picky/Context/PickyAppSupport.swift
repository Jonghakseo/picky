//
//  PickyAppSupport.swift
//  Picky
//

import Foundation

enum PickyAppSupport {
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Picky", isDirectory: true)
    }
}

struct PickyAppSupportScreenshotStore: PickyScreenshotStoring {
    let appSupportRoot: URL
    let fileManager: FileManager

    init(appSupportRoot: URL = PickyAppSupport.defaultRoot(), fileManager: FileManager = .default) {
        self.appSupportRoot = appSupportRoot
        self.fileManager = fileManager
    }

    func store(_ screen: PickyScreenContext, contextID: String, index: Int) throws -> PickyScreenshotContext {
        let directory = appSupportRoot.appendingPathComponent("Screenshots", isDirectory: true)
            .appendingPathComponent(contextID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = "shot-\(index + 1)"
        let fileURL = directory.appendingPathComponent("\(id).jpg")
        if let imageData = screen.imageData {
            try imageData.write(to: fileURL, options: .atomic)
        } else if !fileManager.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }

        return PickyScreenshotContext(
            id: id,
            label: screen.label,
            path: fileURL.path,
            screenId: "screen\(index + 1)",
            bounds: screen.frame,
            screenshotWidthInPixels: screen.screenshotWidthInPixels,
            screenshotHeightInPixels: screen.screenshotHeightInPixels,
            isCursorScreen: screen.isCursorScreen
        )
    }
}
