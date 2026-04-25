// EngineAvailabilityProbe.swift
// VoiceBabel - macOS 菜单栏语音转文字工具
//
// 引擎客观可用性探测 —— 基于实时系统状态判断转录/翻译引擎是否可用。
//
// 职责：
//   1. 定义 EngineAvailability（可用 / 不可用 + 原因）和 UnavailabilityReason（缺 API Key、
//      系统版本过低、本地模型未加载）作为 UI 与 AppDelegate 之间的共享类型。
//   2. EngineAvailabilityProbe 汇总各引擎的"客观可用"判断为纯函数，按需求调用不缓存、
//      不持久化 —— 只读当前系统状态。
//
// 设计：
//   - 与"主观启用"（SettingsStore.transcriptionEnabled / translationEngineEnabled）正交：
//     * 主观：用户勾选禁用 → 不尝试。
//     * 客观：系统不具备条件 → 不可用。
//     两者均为 true 且在优先级数组中的引擎才会进入有效列表。
//   - 纯函数式探针：由 AppDelegate 的 merged Combine sink 在依赖信号变化时调用，
//     也由 SettingsView 按行显示状态。
//
// 依赖：
//   - SettingsStore：读取 hasApiKey（Cloud 引擎）。
//   - LocalWhisperService：读取 state（local 转录，仅 .ready 视为可用，其它状态把
//     statusDescription 透传给 UI 作为 unavailability 副标题）。
//   - LocalTranslator 闭包：非 nil = macOS 15+ 且工厂已成功构造（apple 翻译）。
//
// 架构角色：
//   单一信息源（single source of truth）—— Managers 不再自行判断可用性，
//   AppDelegate 预先过滤优先级数组后推送给 Manager。

import Foundation

/// 单个引擎的客观可用性。
enum EngineAvailability: Equatable {
    case available
    case unavailable(UnavailabilityReason)
}

/// 引擎不可用的具体原因。UI 用来显示灰色行的副标题/徽标。
enum UnavailabilityReason: Equatable {
    /// 缺 API Key（Cloud 系列引擎）。
    case missingApiKey
    /// 系统版本过低（如 Apple Translation 需要 macOS 15.0+）。
    case osTooOld(requiredVersion: String)
    /// 本地模型未就绪（下载中 / 加载中 / 预热中 / 失败 等任意非 .ready 状态）。
    /// `detail` 为 `LocalWhisperService.statusDescription` 透传过来的本地化字符串，
    /// UI 直接展示无需二次映射。
    case localModelNotReady(detail: String)
}

/// 汇总各引擎客观可用性的探针。
///
/// 按调用求值（不缓存）—— 每次 availability(of…:) 都读当前状态。AppDelegate 负责
/// 订阅触发变化的 Combine 发布者（apiKeyVersion / state / 优先级数组变更）
/// 来决定何时重新调用。
///
/// 必须在主线程调用，因为它读取的 `LocalTranslator?` 构造也是 `@MainActor`。
@MainActor
struct EngineAvailabilityProbe {
    /// 用于读取 `hasApiKey`，判断 Cloud 系列引擎是否可用。
    let settingsStore: SettingsStore

    /// 用于读取 `state` / `statusDescription`，判断 local 转录引擎是否可用并把当前阶段
    /// 透传给 UI 副标题。
    let localWhisperService: LocalWhisperService

    /// 闭包形式的 LocalTranslator 获取器 —— 每次探测都重新调用以取最新实例。
    /// 非 nil 表示 LocalTranslatorFactory.make() 已成功构造（即 macOS 15+ 且框架可用）。
    let localTranslator: () -> LocalTranslator?

    /// 判断转录引擎（由 `transcriptionPriority` 中的 id 驱动）的客观可用性。
    func availability(ofTranscriptionEngine id: String) -> EngineAvailability {
        switch id {
        case "cloud":
            return settingsStore.hasApiKey
                ? .available
                : .unavailable(.missingApiKey)
        case "local":
            if localWhisperService.state == .ready {
                return .available
            }
            return .unavailable(.localModelNotReady(detail: localWhisperService.statusDescription))
        default:
            // 未知转录引擎 id —— 保守视为不可用，避免误进入有效列表。
            Log.w("EngineAvailabilityProbe: unknown transcription engine id: \(id)")
            return .unavailable(.localModelNotReady(detail: "Unknown engine: \(id)"))
        }
    }

    /// 判断翻译引擎（由 `translationEnginePriority` 中的 id 驱动）的客观可用性。
    func availability(ofTranslationEngine id: String) -> EngineAvailability {
        switch id {
        case "apple":
            // 非 nil = macOS 15+ 且 LocalTranslatorFactory.make() 已成功构造。
            return localTranslator() != nil
                ? .available
                : .unavailable(.osTooOld(requiredVersion: "macOS 15.0"))
        case "cloud":
            return settingsStore.hasApiKey
                ? .available
                : .unavailable(.missingApiKey)
        default:
            // 未知翻译引擎 id —— 保守视为不可用。
            Log.w("EngineAvailabilityProbe: unknown translation engine id: \(id)")
            return .unavailable(.missingApiKey)
        }
    }
}
