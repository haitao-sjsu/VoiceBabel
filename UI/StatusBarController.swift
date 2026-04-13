// StatusBarController.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 菜单栏 UI 控制器 —— 管理 NSStatusItem 图标和下拉菜单。
//
// 职责：
//   1. 图标管理：根据 RecordingController.AppState 动态切换菜单栏 emoji 图标
//      - idle：根据 ApiMode 显示 🎙📶（cloud/realtime）或 🎙🏠（local）
//      - recording: 🔴 / processing: ⏳ / error: ⚠️
//   2. 下拉菜单：转录(⌥)/翻译(⌥⌥) 按钮、复制并粘贴上次转写、设置、关于、退出
//   3. 状态联动：根据 AppState 更新菜单项文字和可用性（录音中→显示"停止录音"等）
//
// 本文件还定义了两个域枚举：
//   - ApiMode：API 模式（local/cloud/realtime），被 RecordingController 和 AppDelegate 使用
//   - AutoSendMode：自动发送模式（off/always/smart），被 RecordingController 使用
//   注意：这两个枚举是域级概念，理论上应该独立于 UI 层，但目前嵌套在此处
//
// 依赖：
//   - RecordingController.AppState：应用状态枚举
//
// 架构角色：
//   纯 UI 层，不持有业务逻辑。通过闭包回调（onTranscribeToggle, onTranslateToggle,
//   onQuit, onOpenSettings）将用户操作转发给 AppDelegate。
//   由 AppDelegate 创建，RecordingController 通过 onStateChange 回调驱动其更新。

import Cocoa

class StatusBarController {

    // MARK: - 回调

    /// 点击语音转文字按钮时的回调
    var onTranscribeToggle: (() -> Void)?

    /// 点击语音翻译按钮时的回调
    var onTranslateToggle: (() -> Void)?

    /// 点击退出时的回调
    var onQuit: (() -> Void)?

    /// 点击设置时的回调
    var onOpenSettings: (() -> Void)?

    // MARK: - API 模式枚举

    enum ApiMode: String {
        case local = "local"
        case cloud = "cloud"
        case realtime = "realtime"
    }

    // MARK: - 自动发送模式枚举

    enum AutoSendMode: String {
        case off = "off"
        case always = "always"
        case smart = "smart"

        var displayName: String {
            switch self {
            case .off: return "仅转写"
            case .always: return "转写+自动发送"
            case .smart: return "转写+延迟发送"
            }
        }

        static func from(_ string: String) -> AutoSendMode {
            return AutoSendMode(rawValue: string) ?? .smart
        }
    }

    // MARK: - UI 组件

    /// 状态栏图标
    private var statusItem: NSStatusItem!

    /// 菜单
    private var menu: NSMenu!

    /// 当前应用状态
    private var currentAppState: RecordingController.AppState = .idle

    /// 语音转文字按钮
    private var transcribeMenuItem: NSMenuItem!

    /// 语音翻译按钮
    private var translateMenuItem: NSMenuItem!

    /// 当前 API 模式
    private var currentApiMode: ApiMode

    /// 上次转写结果菜单项
    private var lastTranscriptionItem: NSMenuItem!

    /// 上次转写的完整文本
    private var lastTranscriptionText: String = ""

    // MARK: - 状态文字映射

    private let stateIcons: [RecordingController.AppState: String] = [
        .idle: "🎙",  // 待机图标会根据 API 模式动态替换
        .recording: "🔴",
        .processing: "⏳",
        .waitingToSend: "⏳",
        .error: "⚠️"
    ]

    /// 待机状态下根据 API 模式显示的图标
    private func idleIcon() -> String {
        switch currentApiMode {
        case .cloud, .realtime:
            return "🎙📶"
        case .local:
            return "🎙🏠"
        }
    }

    // MARK: - 初始化

    init(apiMode: ApiMode) {
        self.currentApiMode = apiMode
        setupStatusBar()
    }

    private func setupStatusBar() {
        // 创建状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = idleIcon()
        }

        // 创建菜单
        menu = NSMenu()

        // 语音转文字按钮
        transcribeMenuItem = NSMenuItem(
            title: "🎤 开始转录 (⌥)",
            action: #selector(transcribeClicked),
            keyEquivalent: ""
        )
        transcribeMenuItem.target = self
        menu.addItem(transcribeMenuItem)

        // 语音翻译按钮
        translateMenuItem = NSMenuItem(
            title: "🌐 开始翻译 (⌥⌥)",
            action: #selector(translateClicked),
            keyEquivalent: ""
        )
        translateMenuItem.target = self
        menu.addItem(translateMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 复制上次转写结果（两行：提示 + 内容预览）
        let copyHintItem = NSMenuItem(title: "复制并粘贴上次转写:", action: nil, keyEquivalent: "")
        copyHintItem.isEnabled = false
        menu.addItem(copyHintItem)

        lastTranscriptionItem = NSMenuItem(
            title: "  (无)",
            action: nil,
            keyEquivalent: ""
        )
        lastTranscriptionItem.target = self
        lastTranscriptionItem.isEnabled = false
        menu.addItem(lastTranscriptionItem)

        menu.addItem(NSMenuItem.separator())

        // 设置
        let settingsItem = NSMenuItem(
            title: "设置...",
            action: #selector(settingsClicked),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 关于
        let aboutItem = NSMenuItem(
            title: "关于 WhisperUtil",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        // 退出
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitClicked),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - 公共方法

    /// 设置 API 模式
    func setApiMode(_ mode: ApiMode) {
        currentApiMode = mode
        // 更新待机图标以反映当前 API 模式
        if let button = statusItem.button, currentAppState == .idle {
            button.title = idleIcon()
        }
    }

    /// 更新上次转写结果
    func setLastTranscription(_ text: String) {
        lastTranscriptionText = text
        if text.isEmpty {
            lastTranscriptionItem.title = "  (无)"
            lastTranscriptionItem.action = nil
            lastTranscriptionItem.isEnabled = false
        } else {
            let preview = text.count > 10
                ? String(text.prefix(10)) + "..."
                : text
            lastTranscriptionItem.title = "  📋 \(preview)"
            lastTranscriptionItem.action = #selector(copyLastTranscription)
            lastTranscriptionItem.isEnabled = true
        }
    }

    /// 更新状态显示
    func updateState(_ state: RecordingController.AppState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 更新图标（待机时根据 API 模式显示不同图标）
            if let button = self.statusItem.button {
                if state == .idle {
                    button.title = self.idleIcon()
                } else {
                    button.title = self.stateIcons[state] ?? "🎙"
                }
            }

            // 记录当前状态
            self.currentAppState = state

            // 更新按钮状态
            switch state {
            case .idle, .error:
                // 恢复所有选项
                self.transcribeMenuItem.title = "🎤 开始转录 (⌥)"
                self.transcribeMenuItem.isEnabled = true
                self.transcribeMenuItem.isHidden = false

                self.translateMenuItem.title = "🌐 开始翻译 (⌥⌥)"
                self.translateMenuItem.isEnabled = true
                self.translateMenuItem.isHidden = false

            case .recording:
                // 只显示一个停止录音按钮
                self.transcribeMenuItem.title = "⏹ 停止录音"
                self.transcribeMenuItem.isEnabled = true
                self.transcribeMenuItem.isHidden = false

                // 隐藏翻译按钮
                self.translateMenuItem.isHidden = true

            case .processing:
                self.transcribeMenuItem.title = "⏳ 处理中..."
                self.transcribeMenuItem.isEnabled = false
                self.transcribeMenuItem.isHidden = false

                self.translateMenuItem.isHidden = true

            case .waitingToSend:
                self.transcribeMenuItem.title = "⏳ 等待发送... (单击⌥取消)"
                self.transcribeMenuItem.isEnabled = false
                self.transcribeMenuItem.isHidden = false

                self.translateMenuItem.isHidden = true
            }
        }
    }

    /// 显示通知（仅日志记录，视觉反馈通过菜单栏图标实现）
    func showNotification(title: String, message: String) {
        Log.i("通知: [\(title)] \(message)")
    }

    // MARK: - 菜单动作

    @objc private func transcribeClicked() {
        onTranscribeToggle?()
    }

    @objc private func translateClicked() {
        onTranslateToggle?()
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    @objc private func copyLastTranscription() {
        guard !lastTranscriptionText.isEmpty else { return }
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        pasteboard.setString(lastTranscriptionText, forType: .string)
        Log.i("复制上次转写并粘贴: \(lastTranscriptionText)")

        // 菜单关闭后焦点会自动回到之前的应用，延迟后模拟 Cmd+V 粘贴
        // 不恢复原剪贴板：用户主动操作，保留转写内容以便再次粘贴
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let source = CGEventSource(stateID: .hidSystemState)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "关于 WhisperUtil"
        alert.informativeText = """
            版本 1.0.0

            语音转文字 & 翻译工具
            使用 OpenAI Whisper API

            功能:
            • 语音转文字 - 识别语音并输出原文
            • 语音翻译 - 识别语音并翻译成英文
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
