import AppKit
import Foundation

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func openFile(_ file: DiffFile, repoRoot: String) {
    let path = file.newPath ?? file.oldPath ?? file.displayPath
    guard !path.isEmpty else { return }
    let basePath = repoRoot.isEmpty ? FileManager.default.currentDirectoryPath : repoRoot
    let url = path.hasPrefix("/")
        ? URL(fileURLWithPath: path)
        : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: basePath))
    let absoluteURL = url.standardizedFileURL
    if FileManager.default.fileExists(atPath: absoluteURL.path) {
        NSWorkspace.shared.open(absoluteURL)
    } else {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

func formattedCount(_ count: Int) -> String {
    count.formatted(.number.grouping(.automatic))
}
