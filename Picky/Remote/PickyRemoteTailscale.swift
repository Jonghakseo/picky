//
//  PickyRemoteTailscale.swift
//  Picky
//
//  Thin wrapper over the Tailscale CLI. Picky never configures the user's
//  tailnet on its own: it reads status so the settings page can show what is
//  already set up, and runs `tailscale serve` only when the user presses a
//  button.
//

import Foundation

struct PickyTailscaleStatus: Equatable {
    /// MagicDNS name without the trailing dot, e.g. `mac.tailnet-1234.ts.net`.
    var magicDNSName: String?
    var isServing: Bool
    /// Port on 127.0.0.1 that `tailscale serve` currently forwards to, when known.
    var servedPort: Int?
}

enum PickyTailscaleError: LocalizedError, Equatable {
    case cliNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound: L10n.t("settings.remote.tailscale.error.notInstalled")
        case .commandFailed(let message): message
        }
    }
}

enum PickyTailscaleParser {
    /// `tailscale status --json` -> MagicDNS name. The CLI reports `Self.DNSName`
    /// with a trailing dot, which is valid DNS but ugly in a URL.
    static func magicDNSName(fromStatusJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = root["Self"] as? [String: Any],
              let raw = selfNode["DNSName"] as? String
        else { return nil }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    /// `tailscale serve status --json` -> whether anything is served on 443 and
    /// which loopback port it points at. The shape is
    /// `{"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:17640"}}}}}`.
    static func serveState(fromServeStatusJSON data: Data) -> (isServing: Bool, port: Int?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = root["Web"] as? [String: Any]
        else { return (false, nil) }
        for (_, value) in web {
            guard let host = value as? [String: Any],
                  let handlers = host["Handlers"] as? [String: Any]
            else { continue }
            for (_, handler) in handlers {
                guard let handler = handler as? [String: Any],
                      let proxy = handler["Proxy"] as? String
                else { continue }
                return (true, URLComponents(string: proxy)?.port)
            }
        }
        return (false, nil)
    }

    /// Tailscale prints actionable advice on stderr (most often a link to enable
    /// HTTPS certificates for the tailnet). Keep the link, drop the noise.
    static func readableFailure(stdout: String, stderr: String) -> String {
        let combined = (stderr + "\n" + stdout)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !combined.isEmpty else { return L10n.t("settings.remote.tailscale.error.generic") }
        // Keep the first few lines plus any line containing a URL, which is the
        // part the user actually has to act on.
        var kept: [String] = []
        for line in combined where kept.count < 6 {
            kept.append(line)
        }
        for line in combined where line.contains("https://") && !kept.contains(line) {
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}

enum PickyTailscaleCLI {
    static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale"
    ]

    static func locate(fileManager: FileManager = .default) -> URL? {
        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Runs the CLI off the main thread. Every call is user-initiated.
struct PickyTailscaleService {
    var executableURL: URL?

    init(executableURL: URL? = PickyTailscaleCLI.locate()) {
        self.executableURL = executableURL
    }

    var isInstalled: Bool { executableURL != nil }

    func status() async throws -> PickyTailscaleStatus {
        let statusOutput = try await run(["status", "--json"])
        let name = PickyTailscaleParser.magicDNSName(fromStatusJSON: statusOutput.stdout)
        let serve = try? await run(["serve", "status", "--json"])
        let state = serve.map { PickyTailscaleParser.serveState(fromServeStatusJSON: $0.stdout) } ?? (false, nil)
        return PickyTailscaleStatus(magicDNSName: name, isServing: state.0, servedPort: state.1)
    }

    func startServe(port: Int) async throws {
        _ = try await run(["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"])
    }

    func stopServe() async throws {
        _ = try await run(["serve", "--https=443", "off"])
    }

    private struct Output {
        var stdout: Data
        var stderr: Data
    }

    private func run(_ arguments: [String]) async throws -> Output {
        guard let executableURL else { throw PickyTailscaleError.cliNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: PickyTailscaleError.cliNotFound)
                    return
                }
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let message = PickyTailscaleParser.readableFailure(
                        stdout: String(data: stdout, encoding: .utf8) ?? "",
                        stderr: String(data: stderr, encoding: .utf8) ?? ""
                    )
                    continuation.resume(throwing: PickyTailscaleError.commandFailed(message))
                    return
                }
                continuation.resume(returning: Output(stdout: stdout, stderr: stderr))
            }
        }
    }
}
