# CLAUDE.md - WhisperUtil Project Guidelines

## Project Overview

WhisperUtil is a macOS menu bar speech-to-text tool built with Swift. It supports three API modes:

- **Local** (WhisperKit) - offline on-device transcription
- **Cloud** (gpt-4o-transcribe) - HTTP API transcription
- **Realtime** (GA WebSocket) - streaming transcription via WebSocket

All three modes support transcription. Translation (to English) uses the Whisper HTTP API regardless of the selected mode.

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

**Important: Do NOT use `CONFIGURATION_BUILD_DIR=$(pwd)`** -- it generates intermediate files in the project directory.
**Important: Always use `make` targets instead of raw `xcodebuild` commands.**

## Project Structure

- Source code: `.swift` files in the project root directory
- Resources: `WhisperUtil/` subdirectory (Assets, Storyboard, etc.)
- Project config: `WhisperUtil.xcodeproj/`
- Sensitive files: `UserSettings.swift` (contains API keys, do NOT commit to git)
- **Codebase index: `CODEBASE_INDEX.md`** — 每个文件的功能说明和架构图，修改代码前应先阅读此文件定位相关源文件，避免全量阅读所有代码
