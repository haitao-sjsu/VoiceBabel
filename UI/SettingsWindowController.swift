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
        window.title = LocaleManager.shared.localized("WhisperUtil Settings")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func showSettings() {
        installEditMenuIfNeeded()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单栏应用（LSUIElement）没有标准 Edit 菜单，
    /// 导致 Cmd+V 等快捷键在 TextField 中不可用。这里补上。
    private func installEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }

        let mainMenu = NSApp.mainMenu ?? NSMenu()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }
}
