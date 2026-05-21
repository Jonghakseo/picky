//
//  OnboardingNarrationPlayer.swift
//  Picky
//
//  Speech surface for the guided onboarding bubbles. Each beat in
//  `OnboardingFlowController` corresponds to one `OnboardingNarrationKey` and
//  the controller asks the configured player to "speak" that key. Players
//  decide HOW the line is voiced — today the only implementation is
//  `SystemSpeechNarrationPlayer` which routes through `NSSpeechSynthesizer`.
//  A future `RecordedNarrationPlayer` will play pre-rendered ElevenLabs MP3s
//  bundled under `Picky/Resources/Onboarding/Audio/<lang>/bubble_<key>.mp3`
//  and fall back to the system synthesiser when an asset is missing.
//
//  The controller (not the player) owns generation tracking, dwell gating,
//  and the markdown-strip step. Players just have to (a) start playback,
//  (b) call `onFinish` exactly once on the main actor when playback ends,
//  and (c) honour `stop()` by halting whatever is in flight. They are free
//  to invoke `onFinish` even after a `stop()` — the controller's generation
//  guard ignores stale callbacks.
//

import AppKit
import Foundation

/// Stable identifiers for every spoken onboarding bubble. The raw value is the
/// suffix of the L10n key (`onboarding.<rawValue>`) AND the suffix of any
/// recorded audio filename (`bubble_<key>.mp3`), so adding a new beat is a
/// single-source-of-truth change here.
enum OnboardingNarrationKey: String, CaseIterable {
    case preWelcome = "bubble.preWelcome"
    case introducing = "bubble.introducing"
    case showingCapabilities = "bubble.showingCapabilities"
    case openingPatchNotes = "bubble.openingPatchNotes"
    case explainingTriggers = "bubble.explainingTriggers"
    case explainingDelegation = "bubble.explainingDelegation"
    case explainingPickle = "bubble.explainingPickle"
    case inviteDrawing = "bubble.inviteDrawing"
    case delegatingToPickle = "bubble.delegatingToPickle"
    case pickleRunning = "bubble.pickleRunning"
    case pickleCompleted = "bubble.pickleCompleted"
    case awaitingPickleOpen = "bubble.awaitingPickleOpen"
    case openedPickle = "bubble.openedPickle"
    case inviteClose = "bubble.inviteClose"
    case inviteArchive = "bubble.inviteArchive"
    case awaitingArchive = "bubble.awaitingArchive"
    case outro = "bubble.outro"

    /// Catalog key used by `L10n.t` to resolve the displayed bubble copy.
    var l10nKey: String { "onboarding.\(rawValue)" }

    /// Slug used for recorded audio filenames, e.g. `bubble.preWelcome` ->
    /// `bubble_preWelcome`. Keeping `_` instead of `.` makes filenames
    /// well-behaved on every filesystem and matches the convention in the
    /// recording instructions handed to the voice talent.
    var assetBasename: String {
        rawValue.replacingOccurrences(of: ".", with: "_")
    }
}

@MainActor
protocol OnboardingNarrationPlayer: AnyObject {
    /// Begin speaking the line that corresponds to `key`.
    ///
    /// - Parameters:
    ///   - key: Stable identifier for the beat. Recorded-audio players use
    ///     this to look up an asset; text-based players ignore it.
    ///   - text: Markdown-stripped, ready-to-speak version of the bubble copy.
    ///     Always passed by the controller so a player can fall back to text
    ///     synthesis when its primary path (e.g. recorded audio) misses.
    ///   - locale: Effective Picky locale at the time of the call. Used to
    ///     pick a voice / pick the `<lang>` audio subdirectory.
    ///   - onFinish: Invoked once on the main actor when playback ends.
    ///     `success == true` means the utterance reached its natural end;
    ///     `false` means it was cut off (interruption, missing voice, audio
    ///     device error). The controller does not distinguish between the
    ///     two — both satisfy the speech-finished gate after the post-speech
    ///     buffer.
    /// - Returns: `true` if playback was successfully started and `onFinish`
    ///   will eventually fire. `false` means the call was a no-op (no
    ///   compatible voice, no audio device, malformed key, etc.) and the
    ///   caller is responsible for synthesising its own finish so the dwell
    ///   gate doesn't sit waiting forever.
    @discardableResult
    func speak(
        key: OnboardingNarrationKey,
        text: String,
        locale: Locale,
        onFinish: @escaping @MainActor (Bool) -> Void
    ) -> Bool

    /// Halt any in-flight playback. Safe to call when nothing is playing.
    /// Implementations may still invoke `onFinish` after `stop()` — the
    /// controller filters stale callbacks via its generation counter.
    func stop()
}

// MARK: - System speech (NSSpeechSynthesizer) implementation

/// Default narration player. Wraps a dedicated `NSSpeechSynthesizer` (the same
/// engine `PickySystemSpeechPlaybackProvider` uses for normal Picky TTS) so
/// the onboarding voice sounds identical to what the user hears from Picky in
/// regular use. Voice is pinned to the effective locale per utterance so a
/// user whose system-default voice is Korean still gets an English voice when
/// running Picky in English (and vice versa).
@MainActor
final class SystemSpeechNarrationPlayer: NSObject, OnboardingNarrationPlayer {
    private let synthesizer: NSSpeechSynthesizer
    private let suppressAudioOutput: Bool
    private let suppressedPlaybackDuration: TimeInterval

    /// Active utterance bookkeeping. Only one onFinish closure is ever live
    /// because each `speak` cancels the previous one before starting; the
    /// generation counter is purely a defence against the rare case where
    /// the delegate fires after `stop()` and a new `speak()` has already
    /// armed a fresh closure.
    private var activeOnFinish: (@MainActor (Bool) -> Void)?
    private var activeGeneration: Int = 0
    private var prerollTask: Task<Void, Never>?

    init(
        synthesizer: NSSpeechSynthesizer = NSSpeechSynthesizer(),
        suppressAudioOutput: Bool? = nil,
        suppressedPlaybackDuration: TimeInterval = 0.01
    ) {
        self.synthesizer = synthesizer
        self.suppressAudioOutput = suppressAudioOutput ?? PickyRuntimeEnvironment.isRunningUnitTests
        self.suppressedPlaybackDuration = max(0, suppressedPlaybackDuration)
        super.init()
        synthesizer.delegate = self
        synthesizer.usesFeedbackWindow = false
    }

    @discardableResult
    func speak(
        key: OnboardingNarrationKey,
        text: String,
        locale: Locale,
        onFinish: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        // Cancel any in-flight utterance first. The previous onFinish is
        // dropped intentionally — the controller already moved on by bumping
        // its own generation counter, so invoking the stale callback would
        // do nothing useful and risks double-firing the new gate.
        synthesizer.stopSpeaking()

        if let voice = resolveVoice(for: locale) {
            synthesizer.setVoice(voice)
        }

        // Keep the short intro pause outside the text stream. Embedded speech
        // commands create speech markers, and Apple's TTS stack can report
        // invalid marker ranges for some utterances.
        let prepared = PickySpeechPlaybackPreparation.prepareForPlayback(text)

        activeGeneration &+= 1
        let myGen = activeGeneration
        activeOnFinish = onFinish

        prerollTask?.cancel()
        prerollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PickySpeechPlaybackPreparation.prerollSilenceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.activeGeneration == myGen else { return }
                self.prerollTask = nil
                if self.suppressAudioOutput {
                    self.finishSuppressedSpeech(generation: myGen)
                    return
                }
                let started = self.synthesizer.startSpeaking(prepared)
                if !started, self.activeGeneration == myGen {
                    let finish = self.activeOnFinish
                    self.activeOnFinish = nil
                    finish?(false)
                }
            }
        }
        return true
    }

    func stop() {
        // Drop the closure first so the delegate callback that
        // `stopSpeaking` may synchronously trigger can't re-enter the
        // controller's gate logic.
        activeOnFinish = nil
        prerollTask?.cancel()
        prerollTask = nil
        synthesizer.stopSpeaking()
    }

    private func finishSuppressedSpeech(generation: Int) {
        let duration = suppressedPlaybackDuration
        prerollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                guard let finish = self.activeOnFinish else { return }
                self.prerollTask = nil
                self.activeOnFinish = nil
                finish(true)
            }
        }
    }

    /// Resolves a voice from `NSSpeechSynthesizer.availableVoices` whose
    /// locale metadata matches `locale`. Prefers an exact region match (e.g.
    /// `ko-KR`), falls back to the primary language tag (`ko`), and returns
    /// `nil` when no match exists — the synthesizer then keeps whatever voice
    /// the user has set in System Settings.
    private func resolveVoice(for locale: Locale) -> NSSpeechSynthesizer.VoiceName? {
        let identifier = locale.identifier
        let primary = String(identifier.split(separator: "-").first ?? Substring(identifier))
        let voices = NSSpeechSynthesizer.availableVoices

        func voiceLocale(_ voice: NSSpeechSynthesizer.VoiceName) -> String {
            (NSSpeechSynthesizer.attributes(forVoice: voice)[.localeIdentifier] as? String) ?? ""
        }

        if let exact = voices.first(where: {
            voiceLocale($0).caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return exact
        }
        if let primaryMatch = voices.first(where: {
            let tag = voiceLocale($0).split(separator: "-").first.map(String.init) ?? ""
            return tag.caseInsensitiveCompare(primary) == .orderedSame
        }) {
            return primaryMatch
        }
        return nil
    }
}

extension SystemSpeechNarrationPlayer: NSSpeechSynthesizerDelegate {
    /// Fires when the utterance ends naturally OR when `stopSpeaking()`
    /// interrupts it. Either way, satisfy the active onFinish exactly once.
    nonisolated func speechSynthesizer(
        _ sender: NSSpeechSynthesizer,
        didFinishSpeaking finishedSpeaking: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let onFinish = self.activeOnFinish else { return }
            self.activeOnFinish = nil
            onFinish(finishedSpeaking)
        }
    }
}
