// SettingsWindowController.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// NSWindow 包装器 —— 将 SwiftUI SettingsView 嵌入 NSHostingController 并作为独立窗口展示。
//
// 职责：
//   1. 创建设置窗口：标题栏 + 关闭按钮，固定尺寸 500×560
//   2. 提供 showSettings() 方法：激活窗口并置顶（NSApp.activate）
//   3. isReleasedWhenClosed = false：关闭窗口时保留实例，下次打开不需要重建
//
// 依赖：
//   - SettingsView：SwiftUI 设置面板视图
//   - SettingsStore：传递给 SettingsView 作为数据源
//
// 架构角色：
//   由 AppDelegate 创建，由 StatusBarController 的 onOpenSettings 回调触发显示。

import Cocoa
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settingsStore: SettingsStore) {
        let hostingController = NSHostingController(rootView: SettingsView(store: settingsStore))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "WhisperUtil 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
