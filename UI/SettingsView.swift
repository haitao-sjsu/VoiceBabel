// SettingsView.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// SwiftUI 设置面板视图 —— 通过 SettingsStore 双向绑定所有用户可调参数。
//
// 职责：
//   提供图形化的设置界面，让用户无需修改代码即可调整偏好。
//   所有设置通过 @ObservedObject 绑定到 SettingsStore，变更即时持久化到 UserDefaults
//   并通过 Combine 通知 AppDelegate 更新业务逻辑。
//
// 面板布局（4 个 Section）：
//   1. 语言：识别语言选择（自动/中文/英文/日文/韩文）
//   2. 转写：默认 API 模式（本地/网络/实时）、文本优化模式（关闭/自然/正式/口语）
//   3. 翻译：输出语言选择（英/中/日/韩/法/德/西）
//   4. 通用：发送模式（仅转写/自动发送/延迟发送）、延迟时间 Stepper、提示音开关
//
// 依赖：
//   - SettingsStore：ObservableObject 单例，持久化用户偏好
//
// 架构角色：
//   嵌入在 SettingsWindowController 的 NSHostingController 中显示。
//   由 StatusBarController 的"设置..."菜单项触发打开。

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            // MARK: - 语言
            Section("语言") {
                Picker("识别语言", selection: $store.whisperLanguage) {
                    Text("自动检测").tag("")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
            }

            // MARK: - 转写
            Section("转写") {
                Picker("默认 API 模式", selection: $store.defaultApiMode) {
                    Text("本地识别 (WhisperKit)").tag("local")
                    Text("网络 API").tag("cloud")
                    Text("实时 API").tag("realtime")
                }

                Picker("文本优化", selection: $store.textCleanupMode) {
                    Text("关闭").tag("off")
                    Text("自然润色").tag("neutral")
                    Text("正式风格").tag("formal")
                    Text("口语风格").tag("casual")
                }
            }

            // MARK: - 翻译
            Section("翻译") {
                Picker("输出语言", selection: $store.translationTargetLanguage) {
                    Text("English").tag("en")
                    Text("中文").tag("zh")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Español").tag("es")
                }
            }

            // MARK: - 通用
            Section("通用") {
                Picker("发送模式", selection: $store.autoSendMode) {
                    Text("仅转写").tag("off")
                    Text("转写+自动发送").tag("always")
                    Text("转写+延迟发送").tag("smart")
                }

                if store.autoSendMode == "smart" {
                    Stepper(
                        "延迟时间: \(Int(store.smartModeWaitDuration)) 秒",
                        value: $store.smartModeWaitDuration,
                        in: 2...15,
                        step: 1
                    )
                }

                Toggle("播放提示音", isOn: $store.playSound)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }
}
