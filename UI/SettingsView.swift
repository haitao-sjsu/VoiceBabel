// SettingsView.swift
// VoiceBabel - macOS menu bar speech-to-text tool
//
// SwiftUI settings panel — binds all user-adjustable parameters via SettingsStore.
//
// Responsibilities:
//   Provides a graphical settings UI. All settings are bound to SettingsStore via
//   @ObservedObject, changes are instantly persisted to UserDefaults and propagated
//   via Combine to AppDelegate.
//
// Panel layout (5 Sections):
//   1. API Key: OpenAI API Key input and validation
//   2. Language: Recognition language selection
//   3. Transcription: Priority list (with per-row Toggle + availability badges)
//   4. Translation: Engine priority list + output language selection
//   5. General: Interface language, send mode, delay stepper, sound toggle
//
// Dependencies:
//   - SettingsStore: ObservableObject singleton, persists user preferences
//   - LocaleManager: Manages UI locale for instant language switching
//   - EngineAvailabilityProbe: Live objective-availability probe (injected by
//     SettingsWindowController) used by the priority rows to render
//     disabled/unavailable state and the empty-list footer warning.
//
// Architecture:
//   Embedded in SettingsWindowController's NSHostingController.
//   Triggered by StatusBarController's "Settings..." menu item.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var localeManager = LocaleManager.shared
    let probe: EngineAvailabilityProbe

    var body: some View {
        Form {
            // MARK: - API Key
            Section {
                HStack {
                    Text("OpenAI API Key")
                    Spacer()
                    if store.hasApiKey {
                        Text(store.maskedApiKey)
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        TextField("", text: $store.apiKeyInput, prompt: Text("sk-proj-...").foregroundColor(.gray.opacity(0.5)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { store.saveAndValidateApiKey() }
                    }
                }

                // Status line: validation result / not-set hint + action buttons
                HStack(spacing: 6) {
                    if store.hasApiKey {
                        switch store.apiKeyStatus {
                        case .valid:
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("API Key Valid").foregroundColor(.green).font(.caption)
                        case .invalid(let message):
                            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                            Text(message).foregroundColor(.red).font(.caption)
                        case .unchecked:
                            EmptyView()
                        }
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text("API Key required for cloud transcription and translation")
                            .foregroundColor(.secondary).font(.caption)
                    }

                    Spacer()

                    if store.hasApiKey {
                        Button("Validate") { store.validateApiKey() }
                            .disabled(store.isValidatingKey)
                        Button("Clear") { store.clearApiKey() }
                    } else {
                        Link("Get API Key",
                             destination: URL(string: "https://platform.openai.com/api-keys")!)
                        Button("Validate") { store.saveAndValidateApiKey() }
                            .disabled(store.apiKeyInput.isEmpty)
                    }
                }
            } header: {
                Text("API Key")
            }

            // MARK: - Language
            Section("Language") {
                Picker("Recognition Language", selection: $store.whisperLanguage) {
                    Text("Auto Detect").tag("")
                    Text("Same as Interface").tag("ui")
                    Divider()
                    Text("English").tag("en")
                    Text("简体中文").tag("zh")
                    Text("繁體中文").tag("zh-Hant")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Português").tag("pt")
                    Text("Русский").tag("ru")
                    Text("العربية").tag("ar")
                    Text("हिन्दी").tag("hi")
                    Text("Bahasa Indonesia").tag("id")
                    Text("ไทย").tag("th")
                    Text("Tiếng Việt").tag("vi")
                    Text("Türkçe").tag("tr")
                    Text("Polski").tag("pl")
                    Text("Nederlands").tag("nl")
                    Text("Italiano").tag("it")
                    Text("Svenska").tag("sv")
                }
            }

            // MARK: - Transcription
            Section {
                PriorityList(
                    items: $store.transcriptionPriority,
                    enabled: $store.transcriptionEnabled,
                    availability: { probe.availability(ofTranscriptionEngine: $0) },
                    icon: transcriptionModeIcon,
                    name: transcriptionModeName,
                    description: transcriptionModeDescription,
                    unavailableSubtitle: unavailabilityReasonText
                )
            } header: {
                Text("Transcription Priority")
            } footer: {
                let effective = store.transcriptionPriority
                    .filter { store.transcriptionEnabled[$0] ?? true }
                    .filter { probe.availability(ofTranscriptionEngine: $0) == .available }
                if effective.isEmpty {
                    Text("⚠️ No transcription engine enabled. Transcription will fail.")
                        .foregroundColor(.red)
                        .font(.caption)
                } else {
                    Text("Drag to reorder. First item is preferred; others are fallback.")
                }
            }

            // MARK: - Translation
            Section {
                PriorityList(
                    items: $store.translationEnginePriority,
                    enabled: $store.translationEngineEnabled,
                    availability: { probe.availability(ofTranslationEngine: $0) },
                    icon: translationEngineIcon,
                    name: translationEngineName,
                    description: translationEngineDescription,
                    unavailableSubtitle: unavailabilityReasonText
                )
            } header: {
                Text("Translation Engine Priority")
            } footer: {
                let effective = store.translationEnginePriority
                    .filter { store.translationEngineEnabled[$0] ?? true }
                    .filter { probe.availability(ofTranslationEngine: $0) == .available }
                if effective.isEmpty {
                    Text("⚠️ No translation engine enabled. Translation will fail.")
                        .foregroundColor(.red)
                        .font(.caption)
                } else {
                    Text("Drag to reorder. First engine is preferred; others are fallback.")
                }
            }

            Section("Translation") {
                Picker("Output Language", selection: $store.translationTargetLanguage) {
                    Text("English").tag("en")
                    Text("中文").tag("zh")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Español").tag("es")
                }
            }

            // MARK: - General
            Section("General") {
                Picker("Interface Language", selection: $store.appLanguage) {
                    Text("Follow System").tag("system")
                    Divider()
                    ForEach(LocaleManager.supportedLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }

                Picker("Send Mode", selection: $store.autoSendMode) {
                    Text("Transcribe Only").tag("off")
                    Text("Transcribe + Auto Send").tag("always")
                    Text("Transcribe + Delayed Send").tag("delayed")
                }

                if store.autoSendMode == "delayed" {
                    Stepper(
                        "Delay: \(Int(store.delayedSendDuration)) seconds",
                        value: $store.delayedSendDuration,
                        in: 2...15,
                        step: 1
                    )
                }

                Toggle("Play Sound Effects", isOn: $store.playSound)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
        .environment(\.locale, localeManager.currentLocale)
    }

    // MARK: - Priority Display Helpers

    private func transcriptionModeIcon(_ mode: String) -> String {
        switch mode {
        case "cloud": return "cloud"
        case "local": return "desktopcomputer"
        default: return "questionmark"
        }
    }

    private func transcriptionModeName(_ mode: String) -> LocalizedStringKey {
        switch mode {
        case "cloud": return "Cloud API"
        case "local": return "Local (WhisperKit)"
        default: return "Unknown"
        }
    }

    private func transcriptionModeDescription(_ mode: String) -> LocalizedStringKey {
        switch mode {
        case "cloud": return "gpt-4o-transcribe, needs network"
        case "local": return "On-device, offline"
        default: return ""
        }
    }

    private func translationEngineIcon(_ engine: String) -> String {
        switch engine {
        case "apple": return "apple.logo"
        case "cloud": return "cloud"
        default: return "questionmark"
        }
    }

    private func translationEngineName(_ engine: String) -> LocalizedStringKey {
        switch engine {
        case "apple": return "Apple Translation"
        case "cloud": return "Cloud GPT"
        default: return "Unknown"
        }
    }

    private func translationEngineDescription(_ engine: String) -> LocalizedStringKey {
        switch engine {
        case "apple": return "On-device, offline"
        case "cloud": return "gpt-4o-mini, needs network"
        default: return ""
        }
    }

    /// Maps an `UnavailabilityReason` to the per-row subtitle text shown when an
    /// engine is objectively unavailable. Strings are not yet in the xcstrings
    /// catalog (Phase 4 adds them); for now they display verbatim in English.
    private func unavailabilityReasonText(_ reason: UnavailabilityReason) -> LocalizedStringKey {
        switch reason {
        case .missingApiKey:
            return "API Key required"
        case .osTooOld(let v):
            return LocalizedStringKey("Requires \(v) or later")
        case .localModelNotLoaded:
            return "Local model not ready"
        }
    }
}

// MARK: - Reusable Priority List

/// Drag-reorderable priority list with per-row enable toggle + live availability state.
///
/// Each row delegates to `Row` which handles the compound UI (toggle, icon, name,
/// subtitle, badge, opacity). The "Primary" badge tracks the *first effectively
/// active* engine — objectively available AND user-enabled — not necessarily
/// `items[0]`, so toggling off the top row migrates the badge downward.
private struct PriorityList: View {
    @Binding var items: [String]
    @Binding var enabled: [String: Bool]
    let availability: (String) -> EngineAvailability
    let icon: (String) -> String
    let name: (String) -> LocalizedStringKey
    let description: (String) -> LocalizedStringKey
    let unavailableSubtitle: (UnavailabilityReason) -> LocalizedStringKey

    /// Index of the first row that will actually be used (enabled + objectively
    /// available). `nil` when nothing is active — in that case no row renders
    /// the Primary badge and the section footer shows the empty-list warning.
    private var firstActiveIndex: Int? {
        items.firstIndex { item in
            (enabled[item] ?? true) && availability(item) == .available
        }
    }

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Row(
                    item: item,
                    availability: availability(item),
                    isPrimary: index == firstActiveIndex,
                    isEnabled: Binding(
                        get: { enabled[item] ?? true },
                        set: { enabled[item] = $0 }
                    ),
                    icon: icon(item),
                    name: name(item),
                    description: description(item),
                    unavailableSubtitle: unavailableSubtitle
                )
            }
            .onMove { from, to in
                items.move(fromOffsets: from, toOffset: to)
            }
        }
        // Row height bumped to 52 to accommodate the toggle + two-line text stack.
        .frame(height: CGFloat(items.count * 52))
    }
}

// MARK: - Row

/// Single priority-list row. Three visual states composed from two booleans:
///   - isObjectivelyAvailable (system ready)
///   - isEnabled              (user preference)
/// Combinations:
///   available + enabled  → normal row, Primary badge if first-active
///   available + disabled → dimmed, "Disabled" badge
///   unavailable          → dimmed, toggle disabled, "Unavailable" badge,
///                          subtitle replaced with the failure reason
private struct Row: View {
    let item: String
    let availability: EngineAvailability
    let isPrimary: Bool
    @Binding var isEnabled: Bool
    let icon: String
    let name: LocalizedStringKey
    let description: LocalizedStringKey
    let unavailableSubtitle: (UnavailabilityReason) -> LocalizedStringKey

    private var isObjectivelyAvailable: Bool { availability == .available }
    private var isEffectivelyActive: Bool { isObjectivelyAvailable && isEnabled }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .disabled(!isObjectivelyAvailable)
                .toggleStyle(.switch)

            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            badge
        }
        .opacity(isEffectivelyActive ? 1.0 : 0.55)
    }

    /// Row subtitle: engine description when available, unavailability reason otherwise.
    private var subtitle: LocalizedStringKey {
        switch availability {
        case .available:
            return description
        case .unavailable(let reason):
            return unavailableSubtitle(reason)
        }
    }

    /// Right-side status pill. At most one renders; priority order is
    /// Primary > Unavailable > Disabled. Available+enabled non-primary rows
    /// intentionally show nothing (reduces clutter for the common case).
    @ViewBuilder
    private var badge: some View {
        if isPrimary {
            Badge(text: "Primary", color: .green)
        } else if !isObjectivelyAvailable {
            Badge(text: "Unavailable", color: .orange)
        } else if !isEnabled {
            Badge(text: "Disabled", color: .secondary)
        }
    }
}

// MARK: - Badge

/// Small colored pill used for Primary / Unavailable / Disabled state.
/// Text is `LocalizedStringKey` so each usage picks up xcstrings translation.
private struct Badge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }
}
