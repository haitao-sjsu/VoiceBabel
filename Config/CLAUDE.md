# Config/

Configuration management layer.

| File | Description |
|------|-------------|
| **SettingsDefaults.swift** | Hardcoded defaults for user-facing preferences (language, API mode, send mode, sound). Fallback values for SettingsStore |
| **EngineeringOptions.swift** | Engineering switches + technical constants. Controls audio pipeline stages: API endpoints, sample rates, thresholds, encoding params, model selection, timeouts, fallback strategy, post-processing toggles, translation engine ("auto"/"apple"/"cloud"), chat translation model, gesture params, log language. API Key has been migrated to Keychain |
| **KeychainHelper.swift** | macOS Keychain wrapper. Parameterized key-value store using `kSecClassGenericPassword`. `save(for:)`/`load(for:)`/`delete(for:)`/`exists(for:)` with default account `"openai-api-key"` |
| **ApiKeyValidator.swift** | API Key validator. Verifies key via `GET /v1/models`, returns `SettingsStore.ApiKeyStatus` |
| **SettingsStore.swift** | UserDefaults persistence + ObservableObject publisher. Manages all user-adjustable settings. `@Published` properties auto-save to UserDefaults, Combine publishers notify AppDelegate. Also manages API Key state (Keychain) and app language (LocaleManager) |
