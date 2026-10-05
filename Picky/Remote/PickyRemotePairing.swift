//
//  PickyRemotePairing.swift
//  Picky
//
//  Pairing presentation: what the "연결할 폰" sheet shows while a pairing code
//  is alive. The QR payload is the one thing both sides must agree on, so it
//  lives in a pure function with a test.
//

import CoreImage
import Foundation

#if canImport(AppKit)
import AppKit
#endif

struct PickyRemotePairingSession: Equatable {
    var code: String
    var expiresAt: Date
    /// URL reported by the gateway, which already includes the `#pair=` hash.
    var url: String?

    /// `<publicURL>/#pair=<code>`. The code travels in the fragment so it never
    /// reaches the server in a request line or a log.
    static func qrPayload(publicURL: String?, code: String, gatewayURL: String?) -> String? {
        if let gatewayURL, !gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return gatewayURL
        }
        guard let origin = PickyRemoteAccessSettings.normalizedPublicURL(publicURL ?? "") else { return nil }
        let normalizedCode = code.replacingOccurrences(of: "-", with: "").uppercased()
        guard !normalizedCode.isEmpty else { return nil }
        return "\(origin)/#pair=\(normalizedCode)"
    }

    /// `XXXX-XXXX`, the shape the gateway prints and the phone accepts.
    static func formatted(code: String) -> String {
        let bare = code.replacingOccurrences(of: "-", with: "").uppercased()
        guard bare.count == 8 else { return bare }
        let midpoint = bare.index(bare.startIndex, offsetBy: 4)
        return "\(bare[bare.startIndex..<midpoint])-\(bare[midpoint...])"
    }

    func secondsRemaining(now: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.down)))
    }
}

#if canImport(AppKit)
enum PickyRemoteQRCode {
    /// Medium correction keeps the code readable from a hand-held phone even
    /// when the Hub window is partially covered.
    static func image(for payload: String, sideLength: CGFloat) -> NSImage? {
        guard !payload.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, sideLength / max(output.extent.width, 1))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: sideLength, height: sideLength))
    }
}
#endif
