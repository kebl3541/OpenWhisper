import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import NaturalLanguage
import ScreenCaptureKit
import Speech
import ServiceManagement
import Vision

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
