//
//  PickyDiagnosticTextRedactorTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickyDiagnosticTextRedactorTests {
    @Test func redactsTokenLikeAssignments() {
        let text = "target_token=abc123456 NotifyToken=xyz987654 apiKey=secretvalue password: hunter2"
        let redacted = PickyDiagnosticTextRedactor.redact(text)
        #expect(!redacted.contains("abc123456"))
        #expect(!redacted.contains("xyz987654"))
        #expect(!redacted.contains("secretvalue"))
        #expect(!redacted.contains("hunter2"))
        #expect(redacted.contains("<redacted>"))
    }

    @Test func redactsKnownTokenFormats() {
        let text = "xoxb-111-222-secret https://hooks.slack.com/services/T/B/C sk-abcdefghijklmnopqrstuvwxyzaaa"
        let redacted = PickyDiagnosticTextRedactor.redact(text)
        #expect(!redacted.contains("xoxb-111-222-secret"))
        #expect(!redacted.contains("hooks.slack.com/services"))
        #expect(!redacted.contains("sk-abcdefghijkl"))
    }

    @Test func leavesOrdinaryText() {
        let text = "normal log line with tool=bash status=running"
        #expect(PickyDiagnosticTextRedactor.redact(text) == text)
    }

    @Test func redactsUserHomePaths() {
        let text = "running pid=1234 logDir=/Users/jane/Library/Application Support/Picky/Logs cwd=/Users/jane/projects/picky"
        let redacted = PickyDiagnosticTextRedactor.redact(text)
        #expect(!redacted.contains("/Users/jane"))
        #expect(redacted.contains("/Users/<redacted-user>/Library/Application Support/Picky/Logs"))
        #expect(redacted.contains("/Users/<redacted-user>/projects/picky"))
        // Non-PII context around the path is preserved so triagers still see
        // what the daemon was doing.
        #expect(redacted.contains("pid=1234"))
        #expect(redacted.contains("status") == false) // sanity: original had no status
    }

    @Test func redactsTemporaryFolderPaths() {
        let text = "failed to open /private/var/folders/ab/cdefg12345/T/picky-launcher-XYZ/Logs/agentd.stderr.log"
        let redacted = PickyDiagnosticTextRedactor.redact(text)
        #expect(!redacted.contains("/private/var/folders/ab/cdefg12345/T"))
        #expect(redacted.contains("<redacted>"))
    }

    @Test func leavesGenericUsersWordAlone() {
        // The redactor must not eat occurrences of the word "Users" that are
        // not preceded by a `/Users/` path component.
        let text = "Users connected: 3; status=ok"
        let redacted = PickyDiagnosticTextRedactor.redact(text)
        #expect(redacted == text)
    }
}
