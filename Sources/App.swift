import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import NaturalLanguage
import ScreenCaptureKit
import Speech
import ServiceManagement
import Vision

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
                // Blue speaker while reading aloud: dictation is suppressed
                // then (the mic would hear our own voice), and that state
                // must be visible or "I'm talking and nothing happens".
                if SpeechOut.shared.isSpeaking { return ("speaker.wave.2.fill", .systemBlue) }
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
            } else if SpeechOut.shared.isSpeaking {
                statusText = "Reading aloud — say “stop” to interrupt"
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
