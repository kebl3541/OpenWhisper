import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import NaturalLanguage
import ScreenCaptureKit
import Speech
import ServiceManagement
import Vision

// MARK: - One analyzer session (rotated between utterances)

final class AnalyzerSession {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var finished = false

    /// onResult(text, isFinal, meanConfidence) is called on the main queue.
    /// meanConfidence is -1 when the engine reported none.
    init(locale: Locale, label: String = "1st",
         onResult: @escaping @Sendable (String, Bool, Double) -> Void) async throws {
        transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [.volatileResults, .fastResults],
                                        attributeOptions: [.transcriptionConfidence])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SimpleError("No compatible audio format for the speech analyzer.")
        }
        format = fmt
        let (seq, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        let t = transcriber
        resultsTask = Task.detached {
            do {
                for try await result in t.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    var confSum = 0.0
                    var confWeight = 0.0
                    for run in result.text.runs {
                        if let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                            let len = Double(result.text[run.range].characters.count)
                            confSum += c * len
                            confWeight += len
                        }
                    }
                    let conf = confWeight > 0 ? confSum / confWeight : -1
                    onResult(text, isFinal, conf)
                }
                DLog.log("results stream ended (\(label))")
            } catch is CancellationError {
                // Normal teardown between utterances.
            } catch {
                DLog.log("results stream ERROR (\(label)): \(error)")
            }
        }
        try await analyzer.start(inputSequence: seq)
    }

    /// Called from the audio tap thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard !finished else { return }
        // Same-format fast path first: a nil converter (some format pairs)
        // must not silently drop audio that needed no conversion at all.
        if buffer.format == format {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if (status == .haveData || status == .inputRanDry), out.frameLength > 0 {
            inputBuilder.yield(AnalyzerInput(buffer: out))
        }
    }

    func teardown() async {
        guard !finished else { return }
        finished = true
        inputBuilder.finish()
        try? await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
    }
}

// MARK: - Read-aloud: extract frontmost window text via AX and speak it

@MainActor
final class SpeechOut: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechOut()
    private let synth = AVSpeechSynthesizer()
    var isSpeaking: Bool { synth.isSpeaking }
    private var lastActivityAt = Date.distantPast

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// Bumped on every stop; streaming readers abort when it changes.
    private(set) var generation = 0

    /// True while speaking and for a short tail afterwards, including the
    /// gaps between queued chunks. Dictation gates must use THIS, not
    /// isSpeaking: the mic hears our own TTS, and an inter-chunk gap once
    /// let the spoken answer's own words register as a mute command.
    var recentlySpeaking: Bool {
        isSpeaking || Date().timeIntervalSince(lastActivityAt) < 1.5
    }

    func speak(_ text: String) {
        stop()
        enqueue(text)
    }

    func enqueue(_ text: String) {
        lastActivityAt = Date()
        let utt = AVSpeechUtterance(string: text)
        if let v = Self.bestVoice(for: text) { utt.voice = v }
        synth.speak(utt)
    }

    func stop() {
        generation += 1
        lastActivityAt = Date()
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in SpeechOut.shared.lastActivityAt = Date() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in SpeechOut.shared.lastActivityAt = Date() }
    }

    static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        let lang = recognizer.dominantLanguage?.rawValue ?? "en"
        let matching = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return matching.first { $0.quality == .premium }
            ?? matching.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: lang == "en" ? "en-GB" : lang)
    }
}

enum FrontTextReader {
    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    /// Chat transcripts put the newest answer at the bottom, so return the
    /// tail of the readable text. Tries the accessibility tree first; if the
    /// app won't expose real content (Comet doesn't), falls back to
    /// screenshot + OCR, which works on anything visible.
    /// Pass the pid captured when the command was given so the reader stays
    /// locked on that app even if the user switches windows meanwhile.
    static func windowText(pid: pid_t, maxChars: Int = 100_000) async -> String? {
        if let ax = await axWindowText(pid: pid, maxChars: maxChars) { return ax }
        DLog.log("read aloud: AX gave nothing usable, trying OCR")
        return await ocrWindowText(pid: pid, maxChars: maxChars)
    }

    private static func axWindowText(pid: pid_t, maxChars: Int) async -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        for attempt in 0..<6 {
            // Task.sleep, never usleep: this runs on the shared cooperative
            // thread pool, and blocking those threads starves the speech
            // engine's own result streams (observed as "dictation went deaf
            // while answer watchers were polling").
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let winRef = attr(axApp, kAXFocusedWindowAttribute as String),
                  CFGetTypeID(winRef) == AXUIElementGetTypeID() else { continue }
            let win = winRef as! AXUIElement

            // Prefer the web content area so we skip browser toolbars/sidebars.
            var webArea: AXUIElement?
            var scanned = 0
            func findWebArea(_ el: AXUIElement, depth: Int) {
                if webArea != nil || scanned > 3000 || depth > 25 { return }
                scanned += 1
                if (attr(el, kAXRoleAttribute as String) as? String) == "AXWebArea" {
                    webArea = el
                    return
                }
                for c in children(of: el) { findWebArea(c, depth: depth + 1) }
            }
            findWebArea(win, depth: 0)

            var texts: [String] = []
            var seen = Set<String>()
            var visited = 0
            func collect(_ el: AXUIElement, depth: Int) {
                if visited > 20000 || depth > 40 { return }
                visited += 1
                let role = (attr(el, kAXRoleAttribute as String) as? String) ?? ""
                if role == kAXStaticTextRole as String || role == "AXTextArea" {
                    if let s = attr(el, kAXValueAttribute as String) as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Chat UIs repeat button labels and duplicate copies of
                        // the transcript; keep the first occurrence only.
                        if t.count > 3, !seen.contains(t) {
                            seen.insert(t)
                            texts.append(t)
                        }
                    }
                }
                for c in children(of: el) { collect(c, depth: depth + 1) }
            }
            collect(webArea ?? win, depth: 0)

            let total = texts.reduce(0) { $0 + $1.count }
            DLog.log("read aloud: attempt \(attempt + 1), webArea=\(webArea != nil), \(texts.count) blocks, \(total) chars")
            if total >= 300 || (attempt == 5 && total > 0) {
                var out = ""
                for t in texts.reversed() {
                    out = t + "\n" + out
                    if out.count >= maxChars { break }
                }
                return String(out.suffix(maxChars))
            }
        }
        return nil
    }

    @MainActor private static var screenPromptShown = false

    private static func ocrWindowText(pid: pid_t, maxChars: Int) async -> String? {
        // The OCR fallback needs Screen Recording, a separate TCC grant that
        // does not come with mic or Accessibility (and was lost in the
        // bundle-id migration). Without this check the failure is silent and
        // talk mode just "does nothing".
        guard CGPreflightScreenCaptureAccess() else {
            DLog.log("ocr: Screen Recording permission missing")
            await MainActor.run {
                guard !screenPromptShown else { return }
                screenPromptShown = true
                CGRequestScreenCaptureAccess()
                let a = NSAlert()
                a.messageText = "Reading this app aloud needs Screen Recording"
                a.informativeText = "This app doesn't expose its text to accessibility, so OpenWhisper reads it from the screen instead. Allow OpenWhisper under System Settings → Privacy & Security → Screen Recording, then relaunch the app."
                a.addButton(withTitle: "Open Settings")
                a.addButton(withTitle: "Not Now")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let win = content.windows
                .filter({ $0.owningApplication?.processID == pid && $0.isOnScreen })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else {
                DLog.log("ocr: no window found for front app")
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.width = Int(win.frame.width) * 2
            config.height = Int(win.frame.height) * 2
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            let observations = request.results ?? []
            // Top-to-bottom reading order (Vision origin is bottom-left).
            let lines = observations
                .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                .compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n")
            DLog.log("ocr: \(lines.count) lines, \(joined.count) chars")
            return joined.isEmpty ? nil : String(joined.suffix(maxChars))
        } catch {
            DLog.log("ocr failed: \(error)")
            return nil
        }
    }
}

// MARK: - Microphone capture (AVCaptureSession: reliable device selection)

final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "openwhisper.mic")
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(preferBuiltIn: Bool) throws {
        var device: AVCaptureDevice?
        if preferBuiltIn, let uid = builtInMicUID() {
            device = AVCaptureDevice(uniqueID: uid)
        }
        if device == nil { device = AVCaptureDevice.default(for: .audio) }
        guard let device else { throw SimpleError("No microphone found.") }
        DLog.log("capture device: \(device.localizedName)")
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw SimpleError("Cannot add microphone input.") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw SimpleError("Cannot add audio output.") }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        guard status == noErr else { return }
        onBuffer?(buf)
    }
}

// MARK: - Live caption overlay

@MainActor
final class CaptionOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 2
        container.addSubview(label)
        panel.contentView = container
    }

    func show(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { hide(); return }
        label.stringValue = trimmed
        let maxWidth: CGFloat = 640
        let fit = label.sizeThatFits(NSSize(width: maxWidth - 36, height: 60))
        let w = min(maxWidth, fit.width + 36)
        let h = fit.height + 20
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 72, width: w, height: h),
                           display: true)
        }
        label.frame = NSRect(x: 18, y: 10, width: w - 36, height: h - 20)
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            Task { @MainActor in self.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
    }
}

