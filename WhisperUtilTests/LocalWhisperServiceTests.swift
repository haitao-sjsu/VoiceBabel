// LocalWhisperServiceTests.swift
// WhisperUtilTests
//
// LocalWhisperService 依赖 WhisperKit + 626MB CoreML 模型。
// 真正的转录测试需要加载模型（CI 环境不实际）。
// 这里测试初始化状态、错误路径和错误类型。
//
// 【讲解】
// 即使不能测实际转录，测试错误路径仍然有价值：
// 确保"模型没加载就调用 transcribe"不会 crash，而是返回清晰的错误。
// 这类防御性逻辑在开发中很容易被忽略，但在生产环境中会被触发
// （比如 app 刚启动模型还在加载时用户就双击了 Option）。

import XCTest
@testable import WhisperUtil

// MARK: - 初始状态

final class LocalWhisperInitTests: XCTestCase {

    func testNotReady_beforeModelLoaded() {
        let service = LocalWhisperService(language: "zh")
        XCTAssertFalse(service.isReady())
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertFalse(service.isModelLoading)
    }

    func testLanguage_preserved() {
        let service = LocalWhisperService(language: "en")
        XCTAssertEqual(service.language, "en")
    }

    func testEmptyLanguage_meansAutoDetect() {
        let service = LocalWhisperService(language: "")
        XCTAssertTrue(service.language.isEmpty)
    }

    func testLanguage_mutable() {
        let service = LocalWhisperService(language: "zh")
        service.language = "en"
        XCTAssertEqual(service.language, "en")
    }
}

// MARK: - 错误路径

final class LocalWhisperErrorPathTests: XCTestCase {

    /// 【讲解】async 测试方法：在 XCTest 中直接用 async throws 即可。
    /// Xcode 会自动等待 async 完成再判断结果。
    func testTranscribe_withoutModel_throws() async {
        let service = LocalWhisperService(language: "zh")
        do {
            _ = try await service.transcribe(samples: [0.1, 0.2])
            XCTFail("应该抛出错误")
        } catch {
            // 模型未加载时应抛出 modelNotLoaded
            XCTAssertTrue(error is LocalWhisperService.LocalWhisperError)
        }
    }

    func testTranscribe_emptySamples_throws() async {
        let service = LocalWhisperService(language: "zh")
        do {
            _ = try await service.transcribe(samples: [])
            XCTFail("应该抛出错误")
        } catch {
            // 空数据或模型未加载都应抛错（不应 crash）
            XCTAssertNotNil(error)
        }
    }
}

// MARK: - 错误类型

final class LocalWhisperErrorTypeTests: XCTestCase {

    func testErrorDescriptions_nonEmpty() {
        let errors: [LocalWhisperService.LocalWhisperError] = [
            .modelNotLoaded,
            .noAudioData,
            .transcriptionFailed("test reason"),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testTranscriptionFailed_carriesReason() {
        let error = LocalWhisperService.LocalWhisperError.transcriptionFailed("timeout")
        XCTAssertTrue(error.errorDescription?.contains("timeout") ?? false)
    }
}
