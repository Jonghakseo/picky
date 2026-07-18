import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyAgentAnnotationOverlayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func resolvesSupportedOverlayShapesFromScreenshotPixels() throws {
        let resolved = try PickyAnnotationOverlayResolver.resolve(request(annotations: [
            annotation(id: "rect", shape: .rect, x: 200, y: 50, w: 100, h: 100, spotlight: true),
            annotation(id: "line", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200, spotlight: false),
            annotation(id: "label", shape: .label, x: 200, y: 100, label: " Save "),
        ]), now: now)

        #expect(resolved.first { $0.id == "rect" }?.rect == CGRect(x: 200, y: 225, width: 50, height: 50))
        #expect(resolved.first { $0.id == "rect" }?.spotlight == true)
        #expect(resolved.first { $0.id == "line" }?.point == CGPoint(x: 100, y: 300))
        #expect(resolved.first { $0.id == "line" }?.endPoint == CGPoint(x: 300, y: 200))
        #expect(resolved.first { $0.id == "line" }?.spotlight == false)
        #expect(resolved.first { $0.id == "label" }?.label == "Save")
        #expect(resolved.allSatisfy { $0.expiresAt == now.addingTimeInterval(66) && $0.pendingTTL == 6 })
    }

    @Test func bufferedAnnotationsRevealAfterSpeechAndExpireAfterTheirTtl() {
        let pending = resolvedAnnotation(id: "a", expiresAt: now.addingTimeInterval(66), pendingTTL: 6)
        // Streamed annotations are buffered, not shown, until narration reaches them.
        let buffered = reduce(PickyInteractionState(), .agentAnnotationsRequested(mode: .append, annotations: [pending]))
        #expect(buffered.agentAnnotations.isEmpty)
        #expect(buffered.pendingAgentAnnotations.count == 1)

        // First speech schedules the reveal; it is still not shown until the timer fires.
        let spoke = reduce(buffered, .speechStarted(text: "Look here.", speechID: UUID(), sourceContextID: "context"))
        #expect(spoke.agentAnnotations.isEmpty)
        let pendingID = spoke.pendingAgentAnnotations.first!.id

        // Reveal shows it and starts its ttl countdown from the moment it appears.
        let revealed = reduce(spoke, .agentAnnotationRevealDue(id: pendingID))
        #expect(revealed.agentAnnotations.map(\.id) == ["a"])
        #expect(revealed.agentAnnotations.first?.expiresAt == now.addingTimeInterval(6))
        #expect(revealed.agentAnnotations.first?.pendingTTL == nil)

        // It stays for its ttl, then expires.
        let notYet = reduce(revealed, .agentAnnotationsExpired(now: now.addingTimeInterval(5.9)))
        #expect(notYet.agentAnnotations.count == 1)
        let expired = reduce(notYet, .agentAnnotationsExpired(now: now.addingTimeInterval(6.1)))
        #expect(expired.agentAnnotations.isEmpty)
    }

    @Test func companionManagerAppliesAnnotationOverlayEvent() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        let sequenceBeforeEvent = manager.interactionProjectionSequence
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "manager-rect", shape: .rect, x: 200, y: 100, w: 40, h: 20),
        ])))
        // Annotations are buffered until narration reaches them; a silent turn settle
        // reveals whatever remains buffered.
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeEvent && manager.agentAnnotations.count == 1 }

        #expect(manager.agentAnnotations.count == 1)
        #expect(manager.agentAnnotations.first?.id == "manager-rect")
        #expect(manager.agentAnnotations.first?.rect == CGRect(x: 200, y: 240, width: 20, height: 10))
        #expect(manager.agentAnnotations.first?.visualStyle == .fallback)
    }

    @Test func companionManagerUsesTheMatchingCapturedScreenshotSamples() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        let sampleGrid = uniformGrid(.init(red: 1, green: 1, blue: 1))
        let context = PickyContextPacket(
            id: "context",
            source: "cli",
            capturedAt: now,
            transcript: "show me",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [PickyScreenshotContext(
                id: "shot-1",
                label: "primary",
                path: "/tmp/unused.jpg",
                screenId: "screen",
                bounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
                screenshotWidthInPixels: 400,
                screenshotHeightInPixels: 200,
                isCursorScreen: true,
                annotationColorSampleGrid: sampleGrid
            )],
            warnings: []
        )
        manager.noteExternalSubmission(kind: .submitMain, text: "show me", context: context)
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "adaptive", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200)],
            contextGeneration: 1
        )))
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))

        try await waitUntil { manager.agentAnnotations.first?.id == "adaptive" }

        #expect(manager.agentAnnotations.first?.visualStyle.palette == .brightViolet)
    }

    @Test func companionManagerKeepsBasePaletteAcrossSequentialAppendEvents() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        let white = PickyScreenshotSampleColor(red: 1, green: 1, blue: 1)
        let black = PickyScreenshotSampleColor(red: 0, green: 0, blue: 0)
        let sampleGrid = PickyScreenshotColorSampleGrid(
            width: 10,
            height: 10,
            pixels: Array(repeating: white, count: 50) + Array(repeating: black, count: 50)
        )!
        let context = overlayContext(sampleGrid: sampleGrid)
        manager.noteExternalSubmission(kind: .submitMain, text: "show me", context: context)
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "first", shape: .line, x1: 0, y1: 0, x2: 400, y2: 0)],
            mode: .replace,
            contextGeneration: 1
        )))
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "second", shape: .line, x1: 0, y1: 200, x2: 400, y2: 200)],
            mode: .append,
            contextGeneration: 1
        )))
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))

        try await waitUntil { manager.agentAnnotations.count == 2 }

        #expect(manager.agentAnnotations.map(\.visualStyle.palette) == [.brightViolet, .brightViolet])
    }

    @Test func schedulingExpiryIgnoresPersistingAnnotationsWithoutOverflow() {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        // A lingering annotation persists through narration with a far-future sentinel
        // expiry and no activated ttl. Converting that delay to UInt64 nanoseconds used
        // to overflow and crash; scheduling must simply skip it.
        let persisting = PickyAgentAnnotation(
            id: "persisting",
            shape: .rect,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 10, y: 10, width: 20, height: 20),
            label: nil,
            expiresAt: .distantFuture,
            pendingTTL: 6
        )
        manager.scheduleAnnotationExpiryIfNeeded(for: [persisting])

        // A finite (activated) expiry alongside a persisting one still schedules safely.
        let active = PickyAgentAnnotation(
            id: "active",
            shape: .rect,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 30, y: 30, width: 20, height: 20),
            label: nil,
            expiresAt: now.addingTimeInterval(2)
        )
        manager.scheduleAnnotationExpiryIfNeeded(for: [persisting, active])

        // Reaching here without a runtime trap is the regression assertion.
        #expect(manager.agentAnnotations.isEmpty)
    }

    @Test func clearsAnnotationOverlayWithoutScreenGeometry() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "visible", shape: .rect, x: 200, y: 100, w: 20, h: 20),
        ])))
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))
        try await waitUntil { manager.agentAnnotations.count == 1 }

        manager.applyAgentEvent(.annotationOverlayRequested(PickyAnnotationOverlayRequest(
            id: "annotations-clear",
            mode: .clear,
            annotations: [],
            contextId: nil,
            contextGeneration: nil,
            screenId: nil,
            screenBounds: nil,
            screenshotSize: nil
        )))
        try await waitUntil { manager.agentAnnotations.isEmpty }

        #expect(manager.agentAnnotations.isEmpty)
    }

    @Test func dropsAnnotationOverlayFromAnOlderCaptureGeneration() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "current", shape: .rect, x: 200, y: 100, w: 20, h: 20)],
            contextGeneration: 2
        )))
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))
        try await waitUntil { manager.agentAnnotations.first?.id == "current" }
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "stale", shape: .rect, x: 100, y: 100, w: 20, h: 20)],
            contextGeneration: 1
        )))

        #expect(manager.agentAnnotations.map(\.id) == ["current"])
    }

    @Test func reducerBuffersReplacesAppendsAndClearsAnnotations() {
        let initial = PickyInteractionState()
        let original = resolvedAnnotation(id: "original", expiresAt: now.addingTimeInterval(10), pendingTTL: 6)
        let additional = resolvedAnnotation(id: "additional", expiresAt: now.addingTimeInterval(5), pendingTTL: 6)

        // Replace buffers without showing anything.
        let replaced = reduce(initial, .agentAnnotationsRequested(mode: .replace, annotations: [original, additional]))
        #expect(replaced.agentAnnotations.isEmpty)
        #expect(replaced.pendingAgentAnnotations.map(\.annotation.id) == ["original", "additional"])
        #expect(replaced.overlay == .hidden)

        // Append buffers more.
        let appended = reduce(replaced, .agentAnnotationsRequested(mode: .append, annotations: [
            resolvedAnnotation(id: "third", expiresAt: now, pendingTTL: 6),
        ]))
        #expect(appended.pendingAgentAnnotations.count == 3)

        // Clear drops buffered and shown annotations.
        let cleared = reduce(appended, .agentAnnotationsRequested(mode: .clear, annotations: []))
        #expect(cleared.pendingAgentAnnotations.isEmpty)
        #expect(cleared.agentAnnotations.isEmpty)
    }

    @Test func reducerBoundsBufferedAnnotationsAndClearsThemForCLIInput() {
        let existing = (0..<PickyInteractionReducer.maximumAgentAnnotationCount)
            .map { resolvedAnnotation(id: "existing-\($0)", expiresAt: now.addingTimeInterval(10), pendingTTL: 6) }
        let initial = reduce(PickyInteractionState(), .agentAnnotationsRequested(mode: .replace, annotations: existing))
        let appended = reduce(initial, .agentAnnotationsRequested(mode: .append, annotations: [
            resolvedAnnotation(id: "new", expiresAt: now.addingTimeInterval(10), pendingTTL: 6),
        ]))

        #expect(appended.pendingAgentAnnotations.count == PickyInteractionReducer.maximumAgentAnnotationCount)
        #expect(!appended.pendingAgentAnnotations.contains(where: { $0.annotation.id == "existing-0" }))
        #expect(appended.pendingAgentAnnotations.contains(where: { $0.annotation.id == "new" }))

        let cliContext = PickyContextPacket(
            id: "cli-context",
            source: "cli",
            capturedAt: now,
            transcript: "next",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
        let clearedForCLI = reduce(appended, .externalContextCaptured(inputID: UUID(), text: "next", context: cliContext))
        #expect(clearedForCLI.agentAnnotations.isEmpty)
    }

    @Test func roughGeometryIsStableForAnAnnotationIDAndVariesAcrossIDs() {
        let first = PickyAnnotationRoughGeometry.linePaths(
            id: "save-button",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        )
        let repeated = PickyAnnotationRoughGeometry.linePaths(
            id: "save-button",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        )
        let other = PickyAnnotationRoughGeometry.linePaths(
            id: "cancel-button",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        )

        #expect(first == repeated)
        #expect(first != other)
    }

    @Test func legacyPersistedAnnotationsDecodeWithFallbackVisualStyle() throws {
        let data = """
        {
          "id":"legacy","shape":"label",
          "displayFrame":[[0,0],[100,100]],
          "point":[10,20],"spotlight":false,"label":"Legacy",
          "expiresAt":1800000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PickyAgentAnnotation.self, from: data)

        #expect(decoded.visualStyle == .fallback)
    }

    @Test func paletteFallsBackToOverlayBlueAndLightKeylineWithoutScreenshotSamples() throws {
        let resolved = try PickyAnnotationOverlayResolver.resolve(request(annotations: [
            annotation(id: "fallback", shape: .line, x1: 0, y1: 0, x2: 100, y2: 100),
        ]), sampleGrid: nil, now: now)

        #expect(resolved.first?.visualStyle == .fallback)
        #expect(resolved.first?.visualStyle.palette != .signalMagenta)
    }

    @Test func paletteChoosesVioletOnLightPixelsAndYellowOnDarkPixels() throws {
        let lightGrid = uniformGrid(.init(red: 1, green: 1, blue: 1))
        let darkGrid = uniformGrid(.init(red: 0, green: 0, blue: 0))
        let request = request(annotations: [
            annotation(id: "line", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200),
        ])

        let light = try PickyAnnotationOverlayResolver.resolve(request, sampleGrid: lightGrid, now: now)
        let dark = try PickyAnnotationOverlayResolver.resolve(request, sampleGrid: darkGrid, now: now)

        #expect(light.first?.visualStyle == .init(palette: .brightViolet, keyline: .dark))
        #expect(dark.first?.visualStyle == .init(palette: .signalYellow, keyline: .light))
    }

    @Test func streamedAppendKeepsTheTurnBasePaletteWhenContrastRemainsSufficient() {
        let first = [annotation(id: "first", shape: .line, x1: 0, y1: 0, x2: 100, y2: 100)]
        let second = [annotation(id: "second", shape: .line, x1: 0, y1: 0, x2: 100, y2: 100)]
        let screenshotSize = CGSize(width: 100, height: 100)
        let lightGrid = uniformGrid(.init(red: 1, green: 1, blue: 1))
        let darkGrid = uniformGrid(.init(red: 0, green: 0, blue: 0))
        let basePalette = PickyAnnotationPaletteResolver.basePalette(
            for: first,
            screenshotSize: screenshotSize,
            sampleGrid: lightGrid
        )

        let appendedStyles = PickyAnnotationPaletteResolver.styles(
            for: second,
            screenshotSize: screenshotSize,
            sampleGrid: darkGrid,
            preferredBasePalette: basePalette
        )

        #expect(basePalette == .brightViolet)
        #expect(appendedStyles["second"]?.palette == .brightViolet)
    }

    @Test func lowContrastShapeOverridesTheRequestPaletteWithoutChangingOtherShapes() {
        let white = PickyScreenshotSampleColor(red: 1, green: 1, blue: 1)
        let overlayBlue = PickyAnnotationPaletteRole.fallbackBlue.sampleColor
        let grid = PickyScreenshotColorSampleGrid(
            width: 10,
            height: 10,
            pixels: Array(repeating: white, count: 50) + Array(repeating: overlayBlue, count: 50)
        )!
        let annotations = [
            annotation(id: "light", shape: .line, x1: 0, y1: 0, x2: 400, y2: 0),
            annotation(id: "blue", shape: .line, x1: 0, y1: 200, x2: 400, y2: 200),
        ]

        let styles = PickyAnnotationPaletteResolver.styles(
            for: annotations,
            screenshotSize: CGSize(width: 400, height: 200),
            sampleGrid: grid
        )

        #expect(styles["light"]?.palette == .brightViolet)
        #expect(styles["blue"]?.palette == .signalYellow)
    }

    @Test func duplicateAnnotationIDsDoNotCrashPaletteFallback() {
        let duplicates = [
            annotation(id: "same", shape: .label, x: 10, y: 10, label: "First"),
            annotation(id: "same", shape: .label, x: 20, y: 20, label: "Second"),
        ]

        let styles = PickyAnnotationPaletteResolver.styles(
            for: duplicates,
            screenshotSize: CGSize(width: 100, height: 100),
            sampleGrid: nil
        )

        #expect(styles == ["same": .fallback])
    }

    @Test func pointerRingClampsItsPaintedBoundsInsideTheScreen() {
        let center = PickyHighlightGeometry.clampedTargetCenter(
            CGPoint(x: 0, y: 100),
            targetSize: .zero,
            screenSize: CGSize(width: 100, height: 100)
        )

        #expect(center == CGPoint(x: 16, y: 84))
    }

    @Test func reduceMotionSkipsPointerTravelAndBubbleDelay() {
        #expect(!PickyPointerMotionPolicy.shouldAnimateTravel(reduceMotion: true))
        #expect(!PickyPointerMotionPolicy.shouldAnimateMascot(reduceMotion: true, requested: true))
        #expect(PickyPointerMotionPolicy.bubbleDismissalDelay(reduceMotion: true) == 0)
        #expect(PickyPointerMotionPolicy.shouldAnimateTravel(reduceMotion: false))
        #expect(PickyPointerMotionPolicy.shouldAnimateMascot(reduceMotion: false, requested: true))
        #expect(!PickyPointerMotionPolicy.shouldAnimateMascot(reduceMotion: false, requested: false))
        #expect(PickyPointerMotionPolicy.bubbleDismissalDelay(reduceMotion: false) == DS.Animation.fast)
    }

    @Test func rectLabelsAnchorAboveTheOutlineWithoutLeavingTheScreen() {
        let annotation = PickyAgentAnnotation(
            id: "save-area",
            shape: .rect,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 20, y: 30, width: 40, height: 20),
            label: "Save",
            expiresAt: now
        )
        let labelSize = CGSize(width: 56, height: 26)

        let anchor = PickyAnnotationLabelGeometry.outlineAnchor(
            for: annotation,
            screenFrame: annotation.displayFrame,
            labelSize: labelSize
        )

        #expect(anchor == CGPoint(x: 48, y: 29))
        #expect(labelBounds(center: anchor!, size: labelSize).minX >= 0)
    }

    @Test func rectLabelsFallBackBelowWhenTooCloseToTheTop() {
        let annotation = PickyAgentAnnotation(
            id: "top-rect",
            shape: .rect,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 20, y: 90, width: 30, height: 8),
            label: "Top",
            expiresAt: now
        )
        let labelSize = CGSize(width: 47, height: 26)

        let anchor = PickyAnnotationLabelGeometry.outlineAnchor(
            for: annotation,
            screenFrame: annotation.displayFrame,
            labelSize: labelSize
        )

        #expect(anchor == CGPoint(x: 26.5, y: 31))
        #expect(labelBounds(center: anchor!, size: labelSize).minY >= 0)
    }

    @Test func lineLabelsAnchorLeftOfTheLineWhenThereIsRoom() {
        let annotation = PickyAgentAnnotation(
            id: "line-room",
            shape: .line,
            displayFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
            point: CGPoint(x: 80, y: 50),
            endPoint: CGPoint(x: 150, y: 50),
            label: "Flow",
            expiresAt: now
        )

        let anchor = PickyAnnotationLabelGeometry.outlineAnchor(
            for: annotation,
            screenFrame: annotation.displayFrame,
            labelSize: CGSize(width: 56, height: 26)
        )

        #expect(anchor == CGPoint(x: 44, y: 50))
    }

    @Test func lineLabelsUseAnotherSideInsteadOfClippingAtTheRightEdge() {
        let annotation = PickyAgentAnnotation(
            id: "line-cramped",
            shape: .line,
            displayFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
            point: CGPoint(x: 10, y: 50),
            endPoint: CGPoint(x: 150, y: 50),
            label: "Edge",
            expiresAt: now
        )
        let labelSize = CGSize(width: 56, height: 26)

        let anchor = PickyAnnotationLabelGeometry.outlineAnchor(
            for: annotation,
            screenFrame: annotation.displayFrame,
            labelSize: labelSize
        )

        #expect(anchor == CGPoint(x: 80, y: 29))
        #expect(labelBounds(center: anchor!, size: labelSize).maxX <= annotation.displayFrame.width)
    }

    @Test func standaloneAndOversizedLabelsClampInsideTheScreen() {
        let screenSize = CGSize(width: 100, height: 100)
        let boundedSize = PickyAnnotationLabelGeometry.boundedLabelSize(
            measuredSize: CGSize(width: 180, height: 30),
            screenSize: screenSize
        )
        let anchor = PickyAnnotationLabelGeometry.clampedAnchor(
            preferred: CGPoint(x: 2, y: 98),
            screenSize: screenSize,
            labelSize: boundedSize
        )

        #expect(boundedSize == CGSize(width: 80, height: 30))
        #expect(anchor == CGPoint(x: 42, y: 83))
        let paintedBounds = labelBounds(center: anchor, size: boundedSize).insetBy(dx: -2, dy: -2)
        #expect(paintedBounds.minX >= 0 && paintedBounds.maxX <= screenSize.width)
        #expect(paintedBounds.minY >= 0 && paintedBounds.maxY <= screenSize.height)
    }

    @Test func spotlightMaskUsesShapeMatchedHolesAndOmitsPlainAnnotations() {
        let screenFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let annotations = [
            PickyAgentAnnotation(
                id: "rect-hole",
                shape: .rect,
                displayFrame: screenFrame,
                rect: CGRect(x: 60, y: 30, width: 20, height: 10),
                spotlight: true,
                label: nil,
                expiresAt: now
            ),
            PickyAgentAnnotation(
                id: "line-hole",
                shape: .line,
                displayFrame: screenFrame,
                point: CGPoint(x: 20, y: 20),
                endPoint: CGPoint(x: 40, y: 50),
                spotlight: true,
                label: nil,
                expiresAt: now
            ),
            PickyAgentAnnotation(
                id: "plain-rect",
                shape: .rect,
                displayFrame: screenFrame,
                rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                label: nil,
                expiresAt: now
            ),
        ]

        let holes = PickyAnnotationSpotlightMaskGeometry.holes(for: annotations, screenFrame: screenFrame)

        #expect(holes == [
            .roundedRect(CGRect(x: 52, y: 52, width: 36, height: 26), cornerRadius: 6),
            .rect(CGRect(x: 8, y: 38, width: 44, height: 54)),
        ])
        #expect(PickyAnnotationSpotlightMaskGeometry.holes(for: [annotations[2]], screenFrame: screenFrame).isEmpty)
        #expect(PickyAnnotationSpotlightMaskGeometry.dimmingOpacity == 0.38)
    }

    @Test func decodesAnnotationOverlayProtocolEvent() throws {
        let json = """
        {
          "id":"event-annotations-001",
          "protocolVersion":"2026-07-17",
          "timestamp":"2026-07-17T00:00:00.000Z",
          "type":"annotationOverlayRequested",
          "request":{
            "id":"annotations-001","mode":"append","annotations":[{"id":"line-1","shape":"line","x1":0,"y1":0,"x2":10,"y2":10,"spotlight":true}],
            "screenBounds":{"x":0,"y":0,"width":100,"height":100},"screenshotSize":{"width":100,"height":100}
          }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: json)
        guard case .annotationOverlayRequested(let eventRequest) = envelope.event else {
            Issue.record("Expected annotationOverlayRequested")
            return
        }
        #expect(eventRequest.mode == .append)
        #expect(eventRequest.annotations.first?.shape == .line)
        #expect(eventRequest.annotations.first?.spotlight == true)
    }

    private func overlayContext(sampleGrid: PickyScreenshotColorSampleGrid) -> PickyContextPacket {
        PickyContextPacket(
            id: "context",
            source: "cli",
            capturedAt: now,
            transcript: "show me",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [PickyScreenshotContext(
                id: "shot-1",
                label: "primary",
                path: "/tmp/unused.jpg",
                screenId: "screen",
                bounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
                screenshotWidthInPixels: 400,
                screenshotHeightInPixels: 200,
                isCursorScreen: true,
                annotationColorSampleGrid: sampleGrid
            )],
            warnings: []
        )
    }

    private func uniformGrid(_ color: PickyScreenshotSampleColor) -> PickyScreenshotColorSampleGrid {
        PickyScreenshotColorSampleGrid(width: 4, height: 4, pixels: Array(repeating: color, count: 16))!
    }

    private func labelBounds(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !predicate() {
            guard Date() < deadline else {
                throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: "test", field: "projection timeout")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func reduce(_ state: PickyInteractionState, _ event: PickyInteractionEvent) -> PickyInteractionState {
        PickyInteractionReducer.reduce(
            state: state,
            envelope: PickyInteractionEnvelope(id: UUID(), occurredAt: now, event: event, correlation: .init(source: .agent))
        ).state
    }

    private func request(
        annotations: [PickyAnnotationOverlayAnnotation],
        mode: PickyAnnotationOverlayMode = .replace,
        contextGeneration: Int? = nil
    ) -> PickyAnnotationOverlayRequest {
        PickyAnnotationOverlayRequest(
            id: "annotations-request",
            mode: mode,
            annotations: annotations,
            contextId: "context",
            contextGeneration: contextGeneration,
            screenId: "screen",
            screenBounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 400, height: 200)
        )
    }

    private func annotation(
        id: String,
        shape: PickyAnnotationOverlayShape,
        x: Double? = nil, y: Double? = nil,
        w: Double? = nil, h: Double? = nil, x1: Double? = nil, y1: Double? = nil, x2: Double? = nil, y2: Double? = nil,
        spotlight: Bool? = nil, label: String? = nil
    ) -> PickyAnnotationOverlayAnnotation {
        PickyAnnotationOverlayAnnotation(id: id, shape: shape, x: x, y: y, w: w, h: h, x1: x1, y1: y1, x2: x2, y2: y2, spotlight: spotlight, label: label, ttlMs: nil, clamped: nil)
    }

    private func resolvedAnnotation(id: String, expiresAt: Date, pendingTTL: TimeInterval? = nil) -> PickyAgentAnnotation {
        PickyAgentAnnotation(id: id, shape: .rect, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rect: CGRect(x: 40, y: 40, width: 20, height: 20), label: nil, expiresAt: expiresAt, pendingTTL: pendingTTL)
    }
}
