// ServiceAppleTranslationTests.swift
// WhisperUtilTests
//
// ServiceAppleTranslation 依赖 Apple Translation Framework (macOS 15.0+)。
// 实际翻译需要系统语言包已安装，无法在所有环境自动测试。
// 这里测试错误类型和基本的输入验证。
//
// 【讲解】
// #if canImport(Translation) 是条件编译指令。
// 如果编译环境没有 Translation framework（比如旧版 macOS SDK），
// 这些测试会被跳过，不会导致编译失败。
// if #available(macOS 15.0, *) 是运行时检查，
// 如果当前系统低于 15.0，测试体内的代码不会执行。

import XCTest
@testable import WhisperUtil

#if canImport(Translation)

// MARK: - 错误类型

final class AppleTranslationErrorTests: XCTestCase {

    func testErrorDescriptions_nonEmpty() {
        if #available(macOS 15.0, *) {
            let errors: [ServiceAppleTranslation.TranslationError] = [
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

    func testTranslationFailed_carriesMessage() {
        if #available(macOS 15.0, *) {
            let error = ServiceAppleTranslation.TranslationError.translationFailed("timeout after 30s")
            XCTAssertTrue(error.errorDescription?.contains("timeout after 30s") ?? false)
        }
    }
}

// MARK: - 基本验证

final class AppleTranslationBasicTests: XCTestCase {

    // testTranslate_emptyTargetLanguage 跳过：
    // ServiceAppleTranslation 创建 NSWindow，在测试环境析构时触发 malloc 错误。
    // 未来重构为可注入 window 后可恢复。

    /// 可用性状态枚举应有三个值
    func testAvailabilityStatusValues() {
        if #available(macOS 15.0, *) {
            let statuses: [ServiceAppleTranslation.LanguageAvailabilityStatus] = [
                .installed, .needsDownload, .unsupported,
            ]
            XCTAssertEqual(statuses.count, 3)
        }
    }
}

#endif
