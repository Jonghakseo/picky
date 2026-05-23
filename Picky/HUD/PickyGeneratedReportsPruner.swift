//
//  PickyGeneratedReportsPruner.swift
//  Picky
//
//  Background sweep that keeps `~/Library/Application Support/Picky/
//  GeneratedReports/` from growing forever. The directory accumulates
//  Markdown reports every time the user opens an artifact/report viewer
//  for a session message; without this sweep the folder grows linearly
//  with usage even though most reports are only consulted once.
//

import Foundation

struct PickyGeneratedReportsPruner {
    /// Folder that owns the rolling Markdown reports. Decoupled so unit
    /// tests can point at a temporary directory.
    let directory: URL
    /// Files whose modification date is strictly older than this many days
    /// ago are removed. Files on the exact boundary stay so clock jitter
    /// never sweeps borderline reports.
    let retentionDays: Int
    let fileManager: FileManager
    /// Injection point for deterministic tests.
    let now: () -> Date

    init(
        directory: URL = PickyAppSupport.defaultRoot()
            .appendingPathComponent("GeneratedReports", isDirectory: true),
        retentionDays: Int = 30,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.fileManager = fileManager
        self.now = now
    }

    /// Sweeps the configured directory once. Designed for a single
    /// background call on app launch — safe to invoke when the directory
    /// is missing, and individual file failures are logged and swallowed
    /// so a partial permission issue cannot block app startup.
    func prune() {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            print("⚠️ Picky GeneratedReports prune — failed to enumerate: \(error.localizedDescription)")
            return
        }

        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)

        for entry in entries {
            guard entry.pathExtension.lowercased() == "md" else { continue }

            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            } catch {
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard let modified = values.contentModificationDate else { continue }
            guard modified < cutoff else { continue }

            do {
                try fileManager.removeItem(at: entry)
            } catch {
                print("⚠️ Picky GeneratedReports prune — failed to remove \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
