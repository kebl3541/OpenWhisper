import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import NaturalLanguage
import ScreenCaptureKit
import Speech
import ServiceManagement
import Vision

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

