// ServiceAppleTranslation.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// Apple Translation Framework 本地翻译服务 —— 离线翻译能力。
//
// 职责：
//   1. 利用 Apple Translation Framework 进行设备端本地翻译
//   2. 通过隐藏 SwiftUI View 桥接获取 TranslationSession（macOS 14.4+ 限制）
//   3. 提供语言可用性检查（installed/supported/unsupported）
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
//   Apple Translation 翻译路径下调用。与 ServiceCloudOpenAI.chatTranslate() 职责对应。

import Foundation

#if canImport(Translation)
import Translation
import SwiftUI
import AppKit

@available(macOS 15.0, *)
class ServiceAppleTranslation {

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
        let source = sourceLanguage.flatMap { mapToLocaleLanguage($0) }
        let target = mapToLocaleLanguage(targetLanguage)

        guard let target = target else {
            completion(.failure(TranslationError.unsupportedLanguagePair))
            return
        }

        // 先检查语言包状态，给用户明确提示
        Task {
            let availability = LanguageAvailability()
            let sourceLang = source ?? Locale.Language(identifier: "en")
            let status = await availability.status(from: sourceLang, to: target)

            await MainActor.run { [weak self] in
                switch status {
                case .installed:
                    break
                case .supported:
                    Log.i("[AppleTranslation] Language pack not installed (\(sourceLanguage ?? "auto")→\(targetLanguage)), system will prompt for download")
                case .unsupported:
                    completion(.failure(TranslationError.unsupportedLanguagePair))
                    return
                @unknown default:
                    completion(.failure(TranslationError.unsupportedLanguagePair))
                    return
                }
                // installed 和 supported 都继续翻译
                // supported 时 session.translate() 会自动弹出系统下载对话框
                self?.performTranslation(text: text, source: source, target: target, completion: completion)
            }
        }
    }

    /// 检查语言对是否可用
    func checkAvailability(
        source: String?,
        target: String
    ) async -> LanguageAvailabilityStatus {
        let availability = LanguageAvailability()
        let sourceLang = source.flatMap { mapToLocaleLanguage($0) }
            ?? Locale.Language(identifier: "zh-Hans")
        guard let targetLang = mapToLocaleLanguage(target) else {
            return .unsupported
        }

        let status = await availability.status(
            from: sourceLang,
            to: targetLang
        )
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
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
                safeCompletion(.failure(TranslationError.translationFailed("Translation timed out")))
            }
        }
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

    enum LanguageAvailabilityStatus {
        case installed      // 已安装，可立即使用
        case needsDownload  // 支持但需下载
        case unsupported    // 不支持
    }

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
                    await MainActor.run {
                        completion(.success(response.targetText))
                    }
                } catch {
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
