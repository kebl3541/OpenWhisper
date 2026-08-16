import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import NaturalLanguage
import ScreenCaptureKit
import Speech
import ServiceManagement
import Vision

// MARK: - Continuous listening controller

/// Hands the live analyzer sessions to the capture queue under a lock.
/// The capture callback must never read the controller's MainActor-isolated
/// session properties directly: a rotation on the main thread while the
/// audio thread dereferences the old value is a real crash.
final class FeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var primary: AnalyzerSession?
    private var secondary: AnalyzerSession?
    func set(_ p: AnalyzerSession?, _ s: AnalyzerSession?) {
        lock.lock(); primary = p; secondary = s; lock.unlock()
    }
    func get() -> (AnalyzerSession?, AnalyzerSession?) {
        lock.lock(); defer { lock.unlock() }
        return (primary, secondary)
    }
}


@MainActor
final class ListeningController {
    enum State: Equatable { case starting, downloadingModel, listening, paused, failed(String) }

    var state: State = .starting { didSet { onStateChange?() } }
    var onStateChange: (() -> Void)?
    var volatilePreview: String = ""
    var lastUtterance: String = ""
    var recentUtterances: [String] = []

    private var capture = MicCapture()
    private var locale: Locale = Locale(identifier: "en_US")
    private var session: AnalyzerSession?
    private var sessionToken = 0
    // Second transcriber running in parallel for automatic language pick.
    private var secondaryLocale: Locale?
    private var session2: AnalyzerSession?
    private var sessionToken2 = 0
    private var primaryBuf = TextProcessing.UtteranceBuffer()
    private var secondaryBuf = TextProcessing.UtteranceBuffer()
    private var engineRunning = false
    private var timer: Timer?

    lazy var captions = CaptionOverlay()

    // Utterance assembly
    private var pendingSinceCommit = false
    private var typedChunks: [String] = []
    private var typedThisUtterance = ""
    private var typedTargetBundle: String?  // where the last commit typed
    private var lastVoiceAt = Date.distantPast
    private var lastFinalAt = Date.distantPast
    private var lastCommitAt = Date.distantPast
    private var lastResultAt = Date()
    private var sessionStartedAt = Date()
    var lastBufferAt = Date()
    private var lastCaptureRestartAt = Date.distantPast

    func start() async {
        do {
            DLog.log("start(): requesting mic access")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            DLog.log("mic access granted=\(granted)")
            guard granted else {
                state = .failed("Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone, then relaunch.")
                return
            }
            locale = await resolveLocale()
            DLog.log("locale=\(locale.identifier(.bcp47))")
            state = .downloadingModel
            try await ensureModelInstalled(locale: locale) { _ in }
            DLog.log("model installed")
            try await startSession()
            if Defaults.dualLanguage, let second = await resolveLocaleID(Defaults.secondaryLocaleID) {
                do {
                    try await ensureModelInstalled(locale: second) { _ in }
                    secondaryLocale = second
                    try await startSecondarySession()
                    DLog.log("dual language active: \(second.identifier(.bcp47))")
                } catch {
                    DLog.log("dual language unavailable: \(error)")
                }
            }
            try startEngineIfNeeded()
            lastBufferAt = Date()
            state = .listening
            if Defaults.startMuted {
                muted = true
                DLog.log("started muted (startMuted default)")
            }
            let ax = Typist.axTrusted(promptIfNeeded: true)
            DLog.log("listening; axTrusted=\(ax)")
            startTimer()
        } catch {
            DLog.log("start() FAILED: \(error)")
            state = .failed("\(error)")
        }
    }

    private func startSession() async throws {
        sessionToken += 1
        let token = sessionToken
        session = try await AnalyzerSession(locale: locale) { [weak self] text, isFinal, conf in
            Task { @MainActor in
                guard let self, self.sessionToken == token else { return }
                self.handleResult(text: text, isFinal: isFinal, secondary: false, confidence: conf)
            }
        }
        feedBox.set(session, session2)
        sessionStartedAt = Date()
    }

    private func startSecondarySession() async throws {
        guard let secondaryLocale else { return }
        // Never stack sessions: concurrent restart paths (rotation watchdog,
        // settings change, resume) must not leak a live analyzer.
        if let existing = session2 {
            session2 = nil
            feedBox.set(session, nil)
            await existing.teardown()
        }
        sessionToken2 += 1
        let token = sessionToken2
        session2 = try await AnalyzerSession(locale: secondaryLocale, label: "2nd") { [weak self] text, isFinal, conf in
            Task { @MainActor in
                guard let self, self.sessionToken2 == token else { return }
                self.handleResult(text: text, isFinal: isFinal, secondary: true, confidence: conf)
            }
        }
        feedBox.set(session, session2)
    }

    private let feedBox = FeedBox()

    private func startEngineIfNeeded() throws {
        guard !engineRunning else { return }
        configureCaptureCallback()
        try capture.start(preferBuiltIn: Defaults.preferBuiltInMic)
        engineRunning = true
    }

    /// Live mic switching ("headphone mic" / "mac mic") without an app restart.
    func switchMic(builtIn: Bool) {
        Defaults.d.set(builtIn, forKey: "preferBuiltInMic")
        capture.stop()
        capture = MicCapture()
        configureCaptureCallback()
        do {
            try capture.start(preferBuiltIn: builtIn)
            DLog.log("mic switched to \(builtIn ? "built-in" : "system default (headphones)")")
            NSSound(named: "Pop")?.play()
        } catch {
            DLog.log("mic switch failed: \(error)")
            state = .failed("Microphone switch failed: \(error)")
        }
        onStateChange?()
    }

    private func configureCaptureCallback() {
        let box = feedBox
        // VAD state lives inside the closure: it is only ever touched on the
        // capture queue, and a mic switch starts a fresh callback with fresh
        // state.
        var feedActiveUntil = Date.distantPast
        var preroll: [AVAudioPCMBuffer] = []
        capture.onBuffer = { [weak self] buffer in
            let rms = Self.rms(of: buffer)
            if let self { DispatchQueue.main.async { self.noteAudio(rms: rms) } }
            // Battery saver: feed the speech engine only while someone is
            // talking (plus a 3s tail so the endpointer hears the silence and
            // finalizes). A short pre-roll keeps word onsets intact.
            let now = Date()
            if rms > Defaults.voiceThreshold {
                feedActiveUntil = now.addingTimeInterval(3.0)
            }
            let (s1, s2) = box.get()
            // Dual-language: feed continuously. The second engine needs long
            // silence to finalize; gating its audio delays its results by
            // whole utterances.
            if s2 != nil || now < feedActiveUntil {
                if !preroll.isEmpty {
                    for b in preroll {
                        s1?.feed(b)
                        s2?.feed(b)
                    }
                    preroll.removeAll()
                }
                s1?.feed(buffer)
                s2?.feed(buffer)
            } else {
                preroll.append(buffer)
                if preroll.count > 30 { preroll.removeFirst() }
            }
        }
    }

    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        if let data = buffer.floatChannelData {
            var sum: Float = 0
            let samples = data[0]
            for i in 0..<n { sum += samples[i] * samples[i] }
            return Double(sqrt(sum / Float(n)))
        }
        if let data = buffer.int16ChannelData {
            var sum: Double = 0
            let samples = data[0]
            for i in 0..<n {
                let v = Double(samples[i]) / 32768.0
                sum += v * v
            }
            return (sum / Double(n)).squareRoot()
        }
        return 0
    }

    private var wasSpeaking = false
    private func noteAudio(rms: Double) {
        lastBufferAt = Date()
        if rms > Defaults.voiceThreshold {
            if !wasSpeaking { DLog.log(String(format: "voice detected (rms=%.4f)", rms)) }
            wasSpeaking = true
            lastVoiceAt = Date()
        } else if wasSpeaking, Date().timeIntervalSince(lastVoiceAt) > 1.0 {
            wasSpeaking = false
        }
    }

    var speaking: Bool { Date().timeIntervalSince(lastVoiceAt) < 0.6 }

    // MARK: Voice commands ("pause listening" / "start listening")

    var muted = false

    /// Live-final command dispatch. Returns false when the phrase should
    /// fall through to dictation (bare "stop" outside read-aloud, "start
    /// listening" while already unmuted — the commit re-check drops the
    /// latter rather than typing it).
    private func handleLiveCommand(_ cmd: TextProcessing.Command) -> Bool {
        // These work even while muted.
        switch cmd {
        case .pause:
            // Mute must work even when the phrase is embedded in other
            // speech (e.g. a video playing in the room) — parseCommand
            // substring-matches long pause phrases. False positives are
            // harmless; "start listening" undoes them.
            if !muted { setMuted(true) }
            return true
        case .talkOff:
            DLog.log("voice command: talk mode off")
            Defaults.talkMode = false
            SpeechOut.shared.stop()
            NSSound(named: "Bottle")?.play()
            onStateChange?()
            return true
        case .talkOn:
            DLog.log("voice command: talk mode on")
            Defaults.talkMode = true
            NSSound(named: "Glass")?.play()
            onStateChange?()
            return true
        case .languageItalian, .languageEnglish:
            if secondaryLocale != nil {
                DLog.log("language command ignored — dual language is automatic")
                NSSound(named: "Pop")?.play()
            } else {
                switchLocale(cmd == .languageItalian ? "it-IT" : "en-GB")
            }
            return true
        default:
            break
        }
        if muted {
            if cmd == .resume { setMuted(false) }
            else { DLog.log("muted; ignored a command") }
            return true
        }
        switch cmd {
        case .send:
            DLog.log("voice command: send now")
            commitUtterance(force: true)
        case .read:
            doReadAloud()
        case .newline(let n):
            doNewline(n)
        case .micHeadphone:
            switchMic(builtIn: false)
        case .micBuiltIn:
            switchMic(builtIn: true)
        case .scratch:
            if !primaryBuf.isEmpty || !secondaryBuf.isEmpty {
                DLog.log("voice command: scratch (cleared pending utterance)")
                clearUtteranceBuffers()
                pendingSinceCommit = false
                captions.hide()
            } else {
                doScratchTyped()
            }
            onStateChange?()
        case .stopRead, .resume:
            // Bare "stop" outside read-aloud is ordinary dictation; an
            // unmuted "start listening" is handled at commit (dropped).
            return false
        case .pause, .talkOn, .talkOff, .languageItalian, .languageEnglish:
            return true // already handled above
        }
        return true
    }

    private func handleDictionaryCommand(_ cleaned: String) -> Bool {
        if let (wrong, right) = TextProcessing.parseReplace(cleaned) {
            var dict = Defaults.corrections
            dict[wrong] = right
            Defaults.corrections = dict
            // Lengths only — the log must never contain spoken words.
            DLog.log("dictionary: added replacement (\(wrong.count)->\(right.count) chars, \(dict.count) entries)")
            NSSound(named: "Glass")?.play()
            return true
        }
        if let wrong = TextProcessing.parseForget(cleaned) {
            var dict = Defaults.corrections
            dict.removeValue(forKey: wrong)
            Defaults.corrections = dict
            DLog.log("dictionary: removed replacement (\(dict.count) entries left)")
            NSSound(named: "Bottle")?.play()
            return true
        }
        return false
    }

    private var pendingReadAfterSend = false

    nonisolated private static func trimPageJunk(_ s: String) -> String {
        TextProcessing.trimPageJunk(s)
    }

    nonisolated private static func sentenceBoundary(in s: String) -> String.Index? {
        TextProcessing.sentenceBoundary(in: s)
    }

    /// Streams the answer aloud while it renders: each poll speaks any new
    /// complete sentences instead of waiting for the answer to finish.
    private func startAnswerWatcher(prompt: String) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let gen = SpeechOut.shared.generation
        DLog.log("answer watcher: started (pid \(pid))")
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let key = String(prompt.prefix(60)).trimmingCharacters(in: .whitespaces)
            var spoken = ""
            var lastFull = ""
            var stable = 0
            for _ in 0..<90 {
                if await SpeechOut.shared.generation != gen {
                    DLog.log("answer watcher: cancelled by stop")
                    return
                }
                let full = await FrontTextReader.windowText(pid: pid) ?? ""
                var answer: String?
                if key.count > 10,
                   let r = full.range(of: key, options: [.backwards, .caseInsensitive]) {
                    answer = Self.trimPageJunk(String(full[r.upperBound...]))
                }
                let done = !full.isEmpty && full == lastFull
                stable = done ? stable + 1 : 0
                lastFull = full

                if let a = answer, a.hasPrefix(spoken) {
                    let new = String(a.dropFirst(spoken.count))
                    if stable >= 2 {
                        // Stream finished: speak whatever remains.
                        let rest = new.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rest.isEmpty {
                            DLog.log("answer watcher: final chunk (\(rest.count) chars)")
                            await MainActor.run { SpeechOut.shared.enqueue(rest) }
                        }
                    } else if let cut = Self.sentenceBoundary(in: new) {
                        let chunk = String(new[..<cut])
                        if chunk.trimmingCharacters(in: .whitespacesAndNewlines).count > 1 {
                            DLog.log("answer watcher: chunk (\(chunk.count) chars)")
                            await MainActor.run { SpeechOut.shared.enqueue(chunk) }
                            spoken += chunk
                        }
                    }
                }
                if stable >= 2 {
                    if spoken.isEmpty, answer == nil, !lastFull.isEmpty {
                        // Never anchored: read the visible tail once.
                        let tail = String(Self.trimPageJunk(lastFull).suffix(20000))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if tail.count > 10 {
                            DLog.log("answer watcher: unanchored tail (\(tail.count) chars)")
                            await MainActor.run { SpeechOut.shared.enqueue(tail) }
                        }
                    } else if let a = answer, !spoken.isEmpty, !a.hasPrefix(spoken) {
                        // Page reflowed mid-stream; speak what we haven't covered.
                        let rest = String(a.suffix(max(0, a.count - spoken.count)))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        DLog.log("answer watcher: reflow detected, speaking remainder (\(rest.count) chars)")
                        if rest.count > 10 {
                            await MainActor.run { SpeechOut.shared.enqueue(rest) }
                        }
                    }
                    DLog.log("answer watcher: done")
                    return
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    private func normalizeCommand(_ s: String) -> String {
        TextProcessing.normalizeCommand(s)
    }

    private func wakeRemainder(of text: String) -> String? {
        TextProcessing.wakeRemainder(of: text)
    }

    private func frontmostIsWakeTarget() -> Bool {
        (NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() ?? "")
            .hasPrefix(Defaults.wakeTargetPrefix.lowercased())
    }

    private var lastWakeActivation = Date.distantPast

    private func activateWakeTargetApp() {
        lastWakeActivation = Date()
        let ws = NSWorkspace.shared
        if let running = ws.runningApplications.first(where: {
            ($0.bundleIdentifier?.lowercased() ?? "").hasPrefix(Defaults.wakeTargetPrefix.lowercased())
        }) {
            running.activate()
        } else if let url = ws.urlForApplication(withBundleIdentifier: Defaults.wakeTargetAppID) {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func handleWake(remainder: String) {
        DLog.log("wake word: activating target app (remainder \(remainder.count) chars)")
        if muted { setMuted(false) }
        NSSound(named: "Pop")?.play()
        activateWakeTargetApp()
        // Drop anything both engines buffered for this utterance — the
        // trailing secondary final still carries the raw "hey claude …" text
        // and must not win the confidence pick at commit.
        clearUtteranceBuffers()
        guard !remainder.isEmpty else { return }
        var attempts = 0
        func tryType() {
            attempts += 1
            if self.frontmostIsWakeTarget() {
                // Queue it like a dictated utterance; commit types and sends.
                self.clearUtteranceBuffers()
                self.primaryBuf.text = remainder
                self.pendingSinceCommit = true
                self.lastFinalAt = Date()
            } else if attempts < 16 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tryType() }
            } else {
                DLog.log("wake word: Claude never came frontmost; dropping queued text")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { tryType() }
    }

    var currentLocaleID: String { locale.identifier(.bcp47) }
    var languagesDescription: String {
        secondaryLocale == nil
            ? currentLocaleID
            : "\(currentLocaleID) + \(secondaryLocale!.identifier(.bcp47))"
    }

    /// Settings-window entry points for live language changes.
    func setPrimaryLocale(_ id: String) { switchLocale(id) }

    func setSecondaryLocale(_ id: String?) {
        Defaults.d.set(id != nil, forKey: "dualLanguage")
        if let id { Defaults.d.set(id, forKey: "secondaryLocale") }
        // Clear the published state synchronously: the rotation watchdog
        // checks `secondaryLocale` and could otherwise resurrect the old
        // engine between our teardown and the async re-create below.
        secondaryLocale = nil
        let old = session2
        session2 = nil
        feedBox.set(session, nil)
        sessionToken2 += 1
        Task { [weak self] in
            await old?.teardown()
            guard let self, self.state == .listening else { return }
            guard let id, let loc = await resolveLocaleID(id) else {
                if id != nil {
                    // Unsupported locale: don't leave dual mode half-on.
                    Defaults.d.set(false, forKey: "dualLanguage")
                    NSSound(named: "Basso")?.play()
                }
                DLog.log("secondary language off")
                return
            }
            do {
                try await ensureModelInstalled(locale: loc) { _ in }
                guard self.state == .listening else { return }
                self.secondaryLocale = loc
                try await self.startSecondarySession()
                DLog.log("secondary language set to \(loc.identifier(.bcp47))")
            } catch {
                self.secondaryLocale = nil
                Defaults.d.set(false, forKey: "dualLanguage")
                NSSound(named: "Basso")?.play()
                DLog.log("secondary language change failed: \(error)")
            }
        }
    }

    private func switchLocale(_ id: String) {
        guard locale.identifier(.bcp47).lowercased() != id.lowercased() else { return }
        DLog.log("switching locale to \(id)")
        Defaults.d.set(id, forKey: "locale")
        NSSound(named: "Glass")?.play()
        Task { [weak self] in
            guard let self else { return }
            let newLocale = await resolveLocale()
            do {
                try await ensureModelInstalled(locale: newLocale) { _ in }
                self.locale = newLocale
                self.rotateSession()
                DLog.log("locale switched to \(newLocale.identifier(.bcp47))")
            } catch {
                DLog.log("locale switch failed: \(error)")
                NSSound(named: "Basso")?.play()
            }
        }
    }

    private func setMuted(_ m: Bool) {
        muted = m
        typedThisUtterance = ""
        typedChunks = []
        clearUtteranceBuffers()
        pendingSinceCommit = false
        volatilePreview = ""
        captions.hide()
        DLog.log(m ? "voice command: muted" : "voice command: unmuted")
        NSSound(named: m ? "Bottle" : "Pop")?.play()
        onStateChange?()
    }

    private func handleResult(text: String, isFinal: Bool, secondary: Bool, confidence: Double) {
        guard state == .listening else { return }
        lastResultAt = Date()
        if !isFinal {
            if secondary {
                secondaryBuf.sawSpeech = true
                return
            }
            volatilePreview = text
            // Instant stop: don't wait for the phrase to finalize.
            if SpeechOut.shared.isSpeaking {
                let v = normalizeCommand(text)
                if v.contains("stop") || v.contains("shut up") || v.contains("quiet") || v.contains("silence") {
                    DLog.log("instant stop (volatile)")
                    SpeechOut.shared.stop()
                }
                return
            }
            // Instant mute from the live partial transcript — during
            // continuous media audio there may never be a clean final.
            if !muted {
                let v = normalizeCommand(text)
                if TextProcessing.pauseCommands.contains(where: { $0.count >= 10 && v.contains($0) }) {
                    DLog.log("instant mute (volatile)")
                    setMuted(true)
                    return
                }
            }
            // React to "Hey Claude" from the live partial transcript — don't
            // wait for finalization. The final still handles text carry-over.
            if !muted, !SpeechOut.shared.isSpeaking,
               wakeRemainder(of: text) != nil,
               Date().timeIntervalSince(lastWakeActivation) > 3,
               !frontmostIsWakeTarget() {
                DLog.log("wake word (volatile): pre-activating target app")
                NSSound(named: "Pop")?.play()
                activateWakeTargetApp()
            }
            if !muted, Defaults.showCaptions {
                captions.show(primaryBuf.text + " " + text)
            }
            onStateChange?()
            return
        }
        volatilePreview = ""
        lastFinalAt = Date()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        // Sessions are long-lived now; a final belonging to an already
        // committed utterance (no new voice since) must not leak into the next.
        if lastVoiceAt <= lastCommitAt {
            DLog.log("dropping stale final (\(secondary ? "2nd" : "1st"), \(cleaned.count) chars)")
            return
        }

        let command = normalizeCommand(cleaned)
        let parsed = TextProcessing.parseCommand(command)
        // While the Mac itself is speaking, the mic may be hearing our own
        // voice — accept only "stop", ignore everything else.
        if SpeechOut.shared.isSpeaking {
            if parsed == .stopRead {
                DLog.log("voice command: stop reading")
                SpeechOut.shared.stop()
            } else {
                DLog.log("ignoring speech while reading aloud (\(cleaned.count) chars)")
            }
            return
        }
        if !secondary, let remainder = wakeRemainder(of: cleaned) {
            handleWake(remainder: remainder)
            return
        }
        if let parsed, handleLiveCommand(parsed) { return }
        if muted {
            DLog.log("muted; ignored a phrase (\(cleaned.count) chars)")
            return
        }
        if handleDictionaryCommand(cleaned) { return }
        // Accumulate; both models' text is compared and typed at commit time.
        pendingSinceCommit = true
        if secondary {
            secondaryBuf.add(cleaned, confidence: confidence)
        } else {
            primaryBuf.add(cleaned, confidence: confidence)
        }
        DLog.log(String(format: "final (%@ model, %d chars, conf %.3f)", secondary ? "2nd" : "1st", cleaned.count, confidence))
        onStateChange?()
    }

    /// Read the front window aloud, anchored on the last dictated prompt.
    private func doReadAloud() {
        DLog.log("voice command: read front window aloud")
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let anchor = String(lastUtterance.prefix(60)).trimmingCharacters(in: .whitespaces)
        Task.detached {
            guard var text = await FrontTextReader.windowText(pid: pid) else {
                DLog.log("read aloud: no text found in front window")
                await MainActor.run { NSSound(named: "Basso")?.play() }
                return
            }
            // Anchor on the user's last dictated prompt so we read the
            // answer that follows it, not the whole page.
            if anchor.count > 10,
               let r = text.range(of: anchor, options: [.backwards, .caseInsensitive]) {
                text = String(text[r.upperBound...])
                text = Self.trimPageJunk(text)
                DLog.log("read aloud: anchored on last utterance")
            } else {
                text = String(Self.trimPageJunk(text).suffix(4000))
            }
            let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                if final.count > 10 {
                    DLog.log("reading \(final.count) chars aloud")
                    SpeechOut.shared.speak(final)
                } else {
                    NSSound(named: "Basso")?.play()
                }
            }
        }
    }

    private func doNewline(_ n: Int) {
        if (Defaults.anyApp || isAllowedFrontmost()), Typist.axTrusted() {
            DLog.log("voice command: newline x\(n)")
            for _ in 0..<n { Typist.pressKey(36, flags: .maskShift) } // Shift+Return: newline, not send
        }
    }

    /// Delete the last typed phrase — only in the app it was typed into.
    private func doScratchTyped() {
        if !typedChunks.isEmpty,
           Typist.axTrusted(),
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == typedTargetBundle,
           let last = typedChunks.popLast() {
            DLog.log("voice command: scratch (\(last.count) chars)")
            for _ in 0..<last.count { Typist.pressKey(51, flags: []) } // kVK_Delete
            typedThisUtterance = typedChunks.joined()
        } else {
            DLog.log("voice command: scratch (nothing to delete here)")
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common keeps the tick alive during modal panels (Settings' folder
        // picker, alerts) — otherwise finals buffer up during the modal and
        // dump into whatever is frontmost when it closes.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard state == .listening else { return }
        // The gating constants live in TextProcessing.commitDecision, where
        // they are pure and covered by regression tests.
        switch TextProcessing.commitDecision(
            now: Date(), lastVoiceAt: lastVoiceAt, lastFinalAt: lastFinalAt,
            lastResultAt: lastResultAt, sessionStartedAt: sessionStartedAt,
            pending: pendingSinceCommit, muted: muted,
            volatileEmpty: volatilePreview.isEmpty,
            commitDelay: Defaults.effectiveCommitDelay,
            dual: secondaryLocale != nil,
            primary: primaryBuf, secondary: secondaryBuf) {
        case .commit:
            commitUtterance()
        case .rotateIdle:
            // Periodic hygiene: fresh analyzers after long silence.
            rotateSessions()
        case .rotateWatchdog:
            // Voice is present but the engines have gone mute — a dead
            // results stream would otherwise deafen us until 60s of silence,
            // which never comes while the user keeps talking.
            DLog.log("watchdog: engines silent while voice present — rotating sessions")
            rotateSessions()
        case .wait:
            break
        }
        // Capture watchdog: buffers stopped arriving entirely (input device
        // vanished, capture session died). Without this the app stays green
        // "Listening" while permanently deaf.
        if engineRunning,
           Date().timeIntervalSince(lastBufferAt) > 5,
           Date().timeIntervalSince(lastCaptureRestartAt) > 10 {
            DLog.log("watchdog: no audio buffers for 5s — restarting capture")
            lastCaptureRestartAt = Date()
            restartCapture()
        }
    }

    private func restartCapture() {
        capture.stop()
        capture = MicCapture()
        configureCaptureCallback()
        do {
            try capture.start(preferBuiltIn: Defaults.preferBuiltInMic)
            lastBufferAt = Date()
        } catch {
            DLog.log("capture restart failed: \(error)")
        }
    }

    /// Picks whichever model actually understood the utterance, by the
    /// engines' own acoustic confidence (text-language guessing can't tell:
    /// the wrong model still emits real words of its own language).
    private func chooseUtterance() -> String {
        if let picked = TextProcessing.pickUtterance(primary: primaryBuf, secondary: secondaryBuf) {
            if !primaryBuf.isEmpty, !secondaryBuf.isEmpty {
                DLog.log(String(format: "confidence pick: 1st=%.3f 2nd=%.3f -> %@",
                                primaryBuf.meanConfidence ?? -1, secondaryBuf.meanConfidence ?? -1,
                                picked == secondaryBuf.text ? "2nd" : "1st"))
            }
            return picked
        }
        // Fallback when an engine reports no confidence.
        func score(_ text: String, _ lang: NLLanguage) -> Double {
            let r = NLLanguageRecognizer()
            r.processString(text)
            return r.languageHypotheses(withMaximum: 5)[lang] ?? 0
        }
        let en = score(primaryBuf.text, .english)
        let it = score(secondaryBuf.text, .italian)
        DLog.log(String(format: "language pick (fallback): en=%.2f it=%.2f -> %@", en, it, it > en ? "it" : "en"))
        return it > en ? secondaryBuf.text : primaryBuf.text
    }

    private func clearUtteranceBuffers() {
        primaryBuf.clear()
        secondaryBuf.clear()
    }

    private func commitUtterance(force: Bool = false) {
        var force = force
        pendingSinceCommit = false
        var chosen = chooseUtterance()
        // Dictionary commands are matched against the words as spoken —
        // corrections must not rewrite the phrase before it's parsed, or
        // "replace a i with foo" stores the already-corrected key.
        let spokenForDictionary = chosen
        clearUtteranceBuffers()
        if !chosen.isEmpty {
            if let stripped = TextProcessing.stripTrailingReadCommand(chosen) {
                DLog.log("trailing read command: will read answer after send")
                chosen = stripped
                pendingReadAfterSend = true
            }
            chosen = TextProcessing.applyCorrections(chosen, corrections: Defaults.corrections)
            if Defaults.removeFillers { chosen = TextProcessing.stripFillers(chosen) }
        }
        // A command phrase can arrive split across two engine finals ("stop"
        // then "listening"); each half fails to match, they're stitched back
        // together in the buffer, and without this check the assembled
        // command would be typed into the frontmost app and auto-sent.
        // (Observed live: room speech ending in "stop listening" was sent to
        // a chat instead of muting.) Re-check the assembled utterance here.
        if !chosen.isEmpty {
            // Same protection for the wake phrase: if the winning engine's
            // buffer still starts with "hey claude", type only the remainder.
            if let rem = TextProcessing.wakeRemainder(of: chosen) {
                DLog.log("commit: stripping wake phrase from assembled utterance")
                chosen = rem
            }
        }
        if !chosen.isEmpty {
            switch TextProcessing.parseCommand(normalizeCommand(chosen)) {
            case .pause:
                DLog.log("commit: assembled utterance is a mute command — muting, not typing")
                setMuted(true)
                return
            case .send:
                DLog.log("commit: assembled utterance is a send command — pressing Return only")
                chosen = ""
                force = true
            case .scratch:
                DLog.log("commit: assembled utterance is a scratch command")
                doScratchTyped()
                chosen = ""
            case .read:
                doReadAloud()
                chosen = ""
            case .newline(let n):
                doNewline(n)
                chosen = ""
            case .talkOn, .talkOff:
                Defaults.talkMode = TextProcessing.parseCommand(normalizeCommand(chosen)) == .talkOn
                DLog.log("commit: assembled utterance is a talk-mode command")
                chosen = ""
            case .micHeadphone:
                switchMic(builtIn: false)
                chosen = ""
            case .micBuiltIn:
                switchMic(builtIn: true)
                chosen = ""
            case .resume, .languageItalian, .languageEnglish:
                // Not meaningful at commit time — but never type them either.
                DLog.log("commit: dropped assembled command (\(chosen.count) chars)")
                chosen = ""
            case .stopRead, nil:
                // Bare "stop" is legitimate dictation; anything unparsed is text.
                break
            }
            // A split "replace X with Y" reassembles here too — store the
            // correction instead of typing the sentence.
            if !chosen.isEmpty, handleDictionaryCommand(spokenForDictionary) {
                chosen = ""
            }
        }
        let canType = !isCallAppFrontmost()
            && (Defaults.anyApp || isAllowedFrontmost())
            && Typist.axTrusted()
            // Never type into our own windows (Settings, History, alerts).
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        if !chosen.isEmpty {
            lastUtterance = chosen
            recentUtterances.append(chosen)
            if recentUtterances.count > 10 { recentUtterances.removeFirst() }
            Journal.append(chosen)
            HistoryStore.append(chosen)
            if canType {
                if Defaults.insertViaPaste { Typist.pasteViaClipboard(chosen) } else { Typist.type(chosen) }
                typedThisUtterance = chosen
                typedChunks = [chosen]
                typedTargetBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                DLog.log("commit: typed \(chosen.count) chars front=\(typedTargetBundle ?? "?")")
            } else if Defaults.stashToClipboard {
                // Opt-in: overwriting the user's clipboard with room speech
                // is worse than losing a phrase, so this is off by default.
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(chosen, forType: .string)
                DLog.log("commit: stashed to clipboard (\(chosen.count) chars)")
            } else {
                DLog.log("commit: dropped (\(chosen.count) chars — typing not possible here)")
            }
        }
        if canType, force || (Defaults.effectiveAutoReturn && !chosen.isEmpty) {
            DLog.log("commit: pressing Return")
            Typist.pressReturn()
            if (pendingReadAfterSend || Defaults.talkMode), !typedThisUtterance.isEmpty {
                startAnswerWatcher(prompt: typedThisUtterance)
            }
        }
        pendingReadAfterSend = false
        captions.hide()
        lastCommitAt = Date()
        onStateChange?()
        // Sessions stay alive between utterances: rebuilding them here opened
        // a dead window that swallowed the start of rapid follow-up messages.
    }

    private func rotateSessions() {
        rotateSession()
        guard secondaryLocale != nil else { return }
        let old = session2
        session2 = nil
        feedBox.set(session, session2)
        sessionToken2 += 1
        Task { [weak self] in
            await old?.teardown()
            guard let self, self.state == .listening else { return }
            for attempt in 1...5 {
                do {
                    try await self.startSecondarySession()
                    return
                } catch {
                    DLog.log("2nd session restart failed (attempt \(attempt)): \(error)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            DLog.log("2nd session restart gave up — second language temporarily unavailable")
        }
    }

    private func rotateSession() {
        // Reset the watchdog clocks up front: the async restart below can
        // take seconds, and the 0.25s tick must not re-trigger a second
        // overlapping rotation meanwhile.
        sessionStartedAt = Date()
        lastResultAt = Date()
        let old = session
        session = nil
        feedBox.set(session, session2)
        sessionToken += 1
        Task { [weak self] in
            await old?.teardown()
            guard let self, self.state == .listening else { return }
            for attempt in 1...5 {
                do {
                    try await self.startSession()
                    return
                } catch {
                    DLog.log("session restart failed (attempt \(attempt)): \(error)")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            DLog.log("session restart gave up after 5 attempts")
            self.state = .failed("Speech session died and could not be restarted. Quit and reopen the app.")
        }
    }

    func toggleMute() {
        guard state == .listening else { return }
        setMuted(!muted)
    }

    func pause() {
        guard state == .listening else { return }
        state = .paused
        volatilePreview = ""
        typedThisUtterance = ""
        typedChunks = []
        clearUtteranceBuffers()
        pendingSinceCommit = false
        captions.hide()
        // "Turn Mic Off Completely" must actually release the microphone:
        // tearing down only the analyzers leaves the capture session hot and
        // the system mic indicator lit.
        capture.stop()
        engineRunning = false
        let old = session
        let old2 = session2
        session = nil
        session2 = nil
        feedBox.set(nil, nil)
        Task {
            await old?.teardown()
            await old2?.teardown()
        }
        NSSound(named: "Bottle")?.play()
    }

    func resume() {
        guard state == .paused else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startSession()
                try? await self.startSecondarySession()
                try self.startEngineIfNeeded()
                self.lastBufferAt = Date()
                self.state = .listening
                NSSound(named: "Pop")?.play()
            } catch {
                self.state = .failed("\(error)")
            }
        }
    }
}

// MARK: - File transcription (self-test / CLI)

func transcribeFile(path: String) async throws -> String {
    let url = URL(fileURLWithPath: path)
    let locale = await resolveLocale()
    try await ensureModelInstalled(locale: locale) { note in
        FileHandle.standardError.write((note + "\n").data(using: .utf8)!)
    }
    let transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [],
                                        attributeOptions: [])
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)
    let collector = Task {
        var out = ""
        for try await result in transcriber.results where result.isFinal {
            out += String(result.text.characters)
        }
        return out
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }
    return try await collector.value
}

