import AppKit
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

    @Test func resolvesPATHCommandsAndUsesArcLengthMidpointForPointerGuidance() throws {
        let commands = [
            PickyAnnotationPathCommand(type: .move, x: 0, y: 0),
            PickyAnnotationPathCommand(type: .line, x: 200, y: 100),
            PickyAnnotationPathCommand(type: .cubic, x: 400, y: 200, c1x: 240, c1y: 120, c2x: 360, c2y: 180),
        ]
        let resolved = try #require(PickyAnnotationOverlayResolver.resolve(request(annotations: [
            annotation(id: "path", shape: .path, commands: commands, label: "Trend"),
        ])).first)

        #expect(resolved.pathCommands == [
            .move(CGPoint(x: 100, y: 300)),
            .line(CGPoint(x: 200, y: 250)),
            .cubic(
                to: CGPoint(x: 300, y: 200),
                control1: CGPoint(x: 220, y: 240),
                control2: CGPoint(x: 280, y: 210)
            ),
        ])
        #expect(resolved.spotlight == false)
        #expect(resolved.label == "Trend")

        let target = try #require(PickyAnnotationPointerTarget.make(resolved))
        #expect(resolved.displayFrame.contains(target.screenLocation))
        #expect(target.screenLocation.x > 190)
        #expect(target.screenLocation.x < 210)
    }

    @Test func resolvesTextCalloutsAndRejectsEmptyText() throws {
        let resolved = try #require(PickyAnnotationOverlayResolver.resolve(request(annotations: [
            annotation(id: "text", shape: .text, x: 200, y: 50, w: 100, h: 100, text: "  번역  "),
        ])).first)
        #expect(resolved.rect == CGRect(x: 200, y: 225, width: 50, height: 50))
        #expect(resolved.text == "번역")
        #expect(resolved.label == nil)

        #expect(throws: PickyAnnotationOverlayResolveError.self) {
            _ = try PickyAnnotationOverlayResolver.resolve(request(annotations: [
                annotation(id: "empty", shape: .text, x: 0, y: 0, w: 10, h: 10, text: "   "),
            ]))
        }
    }

    @Test func rejectsPATHSpotlightInTheSwiftResolver() {
        #expect(throws: PickyAnnotationOverlayResolveError.self) {
            _ = try PickyAnnotationOverlayResolver.resolve(request(annotations: [
                annotation(
                    id: "path",
                    shape: .path,
                    commands: [
                        PickyAnnotationPathCommand(type: .move, x: 0, y: 0),
                        PickyAnnotationPathCommand(type: .line, x: 10, y: 10),
                    ],
                    spotlight: true
                ),
            ]))
        }
    }

    @Test func bufferedAnnotationsRemainVisibleWithoutSpotlightAfterTheFinalTTSUtteranceDrains() {
        let annotation = resolvedAnnotation(id: "a", spotlight: true)
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
        #expect(revealed.agentAnnotations.first?.spotlight == true)
        #expect(!PickyInteractionProjection(state: revealed).showsAgentAnnotationDismissControl)

        let settled = reduce(revealed, .mainTurnSettled(contextID: "context"))
        #expect(settled.agentAnnotations.map(\.id) == ["a"])
        #expect(!PickyInteractionProjection(state: settled).showsAgentAnnotationDismissControl)

        let drained = reduce(settled, .speechFinished(speechID: speechID))
        #expect(drained.agentAnnotations.map(\.id) == ["a"])
        #expect(drained.agentAnnotations.first?.rect == annotation.rect)
        #expect(drained.agentAnnotations.first?.spotlight == false)
        #expect(drained.pendingAgentAnnotations.isEmpty)
        #expect(PickyInteractionProjection(state: drained).showsAgentAnnotationDismissControl)
    }

    @Test func silentAnnotationKeepsSpotlightWhenTheTurnSettlesWithoutTTS() {
        let annotation = resolvedAnnotation(id: "a", spotlight: true)
        let buffered = reduce(PickyInteractionState(), .agentAnnotationsRequested(mode: .append, annotations: [annotation]))

        let settled = reduce(buffered, .mainTurnSettled(contextID: "context"))

        #expect(settled.agentAnnotations.map(\.id) == ["a"])
        #expect(settled.agentAnnotations.first?.spotlight == true)
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

    @Test func companionManagerKeepsAndCanDismissSilentAnnotationsWhenTheTurnSettles() async throws {
        let manager = CompanionManager(agentClient: FakePickyAgentClient())
        let sequenceBeforeEvent = manager.interactionProjectionSequence
        manager.applyAgentEvent(.annotationOverlayRequested(request(annotations: [
            annotation(id: "manager-rect", shape: .rect, x: 200, y: 100, w: 40, h: 20),
        ])))
        manager.applyAgentEvent(.mainTurnSettled(contextId: "context"))

        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeEvent }
        #expect(manager.agentAnnotations.map(\.id) == ["manager-rect"])
        #expect(manager.showsAgentAnnotationDismissControl)

        let sequenceBeforeDismiss = manager.interactionProjectionSequence
        manager.dismissAgentAnnotations()
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeDismiss }

        #expect(manager.agentAnnotations.isEmpty)
        #expect(!manager.showsAgentAnnotationDismissControl)
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

    @Test func roughPATHGeometryUsesTwoStableDistinctPasses() {
        let commands: [PickyAgentAnnotationPathCommand] = [
            .move(CGPoint(x: 10, y: 20)),
            .line(CGPoint(x: 30, y: 40)),
            .cubic(
                to: CGPoint(x: 90, y: 100),
                control1: CGPoint(x: 50, y: 60),
                control2: CGPoint(x: 70, y: 80)
            ),
        ]
        let first = PickyAnnotationRoughGeometry.pathPaths(id: "path", commands: commands)
        let repeated = PickyAnnotationRoughGeometry.pathPaths(id: "path", commands: commands)

        #expect(first == repeated)
        #expect(first.count == 2)
        #expect(first[0] != first[1])
        #expect(first.allSatisfy { $0.commands.count == commands.count })
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

    @Test func dismissPanelTargetsOnlyScreensContainingVisibleAnnotations() {
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]
        let annotations = [
            PickyAgentAnnotation(
                id: "first-screen",
                shape: .rect,
                displayFrame: screenFrames[0],
                rect: CGRect(x: 20, y: 20, width: 20, height: 20),
                label: nil
            ),
            PickyAgentAnnotation(
                id: "second-screen",
                shape: .rect,
                displayFrame: screenFrames[1],
                rect: CGRect(x: 120, y: 20, width: 20, height: 20),
                label: nil
            ),
        ]

        #expect(PickyAnnotationDismissPanelLayout.targetScreenIndexes(
            screenFrames: screenFrames,
            annotations: annotations
        ) == [0, 1])
    }

    @Test func dismissPanelFrameUsesTheLowerCenter() {
        let visibleFrame = CGRect(x: 40, y: 20, width: 1_200, height: 800)

        let frame = PickyAnnotationDismissPanelLayout.panelFrame(visibleFrame: visibleFrame)

        #expect(frame.size == PickyAnnotationDismissPanelLayout.panelSize)
        #expect(frame.midX == visibleFrame.midX)
        let expectedCenterY = visibleFrame.minY
            + visibleFrame.height * (1 - PickyAnnotationDismissPanelLayout.verticalPositionFromTop)
        #expect(frame.midY == expectedCenterY)
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
          "protocolVersion":"2026-07-23",
          "timestamp":"2026-07-19T00:00:00.000Z",
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

    /// A long caption at the bottom edge has no clean slot: below is clamped
    /// back over itself, the sides are clamped inward over itself, and the only
    /// slot that clears the caption collides with another marked line. The
    /// callout must still never land on the text it explains.
    @Test func crowdedTextCalloutsNeverCoverTheTextTheyExplain() throws {
        let screenSize = CGSize(width: 600, height: 300)
        let items = [
            (
                "caption",
                CGRect(x: 160, y: 262, width: 260, height: 22),
                "이 금액은 부가세를 포함한 값이며 결제일 환율에 따라 최종 청구액이 달라질 수 있습니다"
            ),
            ("total", CGRect(x: 180, y: 200, width: 240, height: 24), "결제 수단 관리"),
            ("title", CGRect(x: 24, y: 28, width: 180, height: 18), "계속하려면 로그인하세요"),
            ("help", CGRect(x: 240, y: 26, width: 160, height: 18), "비밀번호를 잊으셨나요?"),
            ("signup", CGRect(x: 430, y: 118, width: 150, height: 20), "새 계정 만들기"),
        ].map { PickyAnnotationTextItem(id: $0.0, rect: $0.1, text: $0.2, visualStyle: .fallback) }

        let layouts = PickyAnnotationTextLayoutPolicy.layout(items, screenSize: screenSize)

        #expect(layouts.count == items.count)
        for item in items {
            let frame = try #require(layouts[item.id]?.frame)
            #expect(!frame.intersects(item.rect), "Callout \(item.id) covers its own text")
            #expect(CGRect(origin: .zero, size: screenSize).contains(frame), "Callout \(item.id) left the screen")
            // The bottom-edge caption is the one item boxed in on every side:
            // its own bubble is taller than the gap between "total" and itself,
            // and bubbles stay next to the text they explain rather than flying
            // to free space elsewhere on the screen. Every other item has a slot
            // that clears the remaining marked text.
            guard item.id != "caption" else { continue }
            for other in items where other.id != item.id {
                #expect(!frame.intersects(other.rect), "Callout \(item.id) covers the text of \(other.id)")
            }
        }
    }

    @Test func calloutShowsWholeTextAndWidensWithinTheCap() {
        let font = PickyAnnotationTextLayoutPolicy.calloutFont
        let padding = PickyAnnotationTextLayoutPolicy.calloutHorizontalPadding
        let vertical = PickyAnnotationTextLayoutPolicy.calloutVerticalPadding
        func fullHeight(_ text: String, bubbleWidth: CGFloat) -> CGFloat {
            PickyAnnotationTextLayoutPolicy.measure(
                text, font: font, width: bubbleWidth - padding * 2 - PickyAnnotationTextLayoutPolicy.calloutWrapSlack
            ).height
        }

        // 500 characters, the TEXT limit, on a wide screen under a wide paragraph.
        let long = String(repeating: "캐시된 문서를 다시 검사해서 바뀐 스키마를 반영해요. ", count: 17).prefix(500)
        let wide = PickyAnnotationTextLayoutPolicy.calloutBodySize(text: String(long), anchorWidth: 900, screenWidth: 1440)
        #expect(wide.width <= PickyAnnotationTextLayoutPolicy.calloutMaxWidth)
        #expect(wide.width > 500, "a long translation uses the width cap instead of a narrow column")
        #expect(wide.height >= fullHeight(String(long), bubbleWidth: wide.width) + vertical * 2, "no line is cut off")

        // Same text under a narrow label still widens rather than growing past six lines first.
        let narrowAnchor = PickyAnnotationTextLayoutPolicy.calloutBodySize(text: String(long), anchorWidth: 80, screenWidth: 1440)
        #expect(narrowAnchor.width > PickyAnnotationTextLayoutPolicy.calloutMinWrapWidth)

        // Short text hugs its content; small screens cap the width.
        let short = PickyAnnotationTextLayoutPolicy.calloutBodySize(text: "로그인", anchorWidth: 600, screenWidth: 1440)
        #expect(short.width < 120)
        let small = PickyAnnotationTextLayoutPolicy.calloutBodySize(text: String(long), anchorWidth: 900, screenWidth: 400)
        #expect(small.width <= 400 - PickyAnnotationTextLayoutPolicy.calloutScreenMargin * 2)
    }

    /// Mirrors the marketing-page fixture rendered by the messenger-UX gallery
    /// (`PickyMessengerUXRenderGalleryTests`, 720x400). The long body paragraph
    /// wants the empty band under itself, which is exactly where the CTA button
    /// label and its badge sit; neither may end up under a bubble.
    @Test func galleryTranslationFixtureKeepsEveryMarkedTextReadable() throws {
        let screenSize = CGSize(width: 720, height: 400)
        let items = [
            ("nav", CGRect(x: 470, y: 18, width: 220, height: 18), "요금    문서    로그인"),
            ("title", CGRect(x: 40, y: 92, width: 520, height: 36), "회의는 줄이고 더 빨리 출시하세요"),
            (
                "body",
                CGRect(x: 40, y: 142, width: 420, height: 40),
                "비동기 스탠드업, 결정 기록, 리뷰 대기열로 회의 없이도 팀이 계속 움직여요."
            ),
            ("cta", CGRect(x: 56, y: 212, width: 128, height: 18), "무료 체험 시작"),
            ("badge", CGRect(x: 216, y: 214, width: 70, height: 14), "결제 수단 등록 없이 바로 시작할 수 있어요"),
            (
                "billing",
                CGRect(x: 60, y: 288, width: 300, height: 18),
                "결제 주기: 연간. 중간에 상위 요금제로 바꾸면 남은 기간만큼 일할 계산해서 차액만 청구해요."
            ),
        ].map { PickyAnnotationTextItem(id: $0.0, rect: $0.1, text: $0.2, visualStyle: .fallback) }

        let layouts = PickyAnnotationTextLayoutPolicy.layout(items, screenSize: screenSize)

        #expect(layouts.count == items.count)
        for item in items {
            let frame = try #require(layouts[item.id]?.frame)
            #expect(!frame.intersects(item.rect), "Callout \(item.id) covers its own text")
            #expect(CGRect(origin: .zero, size: screenSize).contains(frame), "Callout \(item.id) left the screen")
            for other in items where other.id != item.id {
                #expect(!frame.intersects(other.rect), "Callout \(item.id) covers the text of \(other.id)")
            }
        }
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
        commands: [PickyAnnotationPathCommand]? = nil,
        spotlight: Bool? = nil, label: String? = nil, text: String? = nil
    ) -> PickyAnnotationOverlayAnnotation {
        PickyAnnotationOverlayAnnotation(id: id, shape: shape, x: x, y: y, w: w, h: h, x1: x1, y1: y1, x2: x2, y2: y2, commands: commands, spotlight: spotlight, label: label, text: text, clamped: nil)
    }

    private func resolvedAnnotation(id: String, spotlight: Bool = false) -> PickyAgentAnnotation {
        PickyAgentAnnotation(id: id, shape: .rect, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rect: CGRect(x: 40, y: 40, width: 20, height: 20), spotlight: spotlight, label: nil)
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

    func baselineRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
        baseline
    }

    func currentRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
        guard !current.isEmpty else { throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed }
        return current.removeFirst()
    }

    func reset() {}
}

