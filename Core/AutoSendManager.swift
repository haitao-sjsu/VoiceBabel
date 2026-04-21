// AutoSendManager.swift
// VoiceBabel - macOS menu bar speech-to-text tool
//
// Auto-send logic — manages automatic Enter key press after transcription output.
//
// Responsibilities:
//   1. Off mode: do nothing after transcription
//   2. Always mode: press Enter after a short delay (EngineeringOptions.autoSendDelay)
//   3. Delayed mode: start countdown, press Enter when timer expires, cancel on new recording or user action
//
// Dependencies:
//   - TextInputter (pressReturnKey for simulating Enter)
//   - EngineeringOptions (autoSendDelay timing)
//   - StatusBarController.AutoSendMode (mode enum)
//   - LocaleManager (log localization)
//
// Architecture role:
//   Extracted from AppController. Owned by AppController, communicates
//   state changes back via onStateChange callback.

import Cocoa

class AutoSendManager {

    // MARK: - Configuration

    var autoSendMode: StatusBarController.AutoSendMode = .delayed
    var delayedSendDuration: TimeInterval = SettingsDefaults.delayedSendDuration

    // MARK: - Callbacks

    var onStateChange: ((AppController.AppState) -> Void)?

    // MARK: - Dependencies

    private let textInputter: TextInputter

    // MARK: - State

    private var pendingSendTimer: DispatchWorkItem?

    // MARK: - Init

    init(textInputter: TextInputter) {
        self.textInputter = textInputter
    }

    // MARK: - Public Methods

    func handleAutoSend() {
        let lm = LocaleManager.shared
        switch autoSendMode {
        case .off:
            break

        case .always:
            DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.autoSendDelay) { [weak self] in
                self?.textInputter.pressReturnKey()
                Log.i(lm.logLocalized("Auto send: pressed Enter"))
            }

        case .delayed:
            startDelayedSendCountdown()
        }
    }

    func startDelayedSendCountdown() {
        let lm = LocaleManager.shared
        onStateChange?(.waitingToSend)
        Log.i(lm.logLocalized("Delayed send: starting") + " \(delayedSendDuration)s " + lm.logLocalized("countdown..."))

        let timerWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.textInputter.pressReturnKey()
            Log.i(lm.logLocalized("Delayed send: countdown ended, auto sent"))
            self.cleanupDelayedSend()
            self.onStateChange?(.idle)
        }
        pendingSendTimer = timerWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delayedSendDuration, execute: timerWork)
    }

    func cancelDelayedSend() {
        let lm = LocaleManager.shared
        cleanupDelayedSend()
        onStateChange?(.idle)
        Log.i(lm.logLocalized("Delayed send: user pressed hotkey to cancel send, text preserved"))
    }

    func cancelDelayedSendForNewRecording() {
        let lm = LocaleManager.shared
        Log.i(lm.logLocalized("Delayed send: user started new recording, cancelling send countdown"))
        cleanupDelayedSend()
    }

    func cleanupDelayedSend() {
        pendingSendTimer?.cancel()
        pendingSendTimer = nil
    }

}
