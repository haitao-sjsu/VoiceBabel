# CLAUDE.md - WhisperUtil Project Guidelines

## Project Overview

WhisperUtil is a macOS menu bar speech-to-text tool built with Swift. It supports three API modes:

- **Local** (WhisperKit) - offline on-device transcription
- **Cloud** (gpt-4o-transcribe) - HTTP API transcription
- **Realtime** (GA WebSocket) - streaming transcription via WebSocket

All three modes support transcription. Translation uses a two-step approach: first transcribe (using current API mode), then translate text via Apple Translation (local, macOS 15.0+) or Cloud GPT (gpt-4o-mini). The `translationEngine` setting in EngineeringOptions controls the strategy ("auto"/"apple"/"cloud").

## Architecture

```
main.swift -> AppDelegate (Composition Root)
                 |
                 +-- Config/Config <-- Config/SettingsDefaults (user preference defaults)
                 |                 <-- Config/EngineeringOptions (engineering switches/constants)
                 +-- Config/SettingsStore (UserDefaults + ObservableObject)
                 +-- Config/KeychainHelper (API Key secure storage)
                 +-- UI/StatusBarController (menu bar UI)
                 +-- UI/SettingsWindowController -> UI/SettingsView (SwiftUI settings panel)
                 +-- Core/HotkeyManager (Option key gesture detection)
                 +-- Core/RecordingController (state machine / core dispatcher)
                 |       +-- Core/AutoSendManager (delayed send logic)
                 |       +-- Core/TranslationPipeline (two-step translation flow)
                 |       +-- Audio/AudioRecorder -> Audio/AudioEncoder
                 |       +-- Services/ServiceCloudOpenAI (HTTP transcription + GPT translation)
                 |       +-- Services/ServiceRealtimeOpenAI (WebSocket streaming)
                 |       +-- Services/ServiceLocalWhisper (WhisperKit local)
                 |       +-- Services/ServiceAppleTranslation (Apple Translation local, macOS 15.0+)
                 |       +-- Services/ServiceTextCleanup (GPT-4o-mini text cleanup)
                 |       +-- Utilities/TextInputter (text output to active window)
                 |       +-- Utilities/TextPostProcessor (tag filtering, Chinese script conversion)
                 +-- Utilities/LocaleManager (i18n locale management)
                 +-- Utilities/NetworkHealthMonitor (network recovery probe)
```

Components communicate via closures/callbacks, connected in `AppDelegate.setupComponents()`. Settings changes propagate in real-time via Combine publishers.

## Project Structure

### Directories

```
Core/                       — Core logic (recording state machine, hotkey detection, auto-send, translation pipeline)
Config/                     — Configuration (user prefs, engineering options, Keychain, settings store)
UI/                         — Menu bar controller, SwiftUI settings panel, settings window
Services/                   — Transcription & translation backends (Cloud / Realtime / Local / Apple Translation / Text cleanup)
Audio/                      — Audio capture and encoding
Utilities/                  — Helpers (text input, text post-processing, network probe, logging, i18n locale manager)
WhisperUtil/                — Resources (Assets, Storyboard, String Catalogs)
WhisperUtilTests/           — Unit tests
.claude-research-tech/      — Technical research documents
.claude-research-commercial/— Commercial research documents
.claude-plan/               — Implementation plans
.claude-code-review/        — Code review documents
.human-learn/               — Learning notes (hand-written code reproductions)
.human-devlog/              — Development log (daily work journal)
```

### Root Files

| File | Description |
|------|-------------|
| **main.swift** | App entry point, creates NSApplication and AppDelegate |
| **AppDelegate.swift** | Composition root — initializes all components, connects callbacks, subscribes to settings changes via Combine |
| **Makefile** | Build/run automation (`make dev`, `make build`, `make run`, `make release`, `make clean`) |
| **whisperutil.log** | Runtime log file (auto-generated, not checked into git) |
| **WhisperUtil.xcodeproj/** | Xcode project bundle (directory displayed as a file in Finder). Contains `project.pbxproj` (build targets, file references, settings) |
| **CLAUDE.md** | This file — project guidelines for Claude |

## Background Mode

All tasks should run in the background by default. Only report to the user in these cases:

1. Encountered an error that cannot be resolved independently
2. Need to request permissions
3. Task is complete

## Default Workflow

### Code Change -> Build -> Launch (Standard Flow)

After every code change, use the project Makefile:

```bash
make dev    # Build Debug + quit old process + launch new version
```

Other useful targets:

```bash
make build    # Build Debug only
make release  # Build Release
make run      # Quit old process + launch (without rebuilding)
make clean    # Clean build artifacts
make check    # Verify prerequisites
make help     # Show all targets
```

If build fails, debug and fix it yourself.

### When to restart the app

- **Behavioral changes** (new features, bug fixes, changed logic, modified UI): use `make dev` to rebuild AND restart so the running app reflects the changes.
- **Non-behavioral changes** (renames, comments, docs, CLAUDE.md, formatting, refactors that don't change behavior): `make build` is sufficient to verify compilation. No need to restart.

## Keeping CLAUDE.md Files Up-to-Date

CLAUDE.md files are distributed across the project — one in the root and one in each subdirectory (`Audio/`, `Config/`, `Services/`, `UI/`, `Utilities/`).

- **Subdirectory CLAUDE.md**: When a subdirectory has significant changes (files added/deleted/renamed, major refactoring), update that subdirectory's CLAUDE.md to reflect the current state.
- **Root CLAUDE.md**: When the overall architecture changes significantly (new modules, removed components, changed communication patterns), update the root CLAUDE.md accordingly.

## Git Commit & Push

When the user asks to commit, follow this workflow:

### 1. Analyze changes
```bash
git status                    # Overview of all changes
git diff --stat               # Changed files summary
git log --oneline -5          # Recent commit style reference
```

### 2. Group commits by logical unit

Do NOT put everything into one commit. Group by purpose:

| Category | Example |
|----------|---------|
| Docs (research/plan/review) | Research docs, plan files, code reviews |
| Feature code | New service, controller changes, config |
| Config/meta | CLAUDE.md updates, Makefile, Xcode project |
| Tests | Unit tests |

### 3. Stage and commit each group

```bash
git add <specific files>      # Stage by group, never use `git add -A`
git commit -m "$(cat <<'EOF'
Short summary (imperative mood)

Optional body with details.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 4. Push only when explicitly asked

```bash
git push
```

### Commit message conventions
- Imperative mood: "Add feature" not "Added feature"
- First line under 72 chars
- Body explains "why" not "what" (the diff shows "what")
- Always include `Co-Authored-By` trailer
- Follow existing commit style in `git log`

### File naming conventions (for docs commits)
- `.claude-research-tech/`: `01_topic_name.md` (sequential numbering)
- `.claude-code-review/`: `01_review_name.md` (sequential numbering)
- `.claude-plan/`: `01_plan_name.md` (sequential numbering)
- When renumbering files (e.g., after deletion), keep all numbers sequential with no gaps

## Internationalization (i18n)

- UI strings are localized via String Catalogs (`WhisperUtil/Localizable.xcstrings`), supporting 20 languages
- Log strings use a separate catalog (`WhisperUtil/LogStrings.xcstrings`), supporting en + zh only
- `Utilities/LocaleManager.swift` manages runtime locale switching (instant, no restart)
- AppKit code uses `LocaleManager.shared.localized("key")`, SwiftUI uses `Text("key")` with `.environment(\.locale)`
- Log messages use `LocaleManager.shared.logLocalized("key")`
- Log language is controlled by `EngineeringOptions.logLanguage` ("en" or "zh")