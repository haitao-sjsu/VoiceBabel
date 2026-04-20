# Config/

Configuration management layer.

| File | Description |
|------|-------------|
| **SettingsDefaults.swift** | Hardcoded defaults for user-facing preferences (language, API mode, send mode, sound). Fallback values for SettingsStore. Includes default subjective-enable dicts (`transcriptionEnabled` / `translationEngineEnabled`, all engines default to `true`) |
| **EngineAvailability.swift** | `EngineAvailability` / `UnavailabilityReason` enums + `@MainActor struct EngineAvailabilityProbe`. Pure-function snapshot of whether each engine id is objectively usable right now (API key present, WhisperKit model loaded, macOS 15+ Apple translator constructed). Not cached, not persisted; AppDelegate re-probes on every relevant signal change via Combine |
| **EngineeringOptions.swift** | Engineering switches + technical constants. Controls audio pipeline stages: API endpoints, sample rates, thresholds, encoding params, model selection, timeouts, post-processing toggles, chat translation model, gesture params, log language. API Key has been migrated to Keychain |
| **KeychainHelper.swift** | macOS Keychain wrapper. Parameterized key-value store using `kSecClassGenericPassword`. `save(for:)`/`load(for:)`/`delete(for:)`/`exists(for:)` with default account `"openai-api-key"` |
| **ApiKeyValidator.swift** | API Key validator. Verifies key via `GET /v1/models`, returns `SettingsStore.ApiKeyStatus` |
| **SettingsStore.swift** | UserDefaults persistence + ObservableObject publisher. Manages all user-adjustable settings including the priority arrays **and** the subjective-enable dicts (`transcriptionEnabled` / `translationEngineEnabled: [String: Bool]`). `@Published` properties auto-save to UserDefaults and drive AppDelegate's merged Combine sinks that compute the effective engine list. Also manages API Key state (Keychain) and app language (LocaleManager) |
