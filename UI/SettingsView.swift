// SettingsView.swift
// WhisperUtil - macOS menu bar speech-to-text tool
//
// SwiftUI settings panel — binds all user-adjustable parameters via SettingsStore.
//
// Responsibilities:
//   Provides a graphical settings UI. All settings are bound to SettingsStore via
//   @ObservedObject, changes are instantly persisted to UserDefaults and propagated
//   via Combine to AppDelegate.
//
// Panel layout (4 Sections):
//   1. API Key: OpenAI API Key input and validation
//   2. Language: Recognition language selection
//   3. Transcription: Priority list
//   4. Translation: Engine priority list + output language selection
//   5. General: Interface language, send mode, delay stepper, sound toggle
//
// Dependencies:
//   - SettingsStore: ObservableObject singleton, persists user preferences
//   - LocaleManager: Manages UI locale for instant language switching
//
// Architecture:
//   Embedded in SettingsWindowController's NSHostingController.
//   Triggered by StatusBarController's "Settings..." menu item.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var localeManager = LocaleManager.shared

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
                    icon: transcriptionModeIcon,
                    name: transcriptionModeName,
                    description: transcriptionModeDescription
                )
            } header: {
                Text("Transcription Priority")
            } footer: {
                Text("Drag to reorder. First item is preferred; others are fallback.")
            }

            // MARK: - Translation
            Section {
                PriorityList(
                    items: $store.translationEnginePriority,
                    icon: translationEngineIcon,
                    name: translationEngineName,
                    description: translationEngineDescription
                )
            } header: {
                Text("Translation Engine Priority")
            } footer: {
                Text("Drag to reorder. First engine is preferred; others are fallback.")
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
}

// MARK: - Reusable Priority List

private struct PriorityList: View {
    @Binding var items: [String]
    let icon: (String) -> String
    let name: (String) -> LocalizedStringKey
    let description: (String) -> LocalizedStringKey

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                HStack(spacing: 10) {
                    Image(systemName: icon(item))
                        .foregroundColor(.accentColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(name(item))
                            .font(.body)
                        Text(description(item))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if index == 0 {
                        Text("Primary")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
            }
            .onMove { from, to in
                items.move(fromOffsets: from, toOffset: to)
            }
        }
        .frame(height: CGFloat(items.count * 44))
    }
}
