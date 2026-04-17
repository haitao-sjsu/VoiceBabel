// TextPostProcessor.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// Text post-processing module — stateless transformations applied after transcription/translation.
//
// Responsibilities:
//   1. Tag filtering: remove Whisper output tags like [MUSIC], [BLANK_AUDIO] (controlled by EngineeringOptions.enableTagFiltering)
//   2. Chinese script conversion: Traditional↔Simplified based on user language settings
//   3. Whitespace trimming
//
// Dependencies:
//   - Foundation (CFStringTransform for Chinese script conversion)
//   - EngineeringOptions (enableTagFiltering switch)
//   - SettingsStore (whisperLanguage, appLanguage for script direction)
//
// Architecture role:
//   Stateless utility extracted from AppController. Called by AppController
//   and TranslationManager before outputting text.

import Foundation

enum TextPostProcessor {

    /// Post-process transcription/translation text: filter special tags, convert Chinese script, trim whitespace
    static func process(_ text: String) -> String {
        let original = text
        var result = text

        // Filter Whisper output special tags (e.g. [MUSIC], [BLANK_AUDIO])
        if EngineeringOptions.enableTagFiltering {
            result = result.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        }

        result = convertChineseScript(result)

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result != original { Log.d("TextPostProcessor: processed, length \(original.count) → \(result.count)") }
        return result
    }

    /// Convert Chinese script direction based on user language settings
    ///
    /// - "zh": user specified Simplified Chinese → Traditional→Simplified
    /// - "zh-Hant": user specified Traditional Chinese → Simplified→Traditional
    /// - "ui": follow interface language (zh-Hans → Simplified, zh-Hant → Traditional)
    /// - Other (including empty string for auto-detect): no conversion, return as-is
    static func convertChineseScript(_ text: String) -> String {
        let lang = SettingsStore.shared.whisperLanguage

        let targetScript: String?  // "Hans" or "Hant" or nil
        switch lang {
        case "zh":
            targetScript = "Hans"
        case "zh-Hant":
            targetScript = "Hant"
        case "ui":
            let appLang = SettingsStore.shared.appLanguage
            if appLang == "system" {
                let sysLangCode = Locale.current.language.languageCode?.identifier
                if sysLangCode == "zh" {
                    targetScript = Locale.current.language.script?.identifier == "Hant" ? "Hant" : "Hans"
                } else {
                    targetScript = nil
                }
            } else if appLang == "zh-Hans" {
                targetScript = "Hans"
            } else if appLang == "zh-Hant" {
                targetScript = "Hant"
            } else {
                targetScript = nil
            }
        default:
            targetScript = nil
        }

        guard let script = targetScript else { return text }

        let mutable = NSMutableString(string: text)
        // reverse=false: Traditional→Simplified; reverse=true: Simplified→Traditional
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, script == "Hant")
        return mutable as String
    }

}
