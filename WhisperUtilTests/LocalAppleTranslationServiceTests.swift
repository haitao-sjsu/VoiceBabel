// LocalAppleTranslationServiceTests.swift
// WhisperUtilTests
//
// Apple Translation 的功能测试（真实翻译）无法在 XCTest 中运行：
// .translationTask SwiftUI modifier 需要完整的 app UI 生命周期，
// 而 XCTest 的 test host 环境不具备这个条件。
//
// 可测内容仅限于不依赖 Translation Framework 运行时的纯逻辑：
// 错误类型、枚举值。

import XCTest
@testable import WhisperUtil

final class AppleTranslationErrorTests: XCTestCase {

    func testErrorDescriptions_nonEmpty() {
        if #available(macOS 15.0, *) {
            let errors: [LocalAppleTranslationService.TranslationError] = [
                .unsupportedLanguagePair,
                .translationFailed("test"),
                .sessionCreationFailed,
            ]
            for error in errors {
                XCTAssertNotNil(error.errorDescription)
                XCTAssertFalse(error.errorDescription!.isEmpty)
            }
        }
    }
}
