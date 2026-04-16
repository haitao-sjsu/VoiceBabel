// LocaleManager.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Core locale manager for UI internationalization.
//
// Responsibilities:
//   1. Manage the current application locale and corresponding .lproj Bundle
//   2. Provide localized() for AppKit UI strings (menus, alerts, etc.)
//   3. Provide logLocalized() for log messages (en/zh only, using LogStrings table)
//   4. Support instant locale switching without app restart
//
// Design:
//   - @MainActor singleton, thread-safe
//   - SwiftUI: inject .environment(\.locale, localeManager.currentLocale)
//   - AppKit: subscribe to LocaleManager changes via Combine, manually refresh
//   - Logs: independent logBundle, controlled by EngineeringOptions.logLanguage
//
// Dependencies:
//   - EngineeringOptions: logLanguage setting
//
// Architecture:
//   Used by StatusBarController (AppKit menus), SettingsView (SwiftUI),
//   SettingsWindowController (window title), and all Log calls.

import Foundation
import Combine

@MainActor
final class LocaleManager: ObservableObject {
    static let shared = LocaleManager()

    @Published var currentLocale: Locale
    @Published private(set) var currentBundle: Bundle
    private var logBundle: Bundle

    // All supported UI languages (code -> native display name)
    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("pt", "Português"),
        ("ru", "Русский"),
        ("ar", "العربية"),
        ("hi", "हिन्दी"),
        ("id", "Bahasa Indonesia"),
        ("th", "ไทย"),
        ("vi", "Tiếng Việt"),
        ("tr", "Türkçe"),
        ("pl", "Polski"),
        ("nl", "Nederlands"),
        ("it", "Italiano"),
        ("sv", "Svenska"),
    ]

    // Mapping from locale code to Whisper language code
    static func whisperCode(for localeCode: String) -> String {
        let base = localeCode.replacingOccurrences(of: "-Hans", with: "").replacingOccurrences(of: "-Hant", with: "")
        return base  // Whisper uses "zh", "en", "ja", etc.
    }

    private init() {
        let systemLocale = Locale.current
        self.currentLocale = systemLocale
        self.currentBundle = Self.bundle(for: systemLocale.language.languageCode?.identifier ?? "en")
        self.logBundle = Self.bundle(for: EngineeringOptions.logLanguage)
    }

    func setLocale(_ code: String) {
        if code == "system" {
            let systemLang = Locale.current.language.languageCode?.identifier ?? "en"
            currentLocale = Locale.current
            currentBundle = Self.bundle(for: systemLang)
        } else {
            currentLocale = Locale(identifier: code)
            currentBundle = Self.bundle(for: code)
        }
    }

    /// Localized string for AppKit UI (menus, alerts, etc.)
    func localized(_ key: String) -> String {
        currentBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Localized string for log messages (en or zh only)
    func logLocalized(_ key: String) -> String {
        logBundle.localizedString(forKey: key, value: nil, table: "LogStrings")
    }

    private static func bundle(for languageCode: String) -> Bundle {
        // Try exact match first (e.g., "zh-Hans"), then base (e.g., "zh")
        let candidates = [languageCode, String(languageCode.prefix(2))]
        for code in candidates {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        // Fallback to Base/en
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return Bundle.main
    }
}
