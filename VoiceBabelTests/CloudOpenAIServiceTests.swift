// CloudOpenAIServiceTests.swift
// VoiceBabelTests
//
// 测试 CloudOpenAIService 的纯逻辑部分：超时计算、语言映射、错误类型。
// 不测试网络请求。
//
// 【给你的讲解】
// 这个文件展示了"测什么、不测什么"的判断：
// - calculateProcessingTimeout 是纯函数（输入 → 输出，无副作用）→ 测
// - languageDisplayName 是静态映射表 → 测
// - sendRequest 涉及网络 I/O → 不测（需要 URLProtocol mock，投入产出比低）

import XCTest
@testable import VoiceBabel

// MARK: - 超时计算测试

final class TimeoutCalculationTests: XCTestCase {

    // 【讲解】这里创建一个真实的 service 实例，但不会调用任何网络 API。
    // apiKey 和 model 传空值就行——我们只用它的 calculateProcessingTimeout 方法。
    let service = CloudOpenAIService(apiKey: "", model: "", language: "")

    func testTimeout_zeroAudio_returnsMinimum() {
        XCTAssertEqual(
            service.calculateProcessingTimeout(audioDuration: 0),
            EngineeringOptions.apiProcessingTimeoutMin
        )
    }

    func testTimeout_shortAudio_returnsMinimum() {
        XCTAssertEqual(
            service.calculateProcessingTimeout(audioDuration: 10),
            EngineeringOptions.apiProcessingTimeoutMin
        )
    }

    func testTimeout_thirtySeconds_returnsMinimum() {
        // 30s = 0.5min, 0.5 × 10 = 5 = apiProcessingTimeoutMin
        XCTAssertEqual(
            service.calculateProcessingTimeout(audioDuration: 30),
            EngineeringOptions.apiProcessingTimeoutMin
        )
    }

    func testTimeout_oneMinute() {
        // 1min × 10 = 10s
        XCTAssertEqual(
            service.calculateProcessingTimeout(audioDuration: 60),
            10.0
        )
    }

    func testTimeout_threeMinutes() {
        // 3min × 10 = 30s
        XCTAssertEqual(
            service.calculateProcessingTimeout(audioDuration: 180),
            30.0
        )
    }

    func testTimeout_tenMinutes_returnsMaximum() {
        // 10min × 10 = 100, 但 max 是 90
        XCTAssertEqual(
            service.calculateProcessingTimeout(audioDuration: 600),
            EngineeringOptions.apiProcessingTimeoutMax
        )
    }

    func testTimeout_oneHour_stillMaximum() {
        XCTAssertEqual(
            service.calculateProcessingTimeout(audioDuration: 3600),
            EngineeringOptions.apiProcessingTimeoutMax
        )
    }
}

// MARK: - 语言显示名称测试

final class LanguageDisplayNameTests: XCTestCase {

    // 【讲解】这些是 SettingsView 中暴露给用户的翻译目标语言。
    // 如果映射错了，GPT 的 prompt 会说 "Translate to Japanese" 但代码传的是 "ko"，
    // 翻译结果就全错了。

    func testKnownLanguages() {
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "en"), "English")
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "zh"), "Simplified Chinese")
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "zh-Hant"), "Traditional Chinese")
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "ja"), "Japanese")
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "ko"), "Korean")
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "fr"), "French")
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "de"), "German")
        XCTAssertEqual(CloudOpenAIService.languageDisplayName(for: "es"), "Spanish")
    }

    func testUnknownLanguage_returnsNonEmpty() {
        let name = CloudOpenAIService.languageDisplayName(for: "sv")
        XCTAssertFalse(name.isEmpty, "未知语言不应返回空字符串")
        XCTAssertNotEqual(name, "sv", "不应原样返回语言代码")
    }
}

// MARK: - 错误类型测试

final class WhisperErrorTests: XCTestCase {

    func testAllCasesHaveDescriptions() {
        let cases: [CloudOpenAIService.WhisperError] = [
            .networkError("test"),
            .invalidResponse,
            .noData,
            .apiError(400, "bad request"),
            .decodingError,
        ]
        for error in cases {
            XCTAssertNotNil(error.errorDescription, "\(error) 应有描述")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testNetworkError_carriesMessage() {
        let error = CloudOpenAIService.WhisperError.networkError("connection refused")
        XCTAssertTrue(error.errorDescription?.contains("connection refused") ?? false)
    }

    func testApiError_carriesStatusCode() {
        let error = CloudOpenAIService.WhisperError.apiError(429, "rate limited")
        XCTAssertTrue(error.errorDescription?.contains("429") ?? false)
    }
}

// MARK: - EngineeringOptions 值域验证

/// 【讲解】这不是测试"功能"，而是测试"常量配置的合理性"。
/// 如果有人不小心改了常量（比如把超时设为 0），测试立刻告警。
/// 写起来 5 分钟，但能长期防止低级配置错误。

final class EngineeringOptionsTests: XCTestCase {

    func testSampleRatesPositive() {
        XCTAssertGreaterThan(EngineeringOptions.sampleRate, 0)
    }

    func testTimeoutRangeValid() {
        XCTAssertGreaterThan(EngineeringOptions.apiProcessingTimeoutMin, 0)
        XCTAssertGreaterThan(EngineeringOptions.apiProcessingTimeoutMax, EngineeringOptions.apiProcessingTimeoutMin)
    }

    func testVoiceThresholdInRange() {
        XCTAssertGreaterThan(EngineeringOptions.minVoiceThreshold, 0)
        XCTAssertLessThan(EngineeringOptions.minVoiceThreshold, 1.0)
    }

    func testHotkeyTimingConsistent() {
        XCTAssertGreaterThanOrEqual(
            EngineeringOptions.doubleTapWindow,
            EngineeringOptions.optionHoldThreshold,
            "双击窗口应 >= 按住阈值"
        )
    }

    func testAPIURLsValid() {
        XCTAssertNotNil(URL(string: EngineeringOptions.whisperTranscribeURL))
        XCTAssertNotNil(URL(string: EngineeringOptions.chatCompletionsURL))
    }

    func testTranslationEnginePriorityValid() {
        let valid = Set(["apple", "cloud"])
        let priority = SettingsDefaults.translationEnginePriority
        XCTAssertFalse(priority.isEmpty)
        for engine in priority {
            XCTAssertTrue(valid.contains(engine), "Invalid engine: \(engine)")
        }
    }
}
