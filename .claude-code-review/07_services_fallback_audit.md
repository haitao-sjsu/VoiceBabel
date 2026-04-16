# Services/ Fallback & Default-Value Audit

Date: 2026-04-16
Scope: `CloudOpenAIService`, `LocalWhisperService`, `LocalAppleTranslationService` (TextCleanupService was listed in scope but does not exist as a source file — only referenced historically in docs; skipped.)
Trigger: Two production bugs caused by silent fallbacks:
1. `CloudOpenAIService` silently coerced empty `language` → `"en"`, breaking Auto-Detect + Chinese speech.
2. `LocalAppleTranslationService` used `?? Locale.Language(identifier: "zh-Hans")` + hardcoded `"en"` in `status(from:to:)`, misreporting zh→en as unsupported.

This audit looks for the same class of bug — silent language/model/API-key coercion — in the remaining Services layer.

## Summary

- **7 findings total**
  - HIGH: 2 (would directly produce wrong-language output to the user)
  - MEDIUM: 3 (plausible but narrower blast radius; depends on caller)
  - LOW: 2 (defence-in-depth / maintainability)
- **Key risk areas:**
  - Hardcoded default parameter values on translation functions (silent "English" assumption survives even after CloudOpenAIService main-path fix).
  - "ui" / language-code resolution path inside `CloudOpenAIService` still has a silent fallback to `"en"` when the UI language code is somehow nil.
  - Error branch in `LocalAppleTranslationService` swallows `.supported` / `@unknown default` without distinguishing real errors from downloadable-but-missing packs.

## Findings

### Finding #1: `chatTranslate(targetLanguage:)` silently defaults to English — HIGH
**File:** `Services/CloudOpenAIService.swift:78`
**Code:**
```swift
func chatTranslate(text: String, targetLanguage: String = "en", completion: @escaping (Result<String, Error>) -> Void) {
    let languageName = Self.languageDisplayName(for: targetLanguage)
    Log.i(LocaleManager.shared.logLocalized("GPT translation: translating to") + " \(languageName)")
    ...
}
```
**Why it's a problem:** This is exactly the bug class that produced the two shipped incidents. The `= "en"` default means that any future caller (or a refactor that accidentally omits the argument) will silently translate every utterance into English with no log warning — the user will just see "English came out of the translator." Swift will happily compile the omission. There is currently one caller (`Core/TranslationPipeline.swift:155`) that passes an explicit value, so the default is "dead" today — but it is a loaded gun for any future caller.
**Suggested fix:** Remove the default. Make `targetLanguage: String` a required parameter. Let the compiler force every call site to be explicit. Alternatively, accept `String?` and `guard let targetLanguage else { completion(.failure(.invalidTargetLanguage)); return }` so the empty/missing case fails loudly.
**Risk if left alone:** A future caller (or auto-send refactor) omits the argument → user translating Japanese → English silently, with no warning in the log and no way for the user to notice until they read the output.

---

### Finding #2: `"ui"` language path falls back to `"en"` when UI language code is nil — HIGH
**File:** `Services/CloudOpenAIService.swift:245`
**Code:**
```swift
} else if language == "ui" {
    let interfaceCode = LocaleManager.shared.currentLocale.language.languageCode?.identifier ?? "en"
    effectiveLanguage = LocaleManager.whisperCode(for: interfaceCode)
} else {
    effectiveLanguage = LocaleManager.whisperCode(for: language)
}
```
**Why it's a problem:** This is the *same class of bug* that was just fixed on the Auto-Detect path. If `LocaleManager.shared.currentLocale.language.languageCode?.identifier` ever returns nil (e.g. on a freshly booted machine with an unusual region, or a future Locale API change), the code silently sends `language=en` to Whisper. The user's UI shows "Follow UI language = 中文" but the API receives `en` and returns English transcription of Chinese speech — the exact symptom of the first shipped bug. There is no log line warning that the fallback fired.
**Suggested fix:** Treat nil the same as the Auto-Detect branch: drop through to sending no `language` param at all (let Whisper auto-detect) and emit a `Log.w` saying "UI language code unresolvable, falling back to auto-detect." Never silently pick English.
**Risk if left alone:** Same user-visible symptom as the CloudOpenAIService bug that already shipped: Chinese in, English out, no log trace for post-mortem.

---

### Finding #3: `languageDisplayName(for:)` silently round-trips unknown codes — MEDIUM
**File:** `Services/CloudOpenAIService.swift:316-333`
**Code:**
```swift
static func languageDisplayName(for code: String) -> String {
    switch code {
    case "en": return "English"
    case "zh": return "Simplified Chinese"
    ...
    default: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
```
**Why it's a problem:** Two silent defaults stacked. If `code` is unrecognised (e.g. typo `"zn"`, or empty string), the function returns `code` verbatim, which is then embedded into the GPT prompt as *"Translate the following text to zn"*. GPT will either do something inventive, refuse, or pick a language at random. Worse: if `code` is the empty string, the prompt becomes *"Translate the following text to ."* — GPT's response is undefined. This is not the Auto-Detect bug class per se, but it is the same "silent string coercion instead of failing loudly" pattern.
**Suggested fix:** Have `languageDisplayName` return `String?` and make `chatTranslate` fail with `WhisperError.invalidResponse` (or a new `.unsupportedTargetLanguage`) when the display name cannot be resolved. At minimum, assert non-empty input at the top.
**Risk if left alone:** A settings bug or UI change that writes an unexpected code into `translationTargetLanguage` would produce nonsense translations with no hard failure.

---

### Finding #4: `LocalWhisperService.transcribe` uses `detectLanguage = true` only inside `else`, but never logs the effective choice — MEDIUM
**File:** `Services/LocalWhisperService.swift:125-130`
**Code:**
```swift
if !language.isEmpty {
    options.language = LocaleManager.whisperCode(for: language)
} else {
    // 语言未指定时启用自动检测（WhisperKit 默认英文，需显式开启检测）
    options.detectLanguage = true
}
```
**Why it's a problem:** Logic is correct (this file avoided the CloudOpenAI bug), **but** this relies on the caller passing `""` for Auto-Detect. The comment even admits that *WhisperKit's built-in default is English* — so if any future caller forgets to set `language` to `""` explicitly (e.g. future refactor that introduces `?? ""`), behaviour silently regresses to English. Also: no log line records which language was sent or whether auto-detect was enabled, which is the exact information needed to triage a repeat of the Cloud bug on the local path.
**Suggested fix:** Add a `Log.d("LocalWhisper language: \(language.isEmpty ? "auto-detect" : whisperCode)")` next to CloudOpenAIService line 254/256 style. Also consider making `language: String` a non-optional `enum { case auto, explicit(String) }` so the two branches are impossible to confuse.
**Risk if left alone:** A future regression on the local path mirrors the Cloud bug — Chinese user, English output, and no log breadcrumb.

---

### Finding #5: `LocalAppleTranslationService.translate` swallows `.supported` status by mapping it to `unsupportedLanguagePair` — MEDIUM
**File:** `Services/LocalAppleTranslationService.swift:96-100`
**Code:**
```swift
case .supported:
    Log.i("[AppleTranslation] Language pack not installed (\(resolvedSource.languageCode?.identifier ?? "?")→\(targetLanguage)), failing fast to let pipeline fallback")
    await MainActor.run { completion(.failure(TranslationError.unsupportedLanguagePair)) }
    return
```
**Why it's a problem:** Apple's API defines `.supported` specifically as *"language pair is valid but pack is not downloaded."* By mapping that to the same error as `.unsupported`, the pipeline loses the ability to distinguish "user needs to tap a download prompt" from "we truly cannot do this." The log line is correct, but `TranslationError.unsupportedLanguagePair` is misleading for the caller and for any future UI that might want to offer "Download language pack?" Also, `resolvedSource.languageCode?.identifier ?? "?"` repeats the very nil-coercion-to-magic-string pattern this audit is hunting for (lower severity since it is only in log output).
**Suggested fix:** Split the error enum: `case packNotInstalled(from: Locale.Language, to: Locale.Language)` vs `case unsupportedLanguagePair`. The pipeline can still fall back to Cloud for both, but future UX can offer a real download action. Also replace `?? "?"` with an explicit "unknown" constant or include the full Locale.Language description.
**Risk if left alone:** No immediate wrong-language output; user-visible impact is "Apple Translation never works and user doesn't know they need to pre-download the language pack." Commercial-UX risk, not data-correctness risk.

---

### Finding #6: Empty `code` is silently allowed in `languageDisplayName` — LOW
**File:** `Services/CloudOpenAIService.swift:316`
**Code:**
```swift
static func languageDisplayName(for code: String) -> String {
```
Note: overlaps with Finding #3 but called out separately because an empty string does not hit the `?? code` fallback — it hits it and returns `""`, which then goes into the GPT prompt. Worth an explicit `guard !code.isEmpty` at the top with a precondition failure in debug and a `Log.e` + sensible error in release.

---

### Finding #7: Constructor accepts empty `apiKey` / `model` / `language` without validation — LOW
**Files:**
- `Services/CloudOpenAIService.swift:47-51` (`init(apiKey:, model:, language:)`)
- `Services/LocalWhisperService.swift:71-73` (`init(language:)`)

**Why it's a problem:** The test suite (`WhisperUtilTests/CloudOpenAIServiceTests.swift:22`) constructs the service with empty strings — fine for unit tests, but the same constructor is the only one production uses. If `config.openaiApiKey` is empty (e.g. Keychain read race on first launch), the service will happily build a POST with `Authorization: Bearer ` and get a 401. That's detectable but the error message will be opaque API JSON rather than "API Key not configured."
**Suggested fix:** Either introduce a factory (`CloudOpenAIService.make(config:) throws -> CloudOpenAIService`) that validates non-empty key + known model, or add an `assert(!apiKey.isEmpty, "API key must be non-empty")` in DEBUG. Low severity because AppDelegate already checks API-key-presence elsewhere before recording; this is defence-in-depth.
**Risk if left alone:** Opaque 401 JSON shown to the user on first-launch race conditions, instead of a clear "configure your API key" message.

---

## Not flagged (deliberately)

- **`mapToLocaleLanguage("zh") → "zh-Hans"`** (`LocalAppleTranslationService.swift:187`) — legitimate BCP-47 normalisation; user acknowledged this class of mapping is OK.
- **`LocaleManager.whisperCode(for:)` stripping `-Hans`/`-Hant`** — same reason; documented, deliberate normalisation required by Whisper's limited code set.
- **`overrideModel ?? model`** (`CloudOpenAIService.swift:200`) — `model` is the injected primary; this is a legitimate override pattern, not a silent substitution of unknown data.
- **`String(data: data, encoding: .utf8) ?? "Unknown error"`** (`CloudOpenAIService.swift:142, 297`) — error-message formatting only, does not affect request semantics.
- **`resolvedSource = source ?? Self.detectSourceLanguage(from: text)`** (`LocalAppleTranslationService.swift:86`) — this is now correct behaviour (the fix from the second shipped bug): instead of hardcoding `zh-Hans`, it runs real language detection. Keep as-is.
- **Top-of-file constants in `EngineeringOptions` referenced via `whisperTranscribeURL`, `chatCompletionsURL`, `chatTranslationModel`, `localWhisperModel`, `whisperModel`** — named constants declared in a dedicated config file, exactly the "OK" pattern described in the audit brief.
- **`options.temperature = 0.0` / `options.noSpeechThreshold = 0.3`** in `LocalWhisperService` — numeric tuning constants with inline comments explaining their purpose; out of scope for the silent-fallback bug class.
