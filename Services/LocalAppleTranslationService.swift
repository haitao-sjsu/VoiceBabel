// LocalAppleTranslationService.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// Apple Translation Framework 本地翻译服务 —— 离线翻译能力。
//
// 职责：
//   1. 利用 Apple Translation Framework 进行设备端本地翻译
//   2. 通过隐藏 SwiftUI View 桥接获取 TranslationSession（macOS 14.4+ 限制）
//   3. 源语言自动识别（NLLanguageRecognizer）+ 语言包可用性预检查
//   4. 语言代码映射（WhisperUtil 代码 → Apple Locale.Language）
//
// 关键设计：
//   macOS 14.4/15 下 TranslationSession 只能通过 SwiftUI .translationTask modifier 获取。
//   本服务创建一个隐藏的 NSWindow + NSHostingController 作为桥接宿主，
//   在 .translationTask 闭包中执行翻译后回调结果。
//
// 依赖：
//   - Translation framework（macOS 14.4+）
//   - SwiftUI（桥接 TranslationSession）
//
// 架构角色：
//   由 AppDelegate 创建（@available 条件编译），由 RecordingController 在
//   Apple Translation 翻译路径下调用。与 CloudOpenAIService.chatTranslate() 职责对应。

import Foundation

#if canImport(Translation)
import Translation
import SwiftUI
import AppKit
import NaturalLanguage

@available(macOS 15.0, *)
class LocalAppleTranslationService {

    // MARK: - 隐藏窗口宿主

    /// 专用隐藏窗口，作为 SwiftUI 桥接 View 的宿主
    /// 在 AppDelegate 启动时创建，避免依赖可能不存在的 app 窗口
    private var bridgeWindow: NSWindow?

    init() {
        setupBridgeWindow()
    }

    private func setupBridgeWindow() {
        // 桥接窗口：1x1 像素，屏幕左下角，对用户不可见但对 window server 可见。
        // 必须 orderFrontRegardless() 让 SwiftUI 生命周期激活。
        // 不能用 alphaValue=0，否则系统语言包下载对话框无法弹出。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .init(-1)         // 略低于普通窗口
        window.orderFrontRegardless()
        self.bridgeWindow = window
    }

    // MARK: - 公共方法

    /// 翻译文本
    /// - Parameters:
    ///   - text: 待翻译文本
    ///   - sourceLanguage: 源语言代码（如 "zh"），nil 表示自动检测
    ///   - targetLanguage: 目标语言代码（如 "en"）
    ///   - completion: 完成回调
    func translate(
        text: String,
        sourceLanguage: String?,
        targetLanguage: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Log.i("[AppleTranslation] Starting translation: source=\(sourceLanguage ?? "auto"), target=\(targetLanguage), text length=\(text.count)")

        let source = sourceLanguage.flatMap { mapToLocaleLanguage($0) }
        let target = mapToLocaleLanguage(targetLanguage)

        guard let target = target else {
            Log.e("[AppleTranslation] Unsupported target language code: \(targetLanguage)")
            completion(.failure(TranslationError.unsupportedLanguagePair))
            return
        }

        // 源语言未指定(Auto Detect)时用 NLLanguageRecognizer 预先识别，
        // 避免把识别责任推给 TranslationSession —— 后者在缺语言包时可能挂起而非抛错。
        let resolvedSource = source ?? Self.detectSourceLanguage(from: text)
        Log.i("[AppleTranslation] Source language detected: \(resolvedSource?.languageCode?.identifier ?? "undetected")")

        Task {
            // 已知具体源语言 → 预检查语言包状态，未安装/不支持快速失败
            if let resolvedSource = resolvedSource {
                let availability = LanguageAvailability()
                let status = await availability.status(from: resolvedSource, to: target)

                switch status {
                case .installed:
                    break
                case .supported:
                    Log.i("[AppleTranslation] Language pack not installed (\(resolvedSource.languageCode?.identifier ?? "?")→\(targetLanguage)), failing fast to let pipeline fallback")
                    await MainActor.run { completion(.failure(TranslationError.unsupportedLanguagePair)) }
                    return
                case .unsupported:
                    Log.w("[AppleTranslation] Language pair unsupported: \(resolvedSource.languageCode?.identifier ?? "?") → \(targetLanguage)")
                    await MainActor.run { completion(.failure(TranslationError.unsupportedLanguagePair)) }
                    return
                @unknown default:
                    Log.w("[AppleTranslation] Unknown availability status for language pair")
                    await MainActor.run { completion(.failure(TranslationError.unsupportedLanguagePair)) }
                    return
                }
            }

            await MainActor.run { [weak self] in
                self?.performTranslation(text: text, source: resolvedSource, target: target, completion: completion)
            }
        }
    }

    // MARK: - SwiftUI 桥接翻译

    @MainActor
    private func performTranslation(
        text: String,
        source: Locale.Language?,
        target: Locale.Language,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let window = bridgeWindow else {
            Log.e("[AppleTranslation] Bridge window is nil, cannot perform translation")
            completion(.failure(TranslationError.sessionCreationFailed))
            return
        }

        let config = TranslationSession.Configuration(
            source: source,
            target: target
        )

        // 创建完成标记，防止重复回调；完成时清理桥接 View
        var hasCompleted = false
        var hostingControllerRef: NSHostingController<TranslationHostView>?

        let safeCompletion: (Result<String, Error>) -> Void = { result in
            guard !hasCompleted else { return }
            hasCompleted = true
            hostingControllerRef?.view.removeFromSuperview()
            hostingControllerRef = nil
            completion(result)
        }

        let view = TranslationHostView(
            text: text,
            targetConfig: config,
            completion: safeCompletion
        )

        let hostingController = NSHostingController(rootView: view)
        hostingControllerRef = hostingController
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        hostingController.view.alphaValue = 0

        window.contentView?.addSubview(hostingController.view)

        // 超时保护（60 秒：允许语言包下载时间）
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if !hasCompleted {
                Log.e("[AppleTranslation] Translation timed out after 60s")
                safeCompletion(.failure(TranslationError.translationFailed("Translation timed out")))
            }
        }
    }

    // MARK: - 源语言检测

    /// 用 NLLanguageRecognizer 从文本识别源语言，返回 Locale.Language 或 nil。
    /// 在 Apple Translation 之前自己识别，避免 TranslationSession 内部的自动检测
    /// 在语言包缺失时挂起(而非抛错)。
    private static func detectSourceLanguage(from text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: lang.rawValue)
    }

    // MARK: - 语言代码映射

    /// 将 WhisperUtil 的语言代码映射到 Apple Locale.Language
    /// 返回 nil 表示无法映射
    private func mapToLocaleLanguage(_ code: String) -> Locale.Language? {
        guard !code.isEmpty else { return nil }
        switch code {
        case "zh":      return Locale.Language(identifier: "zh-Hans")
        case "zh-Hant": return Locale.Language(identifier: "zh-Hant")
        default:        return Locale.Language(identifier: code)
        }
    }

    // MARK: - 类型定义

    enum TranslationError: Error, LocalizedError {
        case unsupportedLanguagePair
        case translationFailed(String)
        case sessionCreationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguagePair:
                return String(localized: "Unsupported language pair for local translation")
            case .translationFailed(let msg):
                return String(localized: "Local translation failed: \(msg)")
            case .sessionCreationFailed:
                return String(localized: "Failed to create translation session")
            }
        }
    }
}

// MARK: - SwiftUI 桥接 View

@available(macOS 15.0, *)
private struct TranslationHostView: View {
    let text: String
    let targetConfig: TranslationSession.Configuration
    let completion: (Result<String, Error>) -> Void

    // 【关键】@State 初始为 nil，onAppear 时赋值，触发 translationTask
    // .translationTask 只在 configuration 从 nil 变为非 nil 时触发回调
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(text)
                    Log.i("[AppleTranslation] Translation complete, result length: \(response.targetText.count)")
                    await MainActor.run {
                        completion(.success(response.targetText))
                    }
                } catch {
                    Log.e("[AppleTranslation] Translation session error: \(error.localizedDescription)")
                    await MainActor.run {
                        completion(.failure(error))
                    }
                }
            }
            .onAppear {
                configuration = targetConfig
            }
    }
}

#endif
