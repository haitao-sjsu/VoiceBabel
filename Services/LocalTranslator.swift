// LocalTranslator.swift
// VoiceBabel - macOS menu bar speech-to-text tool
//
// Protocol abstraction for on-device translation backends, plus a factory that
// encapsulates the OS-version gate so callers don't have to.
//
// Why a protocol:
//   The concrete `LocalAppleTranslationService` type requires macOS 15.0+,
//   which otherwise forces `@available` annotations or `Any?` type-erasure at
//   every storage / call site. A protocol with no availability constraint lets
//   `TranslationManager` / `AppController` / `AppDelegate` hold a plain
//   `LocalTranslator?` and never see the OS-version check again.
//
// Why a factory:
//   The `if #available(macOS 15.0, *)` gate becomes a single decision inside
//   `LocalTranslatorFactory.make()`. On macOS 14 it returns `nil`; on 15+ it
//   returns a live `LocalAppleTranslationService`. Adding a future second
//   backend is a one-line change here.

import Foundation

/// Abstraction over on-device text translation engines.
///
/// Conforming types may be gated by `@available` — that constraint is not
/// surfaced on the protocol so that storage / call sites can be version-free.
/// Conformance is created by `LocalTranslatorFactory.make()`.
protocol LocalTranslator: AnyObject {
    /// Translate `text` from `sourceLanguage` (nil = auto-detect) to `targetLanguage`.
    /// Throws on any backend failure (unsupported pair, missing language pack,
    /// timeout, etc.).
    func translate(
        text: String,
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> String
}

/// Centralizes the OS-version decision for local-translator construction.
enum LocalTranslatorFactory {

    /// Returns a live `LocalTranslator` on macOS 15.0+, or `nil` on older systems.
    ///
    /// Must be called on the main actor because `LocalAppleTranslationService`
    /// creates a hidden NSWindow in its initializer for the SwiftUI bridge.
    @MainActor
    static func make() -> LocalTranslator? {
        if #available(macOS 15.0, *) {
            return LocalAppleTranslationService()
        }
        return nil
    }
}
