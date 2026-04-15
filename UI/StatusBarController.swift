// StatusBarController.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Menu bar UI controller — manages NSStatusItem icon and dropdown menu.
//
// Responsibilities:
//   1. Icon management: dynamically switch menu bar emoji icons based on AppState
//   2. Dropdown menu: transcribe/translate buttons, copy last transcription, settings, about, quit
//   3. State sync: update menu item text and availability based on AppState
//   4. Locale sync: subscribe to LocaleManager changes, refresh all menu titles
//
// Also defines two domain enums:
//   - ApiMode: API mode (local/cloud/realtime)
//   - AutoSendMode: auto-send mode (off/always/delayed)
//
// Dependencies:
//   - RecordingController.AppState
//   - LocaleManager: for localized menu strings
//
// Architecture:
//   Pure UI layer. Forwards user actions to AppDelegate via closures.

import Cocoa
import Combine

class StatusBarController {

    // MARK: - Callbacks

    var onTranscribeToggle: (() -> Void)?
    var onTranslateToggle: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    // MARK: - API Mode Enum

    enum ApiMode: String {
        case local = "local"
        case cloud = "cloud"
        case realtime = "realtime"
    }

    // MARK: - Auto Send Mode Enum

    enum AutoSendMode: String {
        case off = "off"
        case always = "always"
        case delayed = "delayed"

        var displayName: String {
            let lm = LocaleManager.shared
            switch self {
            case .off: return lm.localized("Transcribe Only")
            case .always: return lm.localized("Transcribe + Auto Send")
            case .delayed: return lm.localized("Transcribe + Delayed Send")
            }
        }

        static func from(_ string: String) -> AutoSendMode {
            return AutoSendMode(rawValue: string) ?? .delayed
        }
    }

    // MARK: - UI Components

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var currentAppState: RecordingController.AppState = .idle
    private var transcribeMenuItem: NSMenuItem!
    private var translateMenuItem: NSMenuItem!
    private var currentApiMode: ApiMode
    private var lastTranscriptionItem: NSMenuItem!
    private var lastTranscriptionText: String = ""
    private var copyTranscriptionHintItem: NSMenuItem!
    private var lastTranslationItem: NSMenuItem!
    private var lastTranslationText: String = ""
    private var copyTranslationHintItem: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var aboutItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    private var localeCancellable: AnyCancellable?

    // MARK: - State Icons

    private let stateIcons: [RecordingController.AppState: String] = [
        .idle: "🎙",
        .recording: "🔴",
        .processing: "⏳",
        .waitingToSend: "⏳",
        .error: "⚠️"
    ]

    private func idleIcon() -> String {
        switch currentApiMode {
        case .cloud, .realtime:
            return "🎙📶"
        case .local:
            return "🎙🏠"
        }
    }

    // MARK: - Init

    init(apiMode: ApiMode) {
        self.currentApiMode = apiMode
        setupStatusBar()
        subscribeToLocaleChanges()
    }

    private func setupStatusBar() {
        let lm = LocaleManager.shared

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = idleIcon()
        }

        menu = NSMenu()

        transcribeMenuItem = NSMenuItem(
            title: lm.localized("🎤 Start Transcription (⌥)"),
            action: #selector(transcribeClicked),
            keyEquivalent: ""
        )
        transcribeMenuItem.target = self
        menu.addItem(transcribeMenuItem)

        translateMenuItem = NSMenuItem(
            title: lm.localized("🌐 Start Translation (⌥⌥)"),
            action: #selector(translateClicked),
            keyEquivalent: ""
        )
        translateMenuItem.target = self
        menu.addItem(translateMenuItem)

        menu.addItem(NSMenuItem.separator())

        copyTranscriptionHintItem = NSMenuItem(title: lm.localized("Copy & Paste Last Transcription:"), action: nil, keyEquivalent: "")
        copyTranscriptionHintItem.isEnabled = false
        menu.addItem(copyTranscriptionHintItem)

        lastTranscriptionItem = NSMenuItem(
            title: lm.localized("  (None)"),
            action: nil,
            keyEquivalent: ""
        )
        lastTranscriptionItem.target = self
        lastTranscriptionItem.isEnabled = false
        menu.addItem(lastTranscriptionItem)

        copyTranslationHintItem = NSMenuItem(title: lm.localized("Copy & Paste Last Translation:"), action: nil, keyEquivalent: "")
        copyTranslationHintItem.isEnabled = false
        menu.addItem(copyTranslationHintItem)

        lastTranslationItem = NSMenuItem(
            title: lm.localized("  (None)"),
            action: nil,
            keyEquivalent: ""
        )
        lastTranslationItem.target = self
        lastTranslationItem.isEnabled = false
        menu.addItem(lastTranslationItem)

        menu.addItem(NSMenuItem.separator())

        settingsItem = NSMenuItem(
            title: lm.localized("Settings..."),
            action: #selector(settingsClicked),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        aboutItem = NSMenuItem(
            title: lm.localized("About WhisperUtil"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        quitItem = NSMenuItem(
            title: lm.localized("Quit"),
            action: #selector(quitClicked),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Subscribe to LocaleManager changes to refresh menu titles
    private func subscribeToLocaleChanges() {
        localeCancellable = LocaleManager.shared.$currentBundle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuTitles()
            }
    }

    /// Refresh all menu item titles with current locale
    private func refreshMenuTitles() {
        let lm = LocaleManager.shared

        // Refresh static menu items
        copyTranscriptionHintItem.title = lm.localized("Copy & Paste Last Transcription:")
        copyTranslationHintItem.title = lm.localized("Copy & Paste Last Translation:")
        settingsItem.title = lm.localized("Settings...")
        aboutItem.title = lm.localized("About WhisperUtil")
        quitItem.title = lm.localized("Quit")

        // Refresh last transcription/translation items
        if lastTranscriptionText.isEmpty {
            lastTranscriptionItem.title = lm.localized("  (None)")
        }
        if lastTranslationText.isEmpty {
            lastTranslationItem.title = lm.localized("  (None)")
        }

        // Refresh state-dependent items
        updateState(currentAppState)
    }

    // MARK: - Public Methods

    func setApiMode(_ mode: ApiMode) {
        currentApiMode = mode
        if let button = statusItem.button, currentAppState == .idle {
            button.title = idleIcon()
        }
    }

    func setLastTranscription(_ text: String) {
        lastTranscriptionText = text
        if text.isEmpty {
            lastTranscriptionItem.title = LocaleManager.shared.localized("  (None)")
            lastTranscriptionItem.action = nil
            lastTranscriptionItem.isEnabled = false
        } else {
            let preview = text.count > 10
                ? String(text.prefix(10)) + "..."
                : text
            lastTranscriptionItem.title = "  📋 \(preview)"
            lastTranscriptionItem.action = #selector(copyLastTranscription)
            lastTranscriptionItem.isEnabled = true
        }
    }

    func setLastTranslation(_ text: String) {
        lastTranslationText = text
        if text.isEmpty {
            lastTranslationItem.title = LocaleManager.shared.localized("  (None)")
            lastTranslationItem.action = nil
            lastTranslationItem.isEnabled = false
        } else {
            let preview = text.count > 10
                ? String(text.prefix(10)) + "..."
                : text
            lastTranslationItem.title = "  📋 \(preview)"
            lastTranslationItem.action = #selector(copyLastTranslation)
            lastTranslationItem.isEnabled = true
        }
    }

    func updateState(_ state: RecordingController.AppState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let lm = LocaleManager.shared

            if let button = self.statusItem.button {
                if state == .idle {
                    button.title = self.idleIcon()
                } else {
                    button.title = self.stateIcons[state] ?? "🎙"
                }
            }

            self.currentAppState = state

            switch state {
            case .idle, .error:
                self.transcribeMenuItem.title = lm.localized("🎤 Start Transcription (⌥)")
                self.transcribeMenuItem.isEnabled = true
                self.transcribeMenuItem.isHidden = false

                self.translateMenuItem.title = lm.localized("🌐 Start Translation (⌥⌥)")
                self.translateMenuItem.isEnabled = true
                self.translateMenuItem.isHidden = false

            case .recording:
                self.transcribeMenuItem.title = lm.localized("⏹ Stop Recording")
                self.transcribeMenuItem.isEnabled = true
                self.transcribeMenuItem.isHidden = false
                self.translateMenuItem.isHidden = true

            case .processing:
                self.transcribeMenuItem.title = lm.localized("⏳ Processing...")
                self.transcribeMenuItem.isEnabled = false
                self.transcribeMenuItem.isHidden = false
                self.translateMenuItem.isHidden = true

            case .waitingToSend:
                self.transcribeMenuItem.title = lm.localized("⏳ Waiting to Send... (tap ⌥ to cancel)")
                self.transcribeMenuItem.isEnabled = false
                self.transcribeMenuItem.isHidden = false
                self.translateMenuItem.isHidden = true
            }
        }
    }

    func showNotification(title: String, message: String) {
        Log.i(LocaleManager.shared.logLocalized("Notification:") + " [\(title)] \(message)")
    }

    // MARK: - Menu Actions

    @objc private func transcribeClicked() {
        onTranscribeToggle?()
    }

    @objc private func translateClicked() {
        onTranslateToggle?()
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    @objc private func copyLastTranscription() {
        copyAndPaste(lastTranscriptionText, label: "transcription")
    }

    @objc private func copyLastTranslation() {
        copyAndPaste(lastTranslationText, label: "translation")
    }

    private func copyAndPaste(_ text: String, label: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Log.i(LocaleManager.shared.logLocalized("Copy and paste last \(label):") + " \(text)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let source = CGEventSource(stateID: .hidSystemState)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    @objc private func showAbout() {
        let lm = LocaleManager.shared
        let alert = NSAlert()
        alert.messageText = lm.localized("About WhisperUtil")
        alert.informativeText = """
            \(lm.localized("Version")) 1.0.0

            \(lm.localized("Speech-to-text & translation tool"))
            \(lm.localized("Powered by OpenAI Whisper API"))

            \(lm.localized("Features:"))
            • \(lm.localized("Speech-to-text — recognize speech and output original text"))
            • \(lm.localized("Speech translation — recognize speech and translate"))
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: lm.localized("OK"))
        alert.runModal()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
