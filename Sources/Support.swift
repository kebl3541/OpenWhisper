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

