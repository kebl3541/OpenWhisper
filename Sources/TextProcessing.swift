import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import NaturalLanguage
import ScreenCaptureKit
import Speech
import ServiceManagement
import Vision

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
    static let italianCommands: Set<String> = [
        "switch to italian", "italian mode", "speak italian", "dictate in italian",
        "italiano", "parla italiano", "in italiano", "detta in italiano",
    ]
    static let englishCommands: Set<String> = [
        "switch to english", "english mode", "speak english", "dictate in english",
        "inglese", "parla inglese", "in inglese", "passa allinglese", "detta in inglese",
    ]
    static let scratchCommands: Set<String> = [
        "scratch that", "scratch it", "delete that", "delete it",
        "undo", "undo that", "undo it",
    ]
    static let talkOnCommands: Set<String> = [
        "talk mode", "talk mode on", "talkmode", "talkmode on",
        "voice mode", "voice mode on", "torque mode",
    ]
    static let talkOffCommands: Set<String> = [
        "talk mode off", "talkmode off", "voice mode off", "text mode",
        "stop talk mode", "stop talkmode", "talk mode of",
    ]
    static let readCommands: Set<String> = [
        "read it to me", "read to me", "read it", "read this", "read that",
        "read the answer", "read aloud", "read it aloud", "read it out loud",
        "read out loud", "leggi", "leggimelo", "leggilo", "leggimi la risposta",
    ]
    static let stopReadCommands: Set<String> = [
        "stop reading", "stop talking", "shut up", "stop", "quiet", "silence",
        "basta", "zitto", "silenzio", "fermati",
    ]
    static let headphoneMicCommands: Set<String> = [
        "headphone mic", "headphones mic", "headphone microphone", "headphones microphone",
        "use headphone mic", "use headphones mic", "switch to headphones", "use the headphones",
    ]
    static let macMicCommands: Set<String> = [
        "mac mic", "apple mic", "laptop mic", "built in mic", "builtin mic",
        "mac microphone", "apple microphone", "use mac mic", "use the mac mic",
        "switch to mac mic", "switch to the mac",
    ]
    static let newlineCommands: Set<String> = ["new line", "newline", "next line", "a capo"]
    static let newParagraphCommands: Set<String> = ["new paragraph", "next paragraph", "nuovo paragrafo"]

    /// Every standalone voice command, as one value. `parseCommand` is the
    /// single source of truth both dispatchers consume — the live-final path
    /// and the commit-time re-check (which exists because a command phrase
    /// can arrive split across two engine finals and reassemble in the
    /// buffer). Add a command here once; both paths see it.
    enum Command: Equatable {
        case pause, resume, send, scratch, read, stopRead
        case talkOn, talkOff
        case micHeadphone, micBuiltIn
        case newline(Int)
        case languageItalian, languageEnglish
    }

    /// `normalized` must be the output of `normalizeCommand`. Substring
    /// matching applies only to long pause phrases — muting embedded in
    /// other speech is harmless, everything else must match exactly.
    static func parseCommand(_ normalized: String) -> Command? {
        if pauseCommands.contains(normalized)
            || pauseCommands.contains(where: { $0.count >= 10 && normalized.contains($0) }) {
            return .pause
        }
        if resumeCommands.contains(normalized) { return .resume }
        if sendCommands.contains(normalized) { return .send }
        if scratchCommands.contains(normalized) { return .scratch }
        if readCommands.contains(normalized) { return .read }
        if stopReadCommands.contains(normalized) { return .stopRead }
        if talkOffCommands.contains(normalized) { return .talkOff }
        if talkOnCommands.contains(normalized) { return .talkOn }
        if headphoneMicCommands.contains(normalized) { return .micHeadphone }
        if macMicCommands.contains(normalized) { return .micBuiltIn }
        if newParagraphCommands.contains(normalized) { return .newline(2) }
        if newlineCommands.contains(normalized) { return .newline(1) }
        if italianCommands.contains(normalized) { return .languageItalian }
        if englishCommands.contains(normalized) { return .languageEnglish }
        return nil
    }

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

    /// One engine's accumulated finals for the current utterance.
    struct UtteranceBuffer: Equatable {
        var text = ""
        var confSum = 0.0
        var confWeight = 0.0
        var sawSpeech = false
        var isEmpty: Bool { text.isEmpty }
        /// Per-character weighted mean; nil when the engine reported none.
        var meanConfidence: Double? { confWeight > 0 ? confSum / confWeight : nil }
        mutating func add(_ piece: String, confidence: Double) {
            text += (text.isEmpty ? "" : " ") + piece
            if confidence >= 0 {
                confSum += confidence * Double(piece.count)
                confWeight += Double(piece.count)
            }
        }
        mutating func clear() { self = UtteranceBuffer() }
    }

    enum CommitAction: Equatable { case wait, commit, rotateIdle, rotateWatchdog }

    /// The commit gating. Every constant here was tuned against live
    /// dictation failures — change them only with a test proving the old
    /// scenario still passes:
    /// - the slower engine's final can trail by ~1s, so wait 0.9s for it,
    ///   but only if that engine actually heard speech;
    /// - a lone LOW-confidence transcript is probably the other language
    ///   misheard, so wait 3s for the second engine to rescue it;
    /// - short garble scores deceptively high confidence, so short lone
    ///   transcripts need a higher bar (0.75 vs 0.5) before we trust them.
    static func commitDecision(now: Date,
                               lastVoiceAt: Date,
                               lastFinalAt: Date,
                               lastResultAt: Date,
                               sessionStartedAt: Date,
                               pending: Bool,
                               muted: Bool,
                               volatileEmpty: Bool,
                               commitDelay: Double,
                               dual: Bool,
                               primary: UtteranceBuffer,
                               secondary: UtteranceBuffer) -> CommitAction {
        let silentFor = now.timeIntervalSince(lastVoiceAt)
        let sinceFinal = now.timeIntervalSince(lastFinalAt)
        let bothReported = !dual || (!primary.isEmpty && !secondary.isEmpty)
        let stillExpectingSecond = !bothReported && secondary.sawSpeech && secondary.isEmpty
        let cPrimary = primary.meanConfidence ?? 1.0
        let confBar = primary.text.count < 25 ? 0.75 : 0.5
        let suspicious = dual && !bothReported && !primary.isEmpty && cPrimary < confBar
        let slowModelGrace: Double = bothReported ? 0.2 : (suspicious ? 3.0 : (stillExpectingSecond ? 0.9 : 0.2))
        if pending, !muted, silentFor > commitDelay, sinceFinal > slowModelGrace, volatileEmpty {
            return .commit
        }
        if !pending, silentFor > 60, now.timeIntervalSince(sessionStartedAt) > 300 {
            return .rotateIdle
        }
        if silentFor < 5,
           now.timeIntervalSince(lastResultAt) > 15,
           now.timeIntervalSince(sessionStartedAt) > 20 {
            return .rotateWatchdog
        }
        return .wait
    }

    /// Confidence pick between the two engines' buffers. nil means neither
    /// engine reported confidence — the caller should use its text-language
    /// fallback. Assumes Apple's `.transcriptionConfidence` semantics: the
    /// wrong-language engine emits plausible words but scores ~0.2 vs ~0.95.
    static func pickUtterance(primary: UtteranceBuffer, secondary: UtteranceBuffer) -> String? {
        if secondary.isEmpty { return primary.text }
        if primary.isEmpty { return secondary.text }
        guard let a = primary.meanConfidence, let b = secondary.meanConfidence else { return nil }
        return b > a ? secondary.text : primary.text
    }

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

    expect(T.parseCommand("stop listening") == .pause, "cmd: pause exact")
    expect(T.parseCommand("i said please stop listening now") == .pause, "cmd: pause substring in long speech")
    expect(T.parseCommand("start listening") == .resume, "cmd: resume")
    expect(T.parseCommand("send it") == .send, "cmd: send")
    expect(T.parseCommand("invia") == .send, "cmd: send italian")
    expect(T.parseCommand("scratch that") == .scratch, "cmd: scratch")
    expect(T.parseCommand("read it to me") == .read, "cmd: read")
    expect(T.parseCommand("leggi") == .read, "cmd: read italian")
    expect(T.parseCommand("stop") == .stopRead, "cmd: bare stop is stopRead")
    expect(T.parseCommand("stop talking") == .stopRead, "cmd: stop talking")
    expect(T.parseCommand("talk mode on") == .talkOn, "cmd: talk on")
    expect(T.parseCommand("stop talk mode") == .talkOff, "cmd: talk off")
    expect(T.parseCommand("headphone mic") == .micHeadphone, "cmd: headphone mic")
    expect(T.parseCommand("mac mic") == .micBuiltIn, "cmd: mac mic")
    expect(T.parseCommand("new line") == .newline(1), "cmd: newline")
    expect(T.parseCommand("new paragraph") == .newline(2), "cmd: new paragraph")
    expect(T.parseCommand("a capo") == .newline(1), "cmd: newline italian")
    expect(T.parseCommand("italiano") == .languageItalian, "cmd: italian switch")
    expect(T.parseCommand("in inglese") == .languageEnglish, "cmd: english switch")
    expect(T.parseCommand("the weather is nice today") == nil, "cmd: ordinary speech is not a command")
    expect(T.parseCommand("send me the report tomorrow") == nil, "cmd: send inside a sentence is not a command")

    // Commit-gating regression tests. Times are built from a fixed origin so
    // the scenarios read as offsets in seconds.
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    var full = T.UtteranceBuffer()
    full.add("hello there everyone this is a test", confidence: 0.95)
    var lowConf = T.UtteranceBuffer()
    lowConf.add("garbled long transcript of something", confidence: 0.3)
    var shortHigh = T.UtteranceBuffer()
    shortHigh.add("ciao bella", confidence: 0.6)   // short: bar is 0.75
    var heard = T.UtteranceBuffer()
    heard.sawSpeech = true
    let empty = T.UtteranceBuffer()

    func decide(now: Double, final: Double = 0, voice: Double = 0, result: Double? = nil,
                session: Double = -100, pending: Bool = true, muted: Bool = false,
                volatileEmpty: Bool = true, dual: Bool = true,
                primary: T.UtteranceBuffer, secondary: T.UtteranceBuffer) -> T.CommitAction {
        T.commitDecision(now: at(now), lastVoiceAt: at(voice), lastFinalAt: at(final),
                         lastResultAt: at(result ?? now), sessionStartedAt: at(session),
                         pending: pending, muted: muted, volatileEmpty: volatileEmpty,
                         commitDelay: 0.7, dual: dual, primary: primary, secondary: secondary)
    }

    expect(decide(now: 1.0, dual: false, primary: full, secondary: empty) == .commit,
           "gate: single language commits after delay")
    expect(decide(now: 0.5, dual: false, primary: full, secondary: empty) == .wait,
           "gate: single language waits inside delay")
    expect(decide(now: 1.0, primary: full, secondary: full) == .commit,
           "gate: both engines reported -> short grace")
    expect(decide(now: 0.8, primary: full, secondary: heard) == .wait,
           "gate: second engine heard speech but silent -> waits 0.9s")
    expect(decide(now: 1.5, primary: full, secondary: heard) == .commit,
           "gate: 0.9s grace expires -> commit")
    expect(decide(now: 1.5, primary: lowConf, secondary: empty) == .wait,
           "gate: lone low-confidence transcript waits 3s for rescue")
    expect(decide(now: 3.5, primary: lowConf, secondary: empty) == .commit,
           "gate: rescue window expires -> commit")
    expect(decide(now: 1.5, primary: shortHigh, secondary: empty) == .wait,
           "gate: short transcript needs the higher confidence bar")
    expect(decide(now: 1.0, muted: true, primary: full, secondary: full) == .wait,
           "gate: muted never commits")
    expect(decide(now: 1.0, volatileEmpty: false, primary: full, secondary: full) == .wait,
           "gate: live volatile text blocks commit")
    expect(decide(now: 61, voice: 0, session: -300, pending: false,
                  primary: empty, secondary: empty) == .rotateIdle,
           "gate: idle hygiene rotation after long silence")
    expect(decide(now: 20, final: 0, voice: 18, result: 2, session: -5, pending: false,
                  primary: empty, secondary: empty) == .rotateWatchdog,
           "gate: watchdog rotates when voice present but engines mute")

    var joined = T.UtteranceBuffer()
    joined.add("hello", confidence: 1.0)
    joined.add("world", confidence: 0.5)
    expect(joined.text == "hello world", "buffer: finals join with spaces")
    expect(abs((joined.meanConfidence ?? 0) - 0.75) < 0.001, "buffer: weighted mean confidence")
    expect(T.pickUtterance(primary: full, secondary: lowConf) == full.text,
           "pick: higher confidence wins")
    expect(T.pickUtterance(primary: lowConf, secondary: full) == full.text,
           "pick: higher confidence wins either side")
    expect(T.pickUtterance(primary: full, secondary: empty) == full.text,
           "pick: lone buffer wins by default")
    var noConf = T.UtteranceBuffer()
    noConf.add("something", confidence: -1)
    expect(T.pickUtterance(primary: noConf, secondary: full) == nil,
           "pick: missing confidence defers to language fallback")
    expect(T.hotkeyChoices.allSatisfy { $0 == "None" || T.hotkeySpec($0) != nil },
           "hotkey: every offered choice resolves")

    print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
    return failures
}

