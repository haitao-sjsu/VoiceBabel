// main.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 应用入口点。创建 NSApplication 实例，设置 .accessory 激活策略（不显示 Dock 图标），
// 将 AppDelegate 设为代理并启动主运行循环。
//
// 架构角色：
//   整个应用的启动入口，创建 AppDelegate（组合根）并移交控制权。
//
// 依赖：
//   - AppDelegate：应用程序委托，负责初始化所有组件

import Cocoa

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

MainActor.assumeIsolated {
    runApp()
}
