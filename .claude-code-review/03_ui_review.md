# UI Layer Review Summary

## Files Reviewed

- `UI/StatusBarController.swift`
- `UI/SettingsView.swift`
- `UI/SettingsWindowController.swift`

## Changes Applied

### StatusBarController.swift
1. Replaced header comment with structured Chinese header (file name, description, responsibilities, dependencies, architecture role)
2. Removed `stateDescriptions` dictionary -- dead code, never read anywhere in the codebase
3. Removed empty `requestNotificationPermission()` method -- empty body, no effect
4. Removed `isInFallbackMode` property and `setFallbackMode()` method -- the fallback flag had no visual effect since both branches of `idleIcon()` returned the same value `"🎙🏠"`
5. Simplified `idleIcon()` by removing the dead `isInFallbackMode` branch

### SettingsView.swift
- Updated header comment with structured Chinese header (responsibilities, dependencies)
- No code changes needed -- file is clean

### SettingsWindowController.swift
- Updated header comment with structured Chinese header (responsibilities, dependencies)
- No code changes needed -- file is clean

## Architectural Improvement Suggestions

### 1. Move domain enums out of StatusBarController

`ApiMode` and `AutoSendMode` are defined inside `StatusBarController` but are domain-level types used by `RecordingController`, `AppDelegate`, and other non-UI components. They should be extracted to a shared location (e.g., `Models/ApiMode.swift` and `Models/AutoSendMode.swift`, or a single `Config/Enums.swift`). This would eliminate the `StatusBarController.ApiMode` qualification pattern seen throughout the codebase and clarify that these are app-wide concepts, not UI concerns.

### 2. Update call sites in AppDelegate (not done here)

The removed methods (`requestNotificationPermission()` and `setFallbackMode()`) may still be called from `AppDelegate.swift`. Another agent handles AppDelegate changes -- those call sites need to be removed there:
- `statusBarController.requestNotificationPermission()` -- delete the call
- `statusBarController.setFallbackMode(...)` -- delete the call

### 3. showNotification() is a Log.i() wrapper

`showNotification(title:message:)` only calls `Log.i()`. Consider either:
- Removing it and having callers use `Log.i()` directly, or
- Implementing actual user-visible notification (e.g., temporary menu bar title change) if notification feedback is desired

### 4. SettingsView and SettingsWindowController are clean

Both files follow good practices: SettingsView is a pure SwiftUI view with no side effects, and SettingsWindowController is a minimal NSWindow wrapper. No further simplification needed.
