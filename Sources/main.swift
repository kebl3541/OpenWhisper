import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import NaturalLanguage
import ScreenCaptureKit
import Speech
import ServiceManagement
import Vision

// MARK: - Small helpers

enum DLog {
    static let queue = DispatchQueue(label: "openwhisper.log")
    static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenWhisper", isDirectory: true)
        let oldDir = support.appendingPathComponent("TalkToClaude", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: oldDir.path) {
            try? FileManager.default.moveItem(at: oldDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("openwhisper.log")
        // Cap growth: start fresh whenever the log passes ~5 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }()
    static func log(_ s: String) {
        queue.async {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

struct SimpleError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

enum Defaults {
    static let d = UserDefaults.standard
    static var commitDelay: Double { d.object(forKey: "commitDelay") as? Double ?? 2.0 }
    static var voiceThreshold: Double { d.object(forKey: "voiceThreshold") as? Double ?? 0.012 }
    static var autoReturn: Bool { d.object(forKey: "autoReturn") as? Bool ?? true }
    static var anyApp: Bool { d.object(forKey: "anyApp") as? Bool ?? false }
    static var insertViaPaste: Bool { d.object(forKey: "insertViaPaste") as? Bool ?? false }
    static var localeOverride: String? { d.string(forKey: "locale") }
    static var showCaptions: Bool { d.object(forKey: "showCaptions") as? Bool ?? true }
    static var preferBuiltInMic: Bool { d.object(forKey: "preferBuiltInMic") as? Bool ?? true }
    static var talkMode: Bool {
        get { d.object(forKey: "talkMode") as? Bool ?? false }
        set { d.set(newValue, forKey: "talkMode") }
    }
    static var corrections: [String: String] {
        get { d.dictionary(forKey: "corrections") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "corrections") }
    }
    /// Off by default: the second engine costs battery (continuous feeding)
    /// and commit latency. Opt in via Settings → Secondary language.
    static var dualLanguage: Bool { d.object(forKey: "dualLanguage") as? Bool ?? false }
    static var secondaryLocaleID: String { d.string(forKey: "secondaryLocale") ?? "it-IT" }
    static var removeFillers: Bool { d.object(forKey: "removeFillers") as? Bool ?? true }
    /// Launch muted: nothing is typed anywhere until "start listening".
    static var startMuted: Bool { d.object(forKey: "startMuted") as? Bool ?? false }
    /// Copy the transcript to the clipboard when typing isn't possible.
    /// Off by default: silently replacing the user's clipboard is worse than
    /// losing a phrase.
    static var stashToClipboard: Bool { d.object(forKey: "stashToClipboard") as? Bool ?? false }
    /// When set, every committed utterance is appended to a daily Markdown
    /// file in this directory. Explicitly opt-in: it writes spoken text to disk.
    static var journalDir: String? {
        get { d.string(forKey: "journalDir") }
        set { d.set(newValue, forKey: "journalDir") }
    }
    /// Named toggle-listening hotkey ("None" disables). Voice stays primary;
    /// this is for users who want a physical switch too.
    static var hotkeyChoice: String {
        get { d.string(forKey: "hotkeyChoice") ?? "F18" }
        set { d.set(newValue, forKey: "hotkeyChoice") }
    }
    /// Opt-in persistent, searchable history of everything dictated.
    static var historyEnabled: Bool {
        get { d.object(forKey: "historyEnabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "historyEnabled") }
    }

    /// Per-app overrides, keyed by bundle-id prefix:
    /// defaults write io.github.kebl3541.openwhisper profileOverrides -dict \
    ///   com.anthropic. '{ commitDelay = 0.7; autoReturn = 1; }'
    static func profileValue(forFrontmostKey key: String) -> Any? {
        TextProcessing.profileValue(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            profiles: d.dictionary(forKey: "profileOverrides"), key: key)
    }
    static var effectiveCommitDelay: Double {
        (profileValue(forFrontmostKey: "commitDelay") as? Double) ?? commitDelay
    }
    static var effectiveAutoReturn: Bool {
        if let v = profileValue(forFrontmostKey: "autoReturn") {
            if let b = v as? Bool { return b }
            if let n = v as? Int { return n != 0 }
        }
        return autoReturn
    }
}

func resolveLocaleID(_ id: String) async -> Locale? {
    let supported = await SpeechTranscriber.supportedLocales
    return supported.first { $0.identifier(.bcp47).lowercased() == id.lowercased() }
}

/// Apps where dictation must never type (live calls).
let callAppBundles: Set<String> = [
    "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
    "com.apple.FaceTime", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
]

func isCallAppFrontmost() -> Bool {
    guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
    return callAppBundles.contains(bid)
}

/// Bluetooth headsets steal the default input and their HFP mics are poor
/// (and force headphones into low-quality call mode). Find the built-in mic.
func audioDeviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let err = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return err == noErr ? (name as String) : "?"
}

func builtInMicUID() -> String? {
    guard let id = builtInMicDeviceID() else { return nil }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let err = withUnsafeMutablePointer(to: &uid) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return err == noErr ? (uid as String) : nil
}

func builtInMicDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return nil }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var taddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { continue }
        var iaddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var isize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &iaddr, 0, nil, &isize) == noErr, isize > 0 else { continue }
        return id
    }
    return nil
}

/// Apps that get typed dictation + auto-Return. Override with:
/// defaults write io.github.kebl3541.openwhisper targetBundlePrefixes -array "com.anthropic." "ai.perplexity."
func allowedTargetPrefixes() -> [String] {
    Defaults.d.stringArray(forKey: "targetBundlePrefixes") ?? ["com.anthropic.", "ai.perplexity."]
}

func isAllowedFrontmost() -> Bool {
    // Bundle-id prefixes only. Matching on the app's display name would let
    // any app call itself "Claude…" and receive keystrokes plus auto-Return.
    guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else { return false }
    return allowedTargetPrefixes().contains(where: { bid.hasPrefix($0.lowercased()) })
}

// MARK: - Keystroke synthesis

enum Typist {
    static func axTrusted(promptIfNeeded: Bool = false) -> Bool {
        if AXIsProcessTrusted() { return true }
        if promptIfNeeded {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    /// Types arbitrary text into the focused field via synthetic unicode key
    /// events. Chunks split on Character boundaries so surrogate pairs
    /// (emoji, rare CJK) are never torn across two key events.
    static func type(_ text: String) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        var chunk: [UInt16] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up.post(tap: .cgSessionEventTap)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for ch in text {
            let units = Array(String(ch).utf16)
            if chunk.count + units.count > 16 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }

    /// Paste-mode insertion. The user's previous clipboard string is put back
    /// a moment after the synthetic Cmd+V, so dictation doesn't destroy
    /// whatever they had copied.
    static func pasteViaClipboard(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            pressKey(9, flags: .maskCommand) // kVK_ANSI_V
            if let previous {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let pb = NSPasteboard.general
                    // Don't fight the user if they copied something newer meanwhile.
                    if pb.string(forType: .string) == text {
                        pb.clearContents()
                        pb.setString(previous, forType: .string)
                    }
                }
            }
        }
    }

    static func pressReturn() { pressKey(36, flags: []) } // kVK_Return

    static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Speech locale resolution

func resolveLocale() async -> Locale {
    let supported = await SpeechTranscriber.supportedLocales
    func match(_ id: String) -> Locale? {
        supported.first { $0.identifier(.bcp47).lowercased() == id.lowercased() }
    }
    if let over = Defaults.localeOverride, let l = match(over) { return l }
    let current = Locale.current.identifier(.bcp47)
    if let l = match(current) { return l }
    // Same language, any region
    if let lang = Locale.current.language.languageCode?.identifier {
        if let l = supported.first(where: { $0.language.languageCode?.identifier == lang }) { return l }
    }
    return match("en-US") ?? supported.first ?? Locale(identifier: "en_US")
}

func ensureModelInstalled(locale: Locale, progressNote: @escaping @Sendable (String) -> Void) async throws {
    let installed = await SpeechTranscriber.installedLocales
    let id = locale.identifier(.bcp47)
    if installed.contains(where: { $0.identifier(.bcp47) == id }) { return }
    let transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [],
                                        attributeOptions: [])
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        progressNote("Downloading speech model for \(id)…")
        try await req.downloadAndInstall()
    }
}

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
final class SpeechOut {
    static let shared = SpeechOut()
    private let synth = AVSpeechSynthesizer()
    var isSpeaking: Bool { synth.isSpeaking }

    /// Bumped on every stop; streaming readers abort when it changes.
    private(set) var generation = 0

    func speak(_ text: String) {
        stop()
        enqueue(text)
    }

    func enqueue(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        if let v = Self.bestVoice(for: text) { utt.voice = v }
        synth.speak(utt)
    }

    func stop() {
        generation += 1
        synth.stopSpeaking(at: .immediate)
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
        if let ax = axWindowText(pid: pid, maxChars: maxChars) { return ax }
        DLog.log("read aloud: AX gave nothing usable, trying OCR")
        return await ocrWindowText(pid: pid, maxChars: maxChars)
    }

    private static func axWindowText(pid: pid_t, maxChars: Int) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        for attempt in 0..<6 {
            if attempt > 0 { usleep(800_000) }
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

    private static func ocrWindowText(pid: pid_t, maxChars: Int) async -> String? {
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

// MARK: - Pure text processing (no app state; exercised by --selftest)

enum TextProcessing {
    /// Lowercase, letters and spaces only — the canonical form voice
    /// commands are matched against.
    static func normalizeCommand(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // Only sounds that are never real words in English or Italian; anything
    // ambiguous ("well", "cioè", "like") stays.
    // The lookahead keeps hyphenated interjections ("uh-huh") intact.
    static let fillerRegex = try! NSRegularExpression(
        pattern: "\\b(?:um+|uh+m*|erm+|ehm+|hmm+|mmm+)\\b(?![-'’])[,.]?\\s*",
        options: [.caseInsensitive])

    static func stripFillers(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        var out = fillerRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "^[,.\\s]+", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func applyCorrections(_ s: String, corrections: [String: String]) -> String {
        var out = s
        // Deterministic order (longest key first) so one correction's output
        // can't be re-matched by another depending on dictionary hash order.
        let ordered = corrections.sorted { ($0.key.count, $1.key) > ($1.key.count, $0.key) }
        for (wrong, right) in ordered {
            out = out.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b",
                with: NSRegularExpression.escapedTemplate(for: right),
                options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    // "replace foo with bar" / "Claude, replace foo with bar" adds a
    // permanent transcription correction; "forget replacement foo" removes it.
    static let replaceRegex = try! NSRegularExpression(
        pattern: "^(?:claude[,\\s]+)?replace\\s+(.+?)\\s+with\\s+(.+?)[.!?]*$",
        options: [.caseInsensitive])
    static let forgetRegex = try! NSRegularExpression(
        pattern: "^(?:claude[,\\s]+)?(?:forget|remove)(?: the)? replacement\\s+(.+?)[.!?]*$",
        options: [.caseInsensitive])

    /// Long phrases are almost certainly dictation ("replace the tire with a
    /// new one"), not a vocabulary command — capped at 3 words per side.
    static func parseReplace(_ s: String) -> (wrong: String, right: String)? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = replaceRegex.firstMatch(in: s, range: range),
              let wrongR = Range(m.range(at: 1), in: s),
              let rightR = Range(m.range(at: 2), in: s) else { return nil }
        let wrong = String(s[wrongR]).lowercased().trimmingCharacters(in: .punctuationCharacters)
        let right = String(s[rightR]).trimmingCharacters(in: .punctuationCharacters)
        guard wrong.split(separator: " ").count <= 3,
              right.split(separator: " ").count <= 3 else { return nil }
        return (wrong, right)
    }

    static func parseForget(_ s: String) -> String? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = forgetRegex.firstMatch(in: s, range: range),
              let wrongR = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[wrongR]).lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    // "…read it to me" at the end of a dictated question: strip it, send the
    // question, then read the answer aloud once it has finished rendering.
    // Leading class strips joining commas/spaces but leaves the sentence's
    // own terminal punctuation intact ("What is entropy?" keeps its "?").
    static let trailingReadRegex = try! NSRegularExpression(
        pattern: "[,;:\\s]*(read it to me|read to me|read it aloud|read it out loud|read out loud|read aloud|read the answer)[.!?\\s]*$",
        options: [.caseInsensitive])

    static func stripTrailingReadCommand(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = trailingReadRegex.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text), r.lowerBound > text.startIndex else { return nil }
        let rest = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    // "Hey Claude" wake word: requires a greeting word so ordinary sentences
    // starting with "Claude"/"cloud" don't trigger. Tolerates common mishears.
    static let wakeRegex = try! NSRegularExpression(
        pattern: "\\b(hey|hi|ok|okay)[ ,]+(claude|claud|cloud|clod)\\b[.,!?:; ]*",
        options: [.caseInsensitive])

    /// nil when no wake phrase; otherwise the text spoken after it ("" if none).
    static func wakeRemainder(of text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = wakeRegex.firstMatch(in: text, range: range),
              let matched = Range(m.range, in: text) else { return nil }
        return String(text[matched.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    static func commandSet(_ verbs: [String], _ objects: [String]) -> Set<String> {
        var out = Set<String>()
        for v in verbs {
            for o in objects {
                out.insert("\(v) \(o)")
                out.insert("claude \(v) \(o)")
            }
        }
        return out
    }
    // "post"/"paws"/"pours" are common transcription mishears of "pause"
    static let pauseCommands = commandSet(["pause", "stop", "post", "paws", "pours"],
                                          ["listening", "dictation", "dictating"])
        .union(["pausa", "metti in pausa", "pausa ascolto", "smetti di ascoltare"])
    static let resumeCommands = commandSet(["start", "resume", "continue"], ["listening", "dictation", "dictating"])
        .union(["riprendi", "riprendi ascolto", "ascoltami"])
    static let sendCommands: Set<String> = [
        "send", "send it", "send now", "send message", "send the message",
        "claude send", "claude send it", "claude send now",
        "press enter", "press return", "hit enter", "hit return", "enter",
        "invia", "invia il messaggio", "manda", "mandalo", "invio",
    ]

    /// Last sentence/line boundary, so streamed speech never cuts mid-sentence.
    static func sentenceBoundary(in s: String) -> String.Index? {
        var best: String.Index?
        for sep in [". ", ".\n", "! ", "? ", "\n"] {
            if let r = s.range(of: sep, options: .backwards) {
                if best == nil || r.upperBound > best! { best = r.upperBound }
            }
        }
        return best
    }

    /// Carbon (keyCode, modifier mask) for a named hotkey choice; nil = off.
    /// Numeric Carbon constants: cmd 0x100, shift 0x200, option 0x800,
    /// control 0x1000; Space is keycode 49, D is 2, F18/F19 are 79/80.
    static func hotkeySpec(_ choice: String) -> (code: UInt32, mods: UInt32)? {
        switch choice {
        case "F18": return (79, 0)
        case "F19": return (80, 0)
        case "⌥ Space": return (49, 0x800)
        case "⌃⌥ Space": return (49, 0x1800)
        case "⇧⌘ D": return (2, 0x300)
        default: return nil
        }
    }
    static let hotkeyChoices = ["None", "F18", "F19", "⌥ Space", "⌃⌥ Space", "⇧⌘ D"]

    /// Longest matching bundle-id prefix wins.
    static func profileValue(bundleID: String?, profiles: [String: Any]?, key: String) -> Any? {
        guard let bid = bundleID?.lowercased(), let profiles else { return nil }
        var bestLen = -1
        var best: Any?
        for (prefix, v) in profiles {
            guard bid.hasPrefix(prefix.lowercased()), prefix.count > bestLen,
                  let m = v as? [String: Any], let value = m[key] else { continue }
            bestLen = prefix.count
            best = value
        }
        return best
    }

    static func trimPageJunk(_ s: String) -> String {
        var out = s
        for marker in ["\nRelated", "\nSources", "Ask a follow-up", "Ask anything",
                       "\nPeople also ask", "\nFeedback", "\nSearch instead",
                       "\nDive deeper", "\nExport", "\nRewrite"] {
            if let r = out.range(of: marker, options: .caseInsensitive) {
                out = String(out[..<r.lowerBound])
            }
        }
        return out
    }
}

// MARK: - Self tests (pure logic only; run with --selftest, used by CI)

func runSelfTests() -> Int {
    var failures = 0
    func expect(_ cond: Bool, _ name: String) {
        if cond { print("PASS  \(name)") }
        else { failures += 1; print("FAIL  \(name)") }
    }
    typealias T = TextProcessing

    expect(T.normalizeCommand("Stop listening.") == "stop listening", "normalize strips case+punctuation")
    expect(T.normalizeCommand("  Pausa,   ascolto! ") == "pausa ascolto", "normalize collapses spaces")

    expect(T.pauseCommands.contains("stop listening"), "pause set has 'stop listening'")
    expect(T.pauseCommands.contains("claude pause dictation"), "pause set has prefixed variant")
    expect(T.pauseCommands.contains("pausa"), "pause set has Italian")
    expect(T.sendCommands.contains("send it") && T.sendCommands.contains("invia"), "send set EN+IT")
    expect(T.resumeCommands.contains("start listening"), "resume set has 'start listening'")

    expect(T.stripFillers("Um, I think so") == "I think so", "filler: leading um")
    expect(T.stripFillers("so, um, yes uh maybe") == "so, yes maybe", "filler: mid-sentence")
    expect(T.stripFillers("yummy hummus summer") == "yummy hummus summer", "filler: no false positives inside words")
    expect(T.stripFillers("uh-huh, sure") == "uh-huh, sure", "filler: hyphenated interjection kept")
    expect(T.stripFillers("Ehm, ciao") == "ciao", "filler: Italian ehm")
    expect(T.stripFillers("Hmm.") == "", "filler: lone filler becomes empty")

    let corr = ["madre": "marginally", "a i": "AI"]
    expect(T.applyCorrections("say madre now", corrections: corr) == "say marginally now", "corrections: word replaced")
    expect(T.applyCorrections("madres", corrections: corr) == "madres", "corrections: word boundary respected")
    expect(T.applyCorrections("MADRE", corrections: corr) == "marginally", "corrections: case-insensitive")

    expect(T.parseReplace("Replace madre with marginally.")! == ("madre", "marginally"), "parseReplace basic")
    expect(T.parseReplace("Claude, replace a i with AI")! == ("a i", "AI"), "parseReplace with prefix")
    expect(T.parseReplace("replace the tire of my car with a new tire please") == nil, "parseReplace rejects long phrases")
    expect(T.parseForget("forget replacement madre") == "madre", "parseForget basic")

    expect(T.stripTrailingReadCommand("What is entropy? Read it to me") == "What is entropy?", "trailing read stripped")
    expect(T.stripTrailingReadCommand("Explain this, read it to me") == "Explain this", "trailing read after comma")
    expect(T.stripTrailingReadCommand("read it to me") == nil, "lone read command not treated as dictation")

    expect(T.wakeRemainder(of: "Hey Claude, what's the weather") == "what's the weather", "wake: remainder extracted")
    expect(T.wakeRemainder(of: "Claude is a model") == nil, "wake: needs greeting word")
    expect(T.wakeRemainder(of: "okay cloud open my notes") == "open my notes", "wake: mishear tolerated")
    expect(T.wakeRemainder(of: "Hey Claude") == "", "wake: empty remainder")

    if let cut = T.sentenceBoundary(in: "One. Two") {
        expect(String("One. Two"[..<cut]) == "One. ", "sentence boundary after first sentence")
    } else {
        failures += 1; print("FAIL  sentence boundary found none")
    }
    expect(T.trimPageJunk("the answer\nRelated questions\nmore") == "the answer", "page junk trimmed")

    let profiles: [String: Any] = ["com.anthropic.": ["commitDelay": 0.7],
                                   "com.anthropic.claudefordesktop": ["commitDelay": 1.5]]
    expect((T.profileValue(bundleID: "com.anthropic.claudefordesktop", profiles: profiles, key: "commitDelay") as? Double) == 1.5,
           "profile: longest prefix wins")
    expect((T.profileValue(bundleID: "com.anthropic.other", profiles: profiles, key: "commitDelay") as? Double) == 0.7,
           "profile: shorter prefix fallback")
    expect(T.profileValue(bundleID: "com.apple.dt.Xcode", profiles: profiles, key: "commitDelay") == nil,
           "profile: no match returns nil")

    expect(T.hotkeySpec("F18")! == (79, 0), "hotkey: F18 plain")
    expect(T.hotkeySpec("⌥ Space")! == (49, 0x800), "hotkey: option-space")
    expect(T.hotkeySpec("⇧⌘ D")! == (2, 0x300), "hotkey: shift-cmd-D")
    expect(T.hotkeySpec("None") == nil, "hotkey: none disables")
    expect(T.hotkeyChoices.allSatisfy { $0 == "None" || T.hotkeySpec($0) != nil },
           "hotkey: every offered choice resolves")

    print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
    return failures
}

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

// MARK: - Optional persistent history (explicit opt-in: writes speech to disk)

enum HistoryStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisper", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    static func append(_ text: String) {
        guard Defaults.historyEnabled else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Compact instead of growing forever: past ~2 MB, keep the newest
        // 1000 entries.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > 2_000_000 {
            let keep = load(limit: 1000)
            let iso = ISO8601DateFormatter()
            let rewritten = keep.compactMap { entry -> String? in
                guard let d = try? JSONSerialization.data(withJSONObject: ["t": iso.string(from: entry.date), "x": entry.text]) else { return nil }
                return String(data: d, encoding: .utf8)
            }.joined(separator: "\n") + "\n"
            try? rewritten.data(using: .utf8)?.write(to: url)
        }
        let entry: [String: String] = ["t": ISO8601DateFormatter().string(from: Date()), "x": text]
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        let line = data + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    static func load(limit: Int = 2000) -> [(date: Date, text: String)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        return raw.split(separator: "\n").suffix(limit).compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let t = obj["t"], let x = obj["x"], let d = iso.date(from: t) else { return nil }
            return (d, x)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Optional dictation journal (explicit opt-in: writes speech to disk)

enum Journal {
    static func append(_ text: String) {
        guard let dirPath = Defaults.journalDir, !dirPath.isEmpty else { return }
        let dir = URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Fixed locale/calendar: a system set to a non-Gregorian calendar
        // must not produce files named for year 2569.
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        let now = Date()
        let url = dir.appendingPathComponent("\(day.string(from: now)).md")
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        var line = "- \(time.string(from: now)) — \(oneLine)\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            line = "# Dictation journal — \(day.string(from: now))\n\n" + line
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
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
    private var bufPrimary = ""
    private var bufSecondary = ""
    private var confPrimarySum = 0.0
    private var confPrimaryWeight = 0.0
    private var confSecondarySum = 0.0
    private var confSecondaryWeight = 0.0
    private var secondarySawSpeech = false
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

    private static let pauseCommands = TextProcessing.pauseCommands
    private static let resumeCommands = TextProcessing.resumeCommands
    private static let sendCommands = TextProcessing.sendCommands
    private static let italianCommands: Set<String> = [
        "switch to italian", "italian mode", "speak italian", "dictate in italian",
        "italiano", "parla italiano", "in italiano", "detta in italiano",
    ]
    private static let englishCommands: Set<String> = [
        "switch to english", "english mode", "speak english", "dictate in english",
        "inglese", "parla inglese", "in inglese", "passa allinglese", "detta in inglese",
    ]
    private static let scratchCommands: Set<String> = [
        "scratch that", "scratch it", "delete that", "delete it",
        "undo", "undo that", "undo it",
    ]
    private static let talkOnCommands: Set<String> = [
        "talk mode", "talk mode on", "talkmode", "talkmode on",
        "voice mode", "voice mode on", "torque mode",
    ]
    private static let talkOffCommands: Set<String> = [
        "talk mode off", "talkmode off", "voice mode off", "text mode",
        "stop talk mode", "stop talkmode", "talk mode of",
    ]
    private static let readCommands: Set<String> = [
        "read it to me", "read to me", "read it", "read this", "read that",
        "read the answer", "read aloud", "read it aloud", "read it out loud",
        "read out loud", "leggi", "leggimelo", "leggilo", "leggimi la risposta",
    ]
    private static let stopReadCommands: Set<String> = [
        "stop reading", "stop talking", "shut up", "stop", "quiet", "silence",
        "basta", "zitto", "silenzio", "fermati",
    ]
    private static let headphoneMicCommands: Set<String> = [
        "headphone mic", "headphones mic", "headphone microphone", "headphones microphone",
        "use headphone mic", "use headphones mic", "switch to headphones", "use the headphones",
    ]
    private static let macMicCommands: Set<String> = [
        "mac mic", "apple mic", "laptop mic", "built in mic", "builtin mic",
        "mac microphone", "apple microphone", "use mac mic", "use the mac mic",
        "switch to mac mic", "switch to the mac",
    ]
    private static let newlineCommands: Set<String> = ["new line", "newline", "next line", "a capo"]
    private static let newParagraphCommands: Set<String> = ["new paragraph", "next paragraph", "nuovo paragrafo"]
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

    private func frontmostIsAnthropic() -> Bool {
        (NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() ?? "")
            .hasPrefix("com.anthropic.")
    }

    private var lastWakeActivation = Date.distantPast

    private func activateClaudeApp() {
        lastWakeActivation = Date()
        let ws = NSWorkspace.shared
        if let running = ws.runningApplications.first(where: {
            ($0.bundleIdentifier?.lowercased() ?? "").hasPrefix("com.anthropic.")
        }) {
            running.activate()
        } else if let url = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func handleWake(remainder: String) {
        DLog.log("wake word: activating Claude (remainder \(remainder.count) chars)")
        if muted { setMuted(false) }
        NSSound(named: "Pop")?.play()
        activateClaudeApp()
        // Drop anything both engines buffered for this utterance — the
        // trailing secondary final still carries the raw "hey claude …" text
        // and must not win the confidence pick at commit.
        clearUtteranceBuffers()
        guard !remainder.isEmpty else { return }
        var attempts = 0
        func tryType() {
            attempts += 1
            if self.frontmostIsAnthropic() {
                // Queue it like a dictated utterance; commit types and sends.
                self.clearUtteranceBuffers()
                self.bufPrimary = remainder
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
                secondarySawSpeech = true
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
                if Self.pauseCommands.contains(where: { $0.count >= 10 && v.contains($0) }) {
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
               !frontmostIsAnthropic() {
                DLog.log("wake word (volatile): pre-activating Claude")
                NSSound(named: "Pop")?.play()
                activateClaudeApp()
            }
            if !muted, Defaults.showCaptions {
                captions.show(bufPrimary + " " + text)
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
        // While the Mac itself is speaking, the mic may be hearing our own
        // voice — accept only "stop", ignore everything else.
        if SpeechOut.shared.isSpeaking {
            if Self.stopReadCommands.contains(command) {
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
        // Mute must work even when the phrase is embedded in other speech
        // (e.g. a video playing in the room) — match it anywhere. Muting on a
        // false positive is harmless; "start listening" undoes it.
        if Self.pauseCommands.contains(command)
            || Self.pauseCommands.contains(where: { $0.count >= 10 && command.contains($0) }) {
            if !muted { setMuted(true) }
            return
        }
        if Self.talkOffCommands.contains(command) {
            DLog.log("voice command: talk mode off")
            Defaults.talkMode = false
            SpeechOut.shared.stop()
            NSSound(named: "Bottle")?.play()
            onStateChange?()
            return
        }
        if Self.talkOnCommands.contains(command) {
            DLog.log("voice command: talk mode on")
            Defaults.talkMode = true
            NSSound(named: "Glass")?.play()
            onStateChange?()
            return
        }
        if Self.italianCommands.contains(command) || Self.englishCommands.contains(command) {
            if secondaryLocale != nil {
                DLog.log("language command ignored — dual language is automatic")
                NSSound(named: "Pop")?.play()
            } else {
                switchLocale(Self.italianCommands.contains(command) ? "it-IT" : "en-GB")
            }
            return
        }
        if muted {
            if Self.resumeCommands.contains(command) { setMuted(false) }
            else { DLog.log("muted; ignored a phrase (\(cleaned.count) chars)") }
            return
        }
        if Self.sendCommands.contains(command) {
            DLog.log("voice command: send now")
            commitUtterance(force: true)
            return
        }
        if Self.readCommands.contains(command) {
            doReadAloud()
            return
        }
        if Self.newlineCommands.contains(command) || Self.newParagraphCommands.contains(command) {
            doNewline(Self.newParagraphCommands.contains(command) ? 2 : 1)
            return
        }
        if Self.headphoneMicCommands.contains(command) { switchMic(builtIn: false); return }
        if Self.macMicCommands.contains(command) { switchMic(builtIn: true); return }
        if handleDictionaryCommand(cleaned) { return }
        if Self.scratchCommands.contains(command) {
            if !bufPrimary.isEmpty || !bufSecondary.isEmpty {
                DLog.log("voice command: scratch (cleared pending utterance)")
                clearUtteranceBuffers()
                pendingSinceCommit = false
                captions.hide()
            } else {
                doScratchTyped()
            }
            onStateChange?()
            return
        }
        // Accumulate; both models' text is compared and typed at commit time.
        pendingSinceCommit = true
        let weight = Double(cleaned.count)
        if secondary {
            bufSecondary += (bufSecondary.isEmpty ? "" : " ") + cleaned
            if confidence >= 0 {
                confSecondarySum += confidence * weight
                confSecondaryWeight += weight
            }
        } else {
            bufPrimary += (bufPrimary.isEmpty ? "" : " ") + cleaned
            if confidence >= 0 {
                confPrimarySum += confidence * weight
                confPrimaryWeight += weight
            }
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
        let silentFor = Date().timeIntervalSince(lastVoiceAt)
        let sinceFinal = Date().timeIntervalSince(lastFinalAt)
        // With two models racing, wait for both to report (the slower one's
        // final can trail) — but only if the second model actually heard
        // something, and never longer than 0.9s.
        let bothReported = secondaryLocale == nil || (!bufPrimary.isEmpty && !bufSecondary.isEmpty)
        let stillExpectingSecond = !bothReported && secondarySawSpeech && bufSecondary.isEmpty
        // A lone low-confidence transcript is probably the other language
        // misheard — wait longer for the second engine to rescue it.
        let cPrimary = confPrimaryWeight > 0 ? confPrimarySum / confPrimaryWeight : 1.0
        // Short garble scores deceptively high confidence, so short
        // utterances need a higher bar before we trust a lone transcript.
        let confBar = bufPrimary.count < 25 ? 0.75 : 0.5
        let suspicious = secondaryLocale != nil && !bothReported && !bufPrimary.isEmpty && cPrimary < confBar
        let slowModelGrace: Double = bothReported ? 0.2 : (suspicious ? 3.0 : (stillExpectingSecond ? 0.9 : 0.2))
        if pendingSinceCommit, !muted, silentFor > Defaults.effectiveCommitDelay, sinceFinal > slowModelGrace, volatilePreview.isEmpty {
            commitUtterance()
        } else if !pendingSinceCommit,
                  silentFor > 60,
                  Date().timeIntervalSince(sessionStartedAt) > 300 {
            // Periodic hygiene: fresh analyzers after long silence.
            rotateSessions()
        } else if silentFor < 5,
                  Date().timeIntervalSince(lastResultAt) > 15,
                  Date().timeIntervalSince(sessionStartedAt) > 20 {
            // Watchdog: voice is present but the engines have gone mute — a
            // dead results stream would otherwise deafen us until 60s of
            // silence, which never comes while the user keeps talking.
            DLog.log("watchdog: engines silent while voice present — rotating sessions")
            rotateSessions()
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
        if bufSecondary.isEmpty { return bufPrimary }
        if bufPrimary.isEmpty { return bufSecondary }
        let cEN = confPrimaryWeight > 0 ? confPrimarySum / confPrimaryWeight : -1
        let cIT = confSecondaryWeight > 0 ? confSecondarySum / confSecondaryWeight : -1
        if cEN >= 0, cIT >= 0 {
            DLog.log(String(format: "confidence pick: en=%.3f it=%.3f -> %@", cEN, cIT, cIT > cEN ? "it" : "en"))
            return cIT > cEN ? bufSecondary : bufPrimary
        }
        // Fallback when the engine reports no confidence.
        func score(_ text: String, _ lang: NLLanguage) -> Double {
            let r = NLLanguageRecognizer()
            r.processString(text)
            return r.languageHypotheses(withMaximum: 5)[lang] ?? 0
        }
        let en = score(bufPrimary, .english)
        let it = score(bufSecondary, .italian)
        DLog.log(String(format: "language pick (fallback): en=%.2f it=%.2f -> %@", en, it, it > en ? "it" : "en"))
        return it > en ? bufSecondary : bufPrimary
    }

    private func clearUtteranceBuffers() {
        bufPrimary = ""
        bufSecondary = ""
        confPrimarySum = 0; confPrimaryWeight = 0
        confSecondarySum = 0; confSecondaryWeight = 0
        secondarySawSpeech = false
    }

    private func commitUtterance(force: Bool = false) {
        var force = force
        pendingSinceCommit = false
        var chosen = chooseUtterance()
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
            let cmd = normalizeCommand(chosen)
            if Self.pauseCommands.contains(cmd)
                || Self.pauseCommands.contains(where: { $0.count >= 10 && cmd.contains($0) }) {
                DLog.log("commit: assembled utterance is a mute command — muting, not typing")
                setMuted(true)
                return
            }
            if Self.sendCommands.contains(cmd) {
                DLog.log("commit: assembled utterance is a send command — pressing Return only")
                chosen = ""
                force = true
            } else if Self.scratchCommands.contains(cmd) {
                DLog.log("commit: assembled utterance is a scratch command")
                doScratchTyped()
                chosen = ""
            } else if Self.readCommands.contains(cmd) {
                doReadAloud()
                chosen = ""
            } else if Self.newlineCommands.contains(cmd) || Self.newParagraphCommands.contains(cmd) {
                doNewline(Self.newParagraphCommands.contains(cmd) ? 2 : 1)
                chosen = ""
            } else if Self.talkOnCommands.contains(cmd) || Self.talkOffCommands.contains(cmd) {
                Defaults.talkMode = Self.talkOnCommands.contains(cmd)
                DLog.log("commit: assembled utterance is a talk-mode command")
                chosen = ""
            } else if Self.headphoneMicCommands.contains(cmd) {
                switchMic(builtIn: false)
                chosen = ""
            } else if Self.macMicCommands.contains(cmd) {
                switchMic(builtIn: true)
                chosen = ""
            } else if Self.resumeCommands.contains(cmd)
                        || Self.italianCommands.contains(cmd) || Self.englishCommands.contains(cmd) {
                // Not meaningful at commit time — but never type them either.
                DLog.log("commit: dropped assembled command (\(cmd.count) chars)")
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

// MARK: - Settings window

@MainActor
final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private weak var controller: ListeningController?

    private let commitLabel = NSTextField(labelWithString: "")
    private lazy var commitSlider: NSSlider = {
        let s = NSSlider(value: Defaults.commitDelay, minValue: 0.3, maxValue: 3.0,
                         target: self, action: #selector(commitChanged(_:)))
        s.widthAnchor.constraint(equalToConstant: 190).isActive = true
        return s
    }()
    private let thresholdLabel = NSTextField(labelWithString: "")
    private lazy var thresholdSlider: NSSlider = {
        let s = NSSlider(value: Defaults.voiceThreshold, minValue: 0.003, maxValue: 0.05,
                         target: self, action: #selector(thresholdChanged(_:)))
        s.widthAnchor.constraint(equalToConstant: 190).isActive = true
        return s
    }()
    private let primaryPopup = NSPopUpButton()
    private let secondaryPopup = NSPopUpButton()
    private lazy var hotkeyPopup: NSPopUpButton = {
        let p = NSPopUpButton()
        p.addItems(withTitles: TextProcessing.hotkeyChoices)
        p.selectItem(withTitle: Defaults.hotkeyChoice)
        p.target = self
        p.action = #selector(hotkeyChanged(_:))
        return p
    }()
    private lazy var prefixesField: NSTextField = {
        let tf = NSTextField(string: allowedTargetPrefixes().joined(separator: ", "))
        tf.target = self
        tf.action = #selector(prefixesChanged(_:))
        (tf.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        tf.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return tf
    }()
    private let correctionsPopup = NSPopUpButton()
    private var correctionKeys: [String] = []
    private lazy var wrongField: NSTextField = {
        let tf = NSTextField(string: "")
        tf.placeholderString = "heard"
        tf.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return tf
    }()
    private lazy var rightField: NSTextField = {
        let tf = NSTextField(string: "")
        tf.placeholderString = "should be"
        tf.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return tf
    }()

    func show(controller: ListeningController) {
        self.controller = controller
        if window == nil { build() }
        refreshCorrections()
        populateLocales()
        // Re-sync from defaults: the menu's per-app toggle may have changed
        // the list since this field was created.
        prefixesField.stringValue = allowedTargetPrefixes().joined(separator: ", ")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }
    private func hint(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }
    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 8
        g.columnSpacing = 10
        g.column(at: 0).xPlacement = .trailing
        return g
    }
    private func check(_ title: String, key: String, initial: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.state = initial ? .on : .off
        return b
    }

    private func build() {
        commitLabel.stringValue = String(format: "%.1f s", Defaults.commitDelay)
        thresholdLabel.stringValue = String(format: "%.3f", Defaults.voiceThreshold)
        primaryPopup.target = self
        primaryPopup.action = #selector(primaryChanged(_:))
        secondaryPopup.target = self
        secondaryPopup.action = #selector(secondaryChanged(_:))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(header("Dictation"))
        stack.addArrangedSubview(grid([
            [label("Auto-send pause"), commitSlider, commitLabel],
            [label("Voice threshold"), thresholdSlider, thresholdLabel],
            [label("Toggle hotkey"), hotkeyPopup],
        ]))
        stack.addArrangedSubview(check("Auto-send (press Return after a pause)", key: "autoReturn", initial: Defaults.autoReturn))
        stack.addArrangedSubview(check("Type into any app", key: "anyApp", initial: Defaults.anyApp))
        stack.addArrangedSubview(check("Insert via clipboard paste (compatibility)", key: "insertViaPaste", initial: Defaults.insertViaPaste))
        stack.addArrangedSubview(check("Remove filler words (um, uh, ehm)", key: "removeFillers", initial: Defaults.removeFillers))
        stack.addArrangedSubview(check("Show live captions", key: "showCaptions", initial: Defaults.showCaptions))

        stack.addArrangedSubview(header("Languages"))
        stack.addArrangedSubview(grid([
            [label("Primary"), primaryPopup],
            [label("Secondary"), secondaryPopup],
        ]))
        stack.addArrangedSubview(hint("Both run in parallel; each sentence goes to the language that understood it."))

        stack.addArrangedSubview(header("Auto-send apps"))
        stack.addArrangedSubview(grid([[label("Bundle prefixes"), prefixesField]]))
        stack.addArrangedSubview(hint("Comma-separated bundle-id prefixes that get typing + auto-Return."))

        stack.addArrangedSubview(header("Personal dictionary"))
        correctionsPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        stack.addArrangedSubview(grid([
            [correctionsPopup, NSButton(title: "Remove", target: self, action: #selector(removeCorrection))],
            [wrongField, rightField, NSButton(title: "Add", target: self, action: #selector(addCorrection))],
        ]))
        stack.addArrangedSubview(hint("Or just say: “replace madre with marginally”."))

        stack.addArrangedSubview(header("Privacy & startup"))
        stack.addArrangedSubview(check("Launch muted (until “start listening”)", key: "startMuted", initial: Defaults.startMuted))
        stack.addArrangedSubview(check("Copy transcript to clipboard when typing isn't possible", key: "stashToClipboard", initial: Defaults.stashToClipboard))
        stack.addArrangedSubview(check("Keep searchable dictation history (writes speech to disk)", key: "historyEnabled", initial: Defaults.historyEnabled))
        stack.addArrangedSubview(NSButton(title: "Open History…", target: self, action: #selector(openHistory)))

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "OpenWhisper Settings"
        w.isReleasedWhenClosed = false
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
        window = w
    }

    private func populateLocales() {
        Task { [weak self] in
            let ids = await SpeechTranscriber.supportedLocales
                .map { $0.identifier(.bcp47) }
                .sorted()
            guard let self else { return }
            self.primaryPopup.removeAllItems()
            self.primaryPopup.addItems(withTitles: ids)
            self.primaryPopup.selectItem(withTitle: self.controller?.currentLocaleID
                                            ?? Defaults.localeOverride ?? "en-GB")
            self.secondaryPopup.removeAllItems()
            self.secondaryPopup.addItem(withTitle: "None")
            self.secondaryPopup.addItems(withTitles: ids)
            if Defaults.dualLanguage {
                self.secondaryPopup.selectItem(withTitle: Defaults.secondaryLocaleID)
            } else {
                self.secondaryPopup.selectItem(at: 0)
            }
        }
    }

    private func refreshCorrections() {
        let dict = Defaults.corrections
        correctionKeys = dict.keys.sorted()
        correctionsPopup.removeAllItems()
        if correctionKeys.isEmpty {
            correctionsPopup.addItem(withTitle: "No replacements yet")
        } else {
            correctionsPopup.addItems(withTitles: correctionKeys.map { "\($0) → \(dict[$0] ?? "")" })
        }
    }

    @objc private func commitChanged(_ s: NSSlider) {
        Defaults.d.set(s.doubleValue, forKey: "commitDelay")
        commitLabel.stringValue = String(format: "%.1f s", s.doubleValue)
    }
    @objc private func thresholdChanged(_ s: NSSlider) {
        Defaults.d.set(s.doubleValue, forKey: "voiceThreshold")
        thresholdLabel.stringValue = String(format: "%.3f", s.doubleValue)
    }
    @objc private func checkChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        Defaults.d.set(sender.state == .on, forKey: key)
    }
    @objc private func primaryChanged(_ p: NSPopUpButton) {
        guard let id = p.titleOfSelectedItem else { return }
        controller?.setPrimaryLocale(id)
    }
    @objc private func secondaryChanged(_ p: NSPopUpButton) {
        let title = p.titleOfSelectedItem
        controller?.setSecondaryLocale(title == "None" ? nil : title)
    }
    @objc private func prefixesChanged(_ tf: NSTextField) {
        let arr = tf.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if arr.isEmpty {
            // An emptied field means "back to defaults", not "no app ever
            // gets auto-send with no way to recover".
            Defaults.d.removeObject(forKey: "targetBundlePrefixes")
            tf.stringValue = allowedTargetPrefixes().joined(separator: ", ")
        } else {
            Defaults.d.set(arr, forKey: "targetBundlePrefixes")
        }
    }
    @objc private func removeCorrection() {
        let i = correctionsPopup.indexOfSelectedItem
        guard i >= 0, i < correctionKeys.count else { return }
        var dict = Defaults.corrections
        dict.removeValue(forKey: correctionKeys[i])
        Defaults.corrections = dict
        refreshCorrections()
    }
    @objc private func addCorrection() {
        let wrong = wrongField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let right = rightField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !wrong.isEmpty, !right.isEmpty else { return }
        var dict = Defaults.corrections
        dict[wrong] = right
        Defaults.corrections = dict
        wrongField.stringValue = ""
        rightField.stringValue = ""
        refreshCorrections()
    }
    @objc private func hotkeyChanged(_ p: NSPopUpButton) {
        Defaults.hotkeyChoice = p.titleOfSelectedItem ?? "None"
        AppDelegate.shared?.reregisterHotkey()
    }
    @objc private func openHistory() { HistoryWindow.shared.show() }
}

// MARK: - History window

@MainActor
final class HistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = HistoryWindow()
    private var window: NSWindow?
    private let table = NSTableView()
    private let search = NSSearchField()
    private var all: [(date: Date, text: String)] = []
    private var filtered: [(date: Date, text: String)] = []
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    func show() {
        all = HistoryStore.load().reversed()
        if window == nil { build() }
        applyFilter()
        table.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let timeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("t"))
        timeCol.title = "When"
        timeCol.width = 100
        let textCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("x"))
        textCol.title = "Dictation"
        textCol.width = 430
        table.addTableColumn(timeCol)
        table.addTableColumn(textCol)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(copySelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true

        search.target = self
        search.action = #selector(searchChanged(_:))
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let buttons = NSStackView(views: [
            NSButton(title: "Copy Selected", target: self, action: #selector(copySelected)),
            NSButton(title: "Clear History…", target: self, action: #selector(clearAll)),
        ])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [search, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Dictation History"
        w.isReleasedWhenClosed = false
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
        window = w
    }

    private func applyFilter() {
        let q = search.stringValue.lowercased()
        filtered = q.isEmpty ? all : all.filter { $0.text.lowercased().contains(q) }
    }

    @objc private func searchChanged(_ s: NSSearchField) {
        applyFilter()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let value = tableColumn?.identifier.rawValue == "t"
            ? df.string(from: filtered[row].date)
            : filtered[row].text
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = table.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let l = NSTextField(labelWithString: "")
            l.identifier = id
            l.lineBreakMode = .byTruncatingTail
            return l
        }()
        cell.stringValue = value
        return cell
    }

    @objc private func copySelected() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(filtered[row].text, forType: .string)
    }

    @objc private func clearAll() {
        let a = NSAlert()
        a.messageText = "Delete all dictation history?"
        a.informativeText = "This removes the history file permanently."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            HistoryStore.clear()
            all = []
            applyFilter()
            table.reloadData()
        }
    }
}

// MARK: - App delegate / menu bar UI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?
    let controller = ListeningController()
    var statusItem: NSStatusItem!
    var uiTimer: Timer?

    private var hotkeyRef: EventHotKeyRef?

    /// Optional global hotkey that toggles listening — voice stays primary,
    /// this is for users who want a physical switch too. Configurable in
    /// Settings; F18 by default (absent from regular keyboards, so it's
    /// harmless until someone with a macro pad or full-size board wants it).
    private func installHotkeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async {
                AppDelegate.shared?.controller.toggleMute()
                DLog.log("hotkey: listen toggle")
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func reregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        guard let spec = TextProcessing.hotkeySpec(Defaults.hotkeyChoice) else { return }
        RegisterEventHotKey(spec.code, spec.mods,
                            EventHotKeyID(signature: OSType(0x4F575031), id: 1),
                            GetEventDispatcherTarget(), 0, &hotkeyRef)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the login-item registration so it tracks the app's current
        // path (the bundle was renamed TalkToClaude.app -> OpenWhisper.app).
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.register()
        }
        showWelcomeIfFirstRun()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        controller.onStateChange = { [weak self] in self?.refreshUI() }
        refreshUI()
        installHotkeyHandler()
        reregisterHotkey()
        Task { await controller.start() }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        RunLoop.main.add(t, forMode: .common)
        uiTimer = t
    }

    func refreshIcon() {
        // Every active state carries an explicit tint: an untinted template
        // waveform renders near-black over light wallpapers and the user
        // can't tell the app is on. Grey (template) now means exactly
        // "not listening".
        let (symbol, tint): (String, NSColor?) = {
            switch controller.state {
            case .starting: return ("hourglass", nil)
            case .downloadingModel: return ("arrow.down.circle", nil)
            case .paused: return ("waveform.slash", nil)
            case .failed: return ("exclamationmark.triangle", .systemYellow)
            case .listening:
                if controller.muted { return ("waveform.slash", .systemOrange) }
                return controller.speaking ? ("waveform.circle.fill", .systemRed) : ("waveform", .systemGreen)
            }
        }()
        let base = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let img: NSImage?
        if let tint {
            // Bake the color into the image itself. Relying on the status
            // button's contentTintColor fails once a symbol configuration is
            // attached — the glyph renders in its natural black and vanishes
            // against a dark menu bar.
            img = NSImage(systemSymbolName: symbol, accessibilityDescription: "OpenWhisper")?
                .withSymbolConfiguration(base.applying(.init(paletteColors: [tint])))
            img?.isTemplate = false
        } else {
            img = NSImage(systemSymbolName: symbol, accessibilityDescription: "OpenWhisper")?
                .withSymbolConfiguration(base)
            img?.isTemplate = true
        }
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = nil
    }

    var failureAlertShown = false
    func refreshUI() {
        refreshIcon()
        // The menu is populated lazily in menuWillOpen so items like
        // "Auto-send in <app>" reflect the app that's frontmost right now.
        if statusItem.menu == nil {
            let m = NSMenu()
            m.delegate = self
            statusItem.menu = m
        }
        // Re-arm the alert once we recover, so a later, different failure
        // isn't silently swallowed.
        if controller.state == .listening { failureAlertShown = false }
        if case .failed(let msg) = controller.state, !failureAlertShown {
            failureAlertShown = true
            let alert = NSAlert()
            alert.messageText = "OpenWhisper can't listen"
            alert.informativeText = msg
            alert.runModal()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        fillMenu(menu)
    }

    func fillMenu(_ menu: NSMenu) {
        let statusText: String
        switch controller.state {
        case .starting: statusText = "Starting…"
        case .downloadingModel: statusText = "Downloading speech model…"
        case .paused: statusText = "Paused"
        case .failed(let msg): statusText = "Error: \(msg)"
        case .listening:
            if controller.muted {
                statusText = "Muted — say “start listening” to resume"
            } else {
                statusText = Defaults.anyApp ? "Listening (types into any app)" : "Listening (allowlisted apps only)"
            }
        }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if case .listening = controller.state {
            let lang = NSMenuItem(title: "Language: \(controller.languagesDescription)",
                                  action: nil, keyEquivalent: "")
            lang.isEnabled = false
            menu.addItem(lang)
        }
        if !controller.volatilePreview.isEmpty {
            let p = NSMenuItem(title: "“\(String(controller.volatilePreview.prefix(60)))…”", action: nil, keyEquivalent: "")
            p.isEnabled = false
            menu.addItem(p)
        }
        menu.addItem(.separator())

        switch controller.state {
        case .listening:
            let mute = makeItem(controller.muted ? "Unmute (or say “start listening”)"
                                                 : "Mute (or say “pause listening”)",
                                #selector(muteTapped))
            mute.state = controller.muted ? .on : .off
            menu.addItem(mute)
            menu.addItem(makeItem("Turn Mic Off Completely", #selector(pauseTapped)))
        case .paused:
            menu.addItem(makeItem("Turn Mic Back On", #selector(resumeTapped)))
        default: break
        }

        let talk = makeItem("Talk mode (read every answer aloud)", #selector(toggleTalkMode))
        talk.state = Defaults.talkMode ? .on : .off
        menu.addItem(talk)

        let autoReturn = makeItem("Auto-send (press Return after a pause)", #selector(toggleAutoReturn))
        autoReturn.state = Defaults.autoReturn ? .on : .off
        menu.addItem(autoReturn)

        let anyApp = makeItem("Type into any app (not just Claude)", #selector(toggleAnyApp))
        anyApp.state = Defaults.anyApp ? .on : .off
        menu.addItem(anyApp)

        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           bid != Bundle.main.bundleIdentifier,
           !callAppBundles.contains(bid) {
            let item = makeItem("Auto-send in \(front.localizedName ?? bid)", #selector(toggleFrontApp(_:)))
            item.state = isAllowedFrontmost() ? .on : .off
            item.representedObject = bid
            menu.addItem(item)
        }

        let paste = makeItem("Insert via clipboard paste (compatibility)", #selector(togglePasteMode))
        paste.state = Defaults.insertViaPaste ? .on : .off
        menu.addItem(paste)

        let caps = makeItem("Show live captions", #selector(toggleCaptions))
        caps.state = Defaults.showCaptions ? .on : .off
        menu.addItem(caps)

        let fillers = makeItem("Remove filler words (um, uh, ehm)", #selector(toggleFillers))
        fillers.state = Defaults.removeFillers ? .on : .off
        menu.addItem(fillers)

        let journal = makeItem(Defaults.journalDir == nil
                                ? "Journal dictations to Markdown…"
                                : "Journaling to \((Defaults.journalDir! as NSString).abbreviatingWithTildeInPath)",
                               #selector(toggleJournal))
        journal.state = Defaults.journalDir == nil ? .off : .on
        menu.addItem(journal)

        let mic = makeItem(Defaults.preferBuiltInMic
                            ? "Mic: built-in Mac (say “headphone mic” to switch)"
                            : "Mic: headphones/system default (say “mac mic” to switch)",
                           #selector(toggleBuiltInMic))
        menu.addItem(mic)

        menu.addItem(.separator())
        if !controller.lastUtterance.isEmpty {
            menu.addItem(makeItem("Copy Last Utterance", #selector(copyLast)))
        }
        if controller.recentUtterances.count > 1 {
            let recent = NSMenuItem(title: "Recent Utterances", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for utterance in controller.recentUtterances.reversed() {
                let title = utterance.count > 60 ? String(utterance.prefix(60)) + "…" : utterance
                let item = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = utterance
                sub.addItem(item)
            }
            recent.submenu = sub
            menu.addItem(recent)
        }
        if !Typist.axTrusted() {
            menu.addItem(makeItem("⚠️ Grant Accessibility Access…", #selector(openAXSettings)))
        }
        let login = makeItem("Start at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(openSettings), key: ","))
        if Defaults.historyEnabled {
            menu.addItem(makeItem("History…", #selector(openHistoryWindow)))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit OpenWhisper", #selector(quit), key: "q"))
    }

    func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc func muteTapped() { controller.toggleMute() }
    @objc func pauseTapped() { controller.pause() }
    @objc func resumeTapped() { controller.resume() }
    @objc func toggleTalkMode() { Defaults.talkMode.toggle(); refreshUI() }
    @objc func toggleAutoReturn() { Defaults.d.set(!Defaults.autoReturn, forKey: "autoReturn"); refreshUI() }
    @objc func toggleAnyApp() { Defaults.d.set(!Defaults.anyApp, forKey: "anyApp"); refreshUI() }
    @objc func togglePasteMode() { Defaults.d.set(!Defaults.insertViaPaste, forKey: "insertViaPaste"); refreshUI() }
    @objc func toggleBuiltInMic() {
        controller.switchMic(builtIn: !Defaults.preferBuiltInMic)
        refreshUI()
    }
    @objc func toggleCaptions() {
        Defaults.d.set(!Defaults.showCaptions, forKey: "showCaptions")
        if !Defaults.showCaptions { controller.captions.hide() }
        refreshUI()
    }
    @objc func copyLast() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(controller.lastUtterance, forType: .string)
    }
    @objc func toggleFillers() { Defaults.d.set(!Defaults.removeFillers, forKey: "removeFillers"); refreshUI() }
    @objc func toggleJournal() {
        if Defaults.journalDir != nil {
            Defaults.journalDir = nil
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Journal Here"
            panel.message = "Every dictated phrase will be appended to a daily Markdown file in this folder. Spoken text is written to disk only while this is on."
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                Defaults.journalDir = url.path
            }
        }
        refreshUI()
    }
    @objc func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    @objc func openAXSettings() {
        _ = Typist.axTrusted(promptIfNeeded: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
        refreshUI()
    }
    @objc func quit() { NSApp.terminate(nil) }

    /// One-time orientation for people who just downloaded the app.
    func showWelcomeIfFirstRun() {
        guard !Defaults.d.bool(forKey: "hasLaunchedBefore") else { return }
        Defaults.d.set(true, forKey: "hasLaunchedBefore")
        let alert = NSAlert()
        alert.messageText = "Welcome to OpenWhisper"
        alert.informativeText = """
        OpenWhisper lives in the menu bar — look for the waveform icon at the \
        top of the screen (green = listening, orange = muted).

        Put the cursor in any text box and speak; your words are typed for \
        you. Say “pause listening” to mute and “start listening” to resume.

        You'll be asked for Microphone and Accessibility permissions — both \
        are needed (one to hear, one to type). Nothing you say ever leaves \
        this Mac.
        """
        alert.addButton(withTitle: "Get Started")
        alert.addButton(withTitle: "Open User Guide")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let guide = Bundle.main.url(forResource: "USER-GUIDE", withExtension: "md") {
            NSWorkspace.shared.open(guide)
        }
    }

    @objc func openSettings() { SettingsWindow.shared.show(controller: controller) }
    @objc func openHistoryWindow() { HistoryWindow.shared.show() }
    /// One click adds/removes the current app from the auto-send allowlist.
    @objc func toggleFrontApp(_ sender: NSMenuItem) {
        guard let bid = (sender.representedObject as? String)?.lowercased() else { return }
        var prefixes = allowedTargetPrefixes()
        if prefixes.contains(where: { $0.lowercased() == bid }) {
            // Only remove the exact entry this toggle added.
            prefixes.removeAll { $0.lowercased() == bid }
        } else if let broad = prefixes.first(where: { bid.hasPrefix($0.lowercased()) }) {
            // Covered by a broader prefix — removing that would silently
            // disable other apps too. Say so instead of doing it.
            let a = NSAlert()
            a.messageText = "Covered by a broader rule"
            a.informativeText = "Auto-send here comes from the prefix “\(broad)”, which may cover other apps as well. Edit the list in Settings if you want to change it."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        } else {
            prefixes.append(bid)
        }
        Defaults.d.set(prefixes, forKey: "targetBundlePrefixes")
        refreshUI()
    }
}

// MARK: - Entry point

@main
struct OpenWhisperMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            exit(runSelfTests() == 0 ? 0 : 1)
        }
        if args.contains("--version") {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            print("OpenWhisper \(v)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--transcribe"), args.count > i + 1 {
            let path = args[i + 1]
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let text = try await transcribeFile(path: path)
                    print(text)
                    sema.signal()
                } catch {
                    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            sema.wait()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
