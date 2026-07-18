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
            annotation(id: "line", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200, spotlight: false, label: " Save "),
        ]))

        #expect(resolved.first { $0.id == "rect" }?.rect == CGRect(x: 200, y: 225, width: 50, height: 50))
        #expect(resolved.first { $0.id == "rect" }?.spotlight == true)
        #expect(resolved.first { $0.id == "line" }?.point == CGPoint(x: 100, y: 300))
        #expect(resolved.first { $0.id == "line" }?.endPoint == CGPoint(x: 300, y: 200))
        #expect(resolved.first { $0.id == "line" }?.spotlight == false)
        #expect(resolved.first { $0.id == "line" }?.label == "Save")
    }

    @Test func bufferedAnnotationsRemainVisibleAfterTheFinalTTSUtteranceDrains() {
        let annotation = resolvedAnnotation(id: "a")
        let buffered = reduce(PickyInteractionState(), .agentAnnotationsRequested(mode: .append, annotations: [annotation]))
        #expect(buffered.agentAnnotations.isEmpty)
        #expect(buffered.pendingAgentAnnotations.count == 1)

        let speechID = UUID()
        var speaking = reduce(buffered, .speechStarted(text: "Look here.", speechID: speechID, sourceContextID: "context"))
        speaking.output = .speaking(
            contextID: "context",
            speechID: speechID,
            text: "Look here.",
            minimumDisplayTimerID: nil,
            minimumDisplayUntil: nil,
            finishPending: false
        )
        let pendingID = speaking.pendingAgentAnnotations.first!.id
        let revealed = reduce(speaking, .agentAnnotationRevealDue(id: pendingID))
        #expect(revealed.agentAnnotations.map(\.id) == ["a"])

        let settled = reduce(revealed, .mainTurnSettled(contextID: "context"))
        #expect(settled.agentAnnotations.map(\.id) == ["a"])

        let drained = reduce(settled, .speechFinished(speechID: speechID))
        #expect(drained.agentAnnotations.map(\.id) == ["a"])
        #expect(drained.pendingAgentAnnotations.isEmpty)
    }

    @Test func sceneValidationSuspendsWithoutDiscardingAndRestoresOnlyMatchingIdentity() {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 3,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        )
        let staleIdentity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 2,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
        )
        var state = reduce(PickyInteractionState(), .agentAnnotationScenePrepared(identity: identity))
        state = reduce(state, .agentAnnotationsRequested(mode: .append, annotations: [resolvedAnnotation(id: "a")]))
        let speechID = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
        state = reduce(state, .speechStarted(text: "Look here.", speechID: speechID, sourceContextID: "context"))
        state.output = .speaking(
            contextID: "context",
            speechID: speechID,
            text: "Look here.",
            minimumDisplayTimerID: nil,
            minimumDisplayUntil: nil,
            finishPending: false
        )
        let pendingID = state.pendingAgentAnnotations.first!.id
        state = reduce(state, .agentAnnotationRevealDue(id: pendingID))

        #expect(state.annotationScenePhase == .validating)
        #expect(state.agentAnnotations.map(\.id) == ["a"])
        #expect(PickyInteractionProjection(state: state).agentAnnotations.isEmpty)

        state = reduce(state, .agentAnnotationSceneMatched(identity: identity))
        #expect(state.annotationScenePhase == .visible)
        #expect(PickyInteractionProjection(state: state).agentAnnotations.map(\.id) == ["a"])

        state = reduce(state, .agentAnnotationSceneMismatched(identity: identity, reason: .visual))
        #expect(state.annotationScenePhase == .suspended)
        #expect(state.agentAnnotations.map(\.id) == ["a"])
        #expect(PickyInteractionProjection(state: state).agentAnnotations.isEmpty)

        state = reduce(state, .agentAnnotationSceneMatched(identity: staleIdentity))
        #expect(state.annotationScenePhase == .suspended)
        #expect(PickyInteractionProjection(state: state).agentAnnotations.isEmpty)

        state = reduce(state, .agentAnnotationSceneMatched(identity: identity))
        #expect(state.annotationScenePhase == .visible)
        #expect(PickyInteractionProjection(state: state).agentAnnotations.map(\.id) == ["a"])
    }

    @Test func companionManagerKeepsSilentAnnotationsWhenTheTurnSettles() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        let sequenceBeforeEvent = manager.interactionProjectionSequence
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "manager-rect", shape: .rect, x: 200, y: 100, w: 40, h: 20),
        ])))
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))

        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeEvent }
        #expect(manager.agentAnnotations.map(\.id) == ["manager-rect"])
    }

    @Test func companionManagerPermanentlyClearsSettledAnnotationsOnSceneMismatch() async throws {
        let baselineFingerprint = PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 64, count: 100)
        )!
        let changedFingerprint = PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 255, count: 100)
        )!
        let capturer = ManagerAnnotationSceneCapturer(
            baseline: baselineFingerprint,
            current: [
                baselineFingerprint, baselineFingerprint,
                changedFingerprint, changedFingerprint,
                baselineFingerprint, baselineFingerprint,
            ]
        )
        let monitor = PickyAnnotationSceneMonitor(
            capturer: capturer,
            semanticProvider: ManagerAnnotationSceneSemanticProvider(),
            automaticallySchedulesSamples: false
        )
        let manager = CompanionManager(
            agentClient: FakePickyAgentClient(),
            annotationSceneMonitor: monitor
        )
        manager.noteExternalSubmission(
            kind: .submitMain,
            text: "show it",
            context: sceneContext()
        )
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "manager-rect", shape: .rect, x: 200, y: 100, w: 40, h: 20)],
            contextGeneration: 1
        )))
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))

        await monitor.sampleNow()
        await monitor.sampleNow()
        try await waitUntil { manager.agentAnnotations.map(\.id) == ["manager-rect"] }

        await monitor.sampleNow()
        await monitor.sampleNow()
        try await waitUntil { manager.agentAnnotations.isEmpty }

        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(manager.agentAnnotations.isEmpty)
        manager.stop()
    }

    @Test func resolverUsesActionBlueOnOrdinaryLightAndDarkScreens() throws {
        let request = request(annotations: [
            annotation(id: "adaptive", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200),
        ])
        let light = try PickyAnnotationOverlayResolver.resolve(
            request,
            sampleGrid: uniformGrid(.init(red: 1, green: 1, blue: 1))
        )
        let dark = try PickyAnnotationOverlayResolver.resolve(
            request,
            sampleGrid: uniformGrid(.init(red: 0, green: 0, blue: 0))
        )

        #expect(light.first?.visualStyle.palette == .actionBlue)
        #expect(dark.first?.visualStyle.palette == .actionBlue)
    }

    @Test func clearsBufferedAnnotationOverlayWithoutScreenGeometry() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "buffered", shape: .rect, x: 200, y: 100, w: 20, h: 20),
        ])))
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
        let sequenceBeforeEvent = manager.interactionProjectionSequence
        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "current", shape: .rect, x: 200, y: 100, w: 20, h: 20)],
            contextGeneration: 2
        )))
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeEvent }
        let sequenceAfterCurrent = manager.interactionProjectionSequence

        manager.applyAgentEvent(.annotationOverlayRequested(request(
            annotations: [annotation(id: "stale", shape: .rect, x: 100, y: 100, w: 20, h: 20)],
            contextGeneration: 1
        )))

        #expect(manager.interactionProjectionSequence == sequenceAfterCurrent)
    }

    @Test func reducerBuffersReplacesAppendsAndClearsAnnotations() {
        let initial = PickyInteractionState()
        let original = resolvedAnnotation(id: "original")
        let additional = resolvedAnnotation(id: "additional")

        // Replace buffers without showing anything.
        let replaced = reduce(initial, .agentAnnotationsRequested(mode: .replace, annotations: [original, additional]))
        #expect(replaced.agentAnnotations.isEmpty)
        #expect(replaced.pendingAgentAnnotations.map(\.annotation.id) == ["original", "additional"])
        #expect(replaced.overlay == .hidden)

        // Append buffers more.
        let appended = reduce(replaced, .agentAnnotationsRequested(mode: .append, annotations: [
            resolvedAnnotation(id: "third"),
        ]))
        #expect(appended.pendingAgentAnnotations.count == 3)

        // Clear drops buffered and shown annotations.
        let cleared = reduce(appended, .agentAnnotationsRequested(mode: .clear, annotations: []))
        #expect(cleared.pendingAgentAnnotations.isEmpty)
        #expect(cleared.agentAnnotations.isEmpty)
    }

    @Test func reducerBoundsBufferedAnnotationsAndClearsThemForCLIInput() {
        let existing = (0..<PickyInteractionReducer.maximumAgentAnnotationCount)
            .map { resolvedAnnotation(id: "existing-\($0)") }
        let initial = reduce(PickyInteractionState(), .agentAnnotationsRequested(mode: .replace, annotations: existing))
        let appended = reduce(initial, .agentAnnotationsRequested(mode: .append, annotations: [
            resolvedAnnotation(id: "new"),
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

    @Test func roughLinesAndRectangleEdgesUseTwoDistinctPasses() {
        let linePaths = PickyAnnotationRoughGeometry.linePaths(
            id: "line",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        )
        let rectanglePaths = PickyAnnotationRoughGeometry.rectanglePaths(
            id: "rect",
            rect: CGRect(x: 20, y: 30, width: 80, height: 50)
        )

        #expect(linePaths.count == 2)
        #expect(linePaths.allSatisfy { $0.commands.count == 3 })
        #expect(linePaths[0] != linePaths[1])
        #expect(rectanglePaths.count == 8)
        #expect(rectanglePaths.allSatisfy { $0.commands.count == 3 })
        #expect(rectanglePaths[0] != rectanglePaths[4])
    }

    @Test func roughRectanglePassesFollowThePerimeterInOrder() throws {
        let rect = CGRect(x: 20, y: 30, width: 80, height: 50)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        let paths = PickyAnnotationRoughGeometry.rectanglePaths(id: "ordered-rect", rect: rect)

        for (index, path) in paths.enumerated() {
            let edge = index % corners.count
            let start = try #require(roughPathStart(path))
            let end = try #require(roughPathEnd(path))
            #expect(distance(start, corners[edge]) < 3)
            #expect(distance(end, corners[(edge + 1) % corners.count]) < 3)
        }
    }

    @Test func roughGeometryStaysInsideABoundedSketchEnvelope() {
        let lineBounds = CGRect(x: 10, y: 20, width: 80, height: 60).insetBy(dx: -4, dy: -4)
        let rectangleBounds = CGRect(x: 20, y: 30, width: 80, height: 50).insetBy(dx: -4, dy: -4)
        let linePoints = roughPathPoints(PickyAnnotationRoughGeometry.linePaths(
            id: "bounded-line",
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 90, y: 80)
        ))
        let rectanglePoints = roughPathPoints(PickyAnnotationRoughGeometry.rectanglePaths(
            id: "bounded-rect",
            rect: CGRect(x: 20, y: 30, width: 80, height: 50)
        ))

        #expect(linePoints.allSatisfy(lineBounds.contains))
        #expect(rectanglePoints.allSatisfy(rectangleBounds.contains))
    }

    @Test func persistedAnnotationsDecodeWithFallbackVisualStyle() throws {
        let data = """
        {
          "id":"persisted","shape":"rect",
          "displayFrame":[[0,0],[100,100]],
          "spotlight":false,"label":"Area"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PickyAgentAnnotation.self, from: data)

        #expect(decoded.visualStyle == .fallback)
    }

    @Test func paletteFallsBackToOverlayBlueAndLightKeylineWithoutScreenshotSamples() throws {
        let resolved = try PickyAnnotationOverlayResolver.resolve(request(annotations: [
            annotation(id: "fallback", shape: .line, x1: 0, y1: 0, x2: 100, y2: 100),
        ]), sampleGrid: nil)

        #expect(resolved.first?.visualStyle == .fallback)
    }

    @Test func paletteKeepsActionBlueOnLightAndDarkPixels() throws {
        let lightGrid = uniformGrid(.init(red: 1, green: 1, blue: 1))
        let darkGrid = uniformGrid(.init(red: 0, green: 0, blue: 0))
        let request = request(annotations: [
            annotation(id: "line", shape: .line, x1: 0, y1: 0, x2: 400, y2: 200),
        ])

        let light = try PickyAnnotationOverlayResolver.resolve(request, sampleGrid: lightGrid)
        let dark = try PickyAnnotationOverlayResolver.resolve(request, sampleGrid: darkGrid)

        #expect(light.first?.visualStyle == .init(palette: .actionBlue, keyline: .dark))
        #expect(dark.first?.visualStyle == .init(palette: .actionBlue, keyline: .light))
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

        #expect(basePalette == .actionBlue)
        #expect(appendedStyles["second"]?.palette == .actionBlue)
    }

    @Test func lowContrastShapeOverridesTheRequestPaletteWithoutChangingOtherShapes() {
        let white = PickyScreenshotSampleColor(red: 1, green: 1, blue: 1)
        let overlayBlue = PickyAnnotationPaletteRole.actionBlue.sampleColor
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

        #expect(styles["light"]?.palette == .actionBlue)
        #expect(styles["blue"]?.palette != .actionBlue)
    }

    @Test func duplicateAnnotationIDsDoNotCrashPaletteFallback() {
        let duplicates = [
            annotation(id: "same", shape: .line, x1: 0, y1: 0, x2: 10, y2: 10, label: "First"),
            annotation(id: "same", shape: .line, x1: 10, y1: 10, x2: 20, y2: 20, label: "Second"),
        ]

        let styles = PickyAnnotationPaletteResolver.styles(
            for: duplicates,
            screenshotSize: CGSize(width: 100, height: 100),
            sampleGrid: nil
        )

        #expect(styles == ["same": .fallback])
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
            label: "Save"
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
            label: "Top"
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
            label: "Flow"
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
            label: "Edge"
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

    @Test func oversizedShapeLabelsClampInsideTheScreen() {
        #expect(PickyAnnotationLabelGeometry.boundedLabelSize(
            measuredSize: CGSize(width: 800, height: 30),
            screenSize: CGSize(width: 1_000, height: 500)
        ).width == PickyAnnotationLabelGeometry.maximumLabelWidth)

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

        #expect(boundedSize == CGSize(width: 84, height: 30))
        #expect(anchor == CGPoint(x: 42, y: 85))
        let bounds = labelBounds(center: anchor, size: boundedSize)
        #expect(bounds.minX >= 0 && bounds.maxX <= screenSize.width)
        #expect(bounds.minY >= 0 && bounds.maxY <= screenSize.height)
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
                label: nil
            ),
            PickyAgentAnnotation(
                id: "line-hole",
                shape: .line,
                displayFrame: screenFrame,
                point: CGPoint(x: 20, y: 20),
                endPoint: CGPoint(x: 40, y: 50),
                spotlight: true,
                label: nil
            ),
            PickyAgentAnnotation(
                id: "plain-rect",
                shape: .rect,
                displayFrame: screenFrame,
                rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                label: nil
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

    private func sceneContext() -> PickyContextPacket {
        PickyContextPacket(
            id: "context",
            source: "cli",
            capturedAt: now,
            transcript: "show it",
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [
                PickyScreenshotContext(
                    id: "shot-1",
                    label: "screen",
                    path: "/tmp/not-read-by-fake.jpg",
                    screenId: "screen",
                    bounds: PickyCGRect(x: 100, y: 200, width: 200, height: 100),
                    screenshotWidthInPixels: 400,
                    screenshotHeightInPixels: 200
                ),
            ],
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

    private func roughPathStart(_ path: PickyRoughPath) -> CGPoint? {
        guard case .move(let point) = path.commands.first else { return nil }
        return point
    }

    private func roughPathEnd(_ path: PickyRoughPath) -> CGPoint? {
        for command in path.commands.reversed() {
            switch command {
            case .move(let point), .line(let point), .curve(to: let point, control1: _, control2: _):
                return point
            case .close:
                continue
            }
        }
        return nil
    }

    private func roughPathPoints(_ paths: [PickyRoughPath]) -> [CGPoint] {
        paths.flatMap { path in
            path.commands.flatMap { command -> [CGPoint] in
                switch command {
                case .move(let point), .line(let point):
                    return [point]
                case .curve(to: let point, control1: let control1, control2: let control2):
                    return [point, control1, control2]
                case .close:
                    return []
                }
            }
        }
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
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
        PickyAnnotationOverlayAnnotation(id: id, shape: shape, x: x, y: y, w: w, h: h, x1: x1, y1: y1, x2: x2, y2: y2, spotlight: spotlight, label: label, clamped: nil)
    }

    private func resolvedAnnotation(id: String) -> PickyAgentAnnotation {
        PickyAgentAnnotation(id: id, shape: .rect, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rect: CGRect(x: 40, y: 40, width: 20, height: 20), label: nil)
    }
}

@MainActor
private final class ManagerAnnotationSceneCapturer: PickyAnnotationSceneSnapshotCapturing {
    let baseline: PickyAnnotationSceneFingerprint
    var current: [PickyAnnotationSceneFingerprint]

    init(baseline: PickyAnnotationSceneFingerprint, current: [PickyAnnotationSceneFingerprint]) {
        self.baseline = baseline
        self.current = current
    }

    func baselineFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        baseline
    }

    func currentFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        guard !current.isEmpty else { throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed }
        return current.removeFirst()
    }

    func reset() {}
}

@MainActor
private final class ManagerAnnotationSceneSemanticProvider: PickyAnnotationSceneSemanticProviding {
    func mismatchReason(for baseline: PickyAnnotationSceneBaseline) -> PickyAnnotationSceneMismatchReason? {
        nil
    }
}
