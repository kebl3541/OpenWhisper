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

