// TextInputter.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 文本输入模块 —— 将转录/翻译结果输入到当前活跃的应用程序。
//
// 职责：
//   1. 文本输入：支持两种方式将文字发送到目标应用
//      - clipboard（默认）：保存原剪贴板 → 写入 → Cmd+V → 延迟恢复原内容
//      - keyboard：CGEvent 逐字符模拟输入（支持 CJK 等 Unicode 字符）
//   2. 文本后处理：繁体→简体转换、特殊标签过滤（[MUSIC] 等）
//   3. 自动发送：pressReturnKey() 模拟 Enter 键，由 RecordingController 调用
//   4. 原始输入：inputTextRaw() 仅做繁简转换（用于 Realtime delta 保留空格）
//
// 底层原理：
//   使用 macOS CGEvent API 创建并注入键盘事件到 HID 事件流。
//   .cghidEventTap 注入点使模拟按键与物理按键行为一致。
//   Unicode 字符通过 keyboardSetUnicodeString 方法绕过键码映射。
//
// 权限要求：
//   需要「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能）。
//   无权限时 CGEvent.post() 静默失败。
//
// 依赖：
//   - CGEvent (Core Graphics)：模拟键盘事件
//   - Carbon：虚拟键码常量（kVK_Return 等）
//   - EngineeringOptions：enableTraditionalToSimplified, enableTagFiltering, clipboardPasteDelay, clipboardRestoreDelay
//
// 架构角色：
//   由 AppDelegate 创建，由 RecordingController 在转录/翻译完成后调用。

import Cocoa
import Carbon

class TextInputter {

    // MARK: - 输入方式

    enum InputMethod {
        case keyboard   // 逐字符键盘模拟输入
        case clipboard  // 剪贴板粘贴（Cmd+V）
    }

    // MARK: - 配置

    /// 当前使用的输入方式
    var method: InputMethod = .clipboard

    /// 键盘模拟模式下每个字符之间的延迟（秒）
    /// 某些应用处理输入较慢，需要设置延迟才能正确接收所有字符
    var typingDelay: TimeInterval = 0

    // MARK: - 公共方法

    /// 将文本输入到当前活跃的应用程序（经过后处理：繁转简、过滤标签）
    /// - Parameter text: 要输入的文本（转录或翻译结果）
    func inputText(_ text: String) {
        guard !text.isEmpty else { return }

        // 统一后处理：繁体→简体、去除特殊标签
        let processed = Self.postProcess(text)
        guard !processed.isEmpty else { return }

        rawInput(processed)
    }

    /// 将文本输入，仅做繁转简，不做其他后处理（不 trim、不过滤标签）
    /// 用于 Realtime API delta 等需要保留空格的场景
    func inputTextRaw(_ text: String) {
        guard !text.isEmpty else { return }
        if EngineeringOptions.enableTraditionalToSimplified {
            let mutableText = NSMutableString(string: text)
            CFStringTransform(mutableText, nil, "Traditional-Simplified" as CFString, false)
            rawInput(mutableText as String)
        } else {
            rawInput(text)
        }
    }

    /// 内部输入方法
    private func rawInput(_ text: String) {
        switch method {
        case .keyboard:
            typeText(text)
        case .clipboard:
            pasteText(text)
        }
    }

    /// 文本后处理：繁体转简体、过滤特殊标签
    /// 所有模式（本地/云端/实时/翻译）的输出都经过此处理
    private static func postProcess(_ text: String) -> String {
        var result = text

        // 过滤 Whisper 输出的特殊标签（如 [MUSIC]、[BLANK_AUDIO] 等）
        if EngineeringOptions.enableTagFiltering {
            result = result.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        }

        // 繁体中文 → 简体中文
        if EngineeringOptions.enableTraditionalToSimplified {
            let mutableText = NSMutableString(string: result)
            CFStringTransform(mutableText, nil, "Traditional-Simplified" as CFString, false)
            result = mutableText as String
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 使用键盘模拟逐字符输入文本
    ///
    /// 对于换行符和制表符使用对应的物理键码，
    /// 其他字符使用 Unicode 输入方式（支持中文等非 ASCII 字符）
    ///
    /// - Parameter text: 要输入的文本
    func typeText(_ text: String) {
        for character in text {
            if character == "\n" {
                pressKey(keyCode: 36)   // macOS 键码 36 = Return 键
            } else if character == "\t" {
                pressKey(keyCode: 48)   // macOS 键码 48 = Tab 键
            } else {
                typeCharacter(character)
            }

            // 如果设置了延迟，在每个字符之间暂停
            if typingDelay > 0 {
                Thread.sleep(forTimeInterval: typingDelay)
            }
        }
    }

    /// 使用剪贴板粘贴文本
    ///
    /// 流程：保存原剪贴板 → 写入新文本 → 模拟 Cmd+V → 等待粘贴 → 恢复原剪贴板
    ///
    /// - Parameter text: 要粘贴的文本
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // 保存原剪贴板内容，以便粘贴后恢复
        let originalContents = pasteboard.string(forType: .string)

        // 将转录结果写入剪贴板
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 模拟 Cmd+V 按键组合，触发粘贴操作
        // keyCode 9 = "V" 键
        pressKey(keyCode: 9, flags: .maskCommand)

        // 等待目标应用处理粘贴事件
        Thread.sleep(forTimeInterval: EngineeringOptions.clipboardPasteDelay)

        // 异步恢复原剪贴板内容（延迟一小段时间确保粘贴完成）
        if let original = originalContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.clipboardRestoreDelay) {
                pasteboard.clearContents()
                pasteboard.setString(original, forType: .string)
            }
        }
    }

    /// 模拟按下 Return（Enter）键
    /// 用于自动发送功能：在文本粘贴/输入完成后按 Enter 发送消息
    func pressReturnKey() {
        pressKey(keyCode: 36)  // macOS 键码 36 = Return 键
    }

    // MARK: - 私有方法

    /// 模拟一次完整的按键操作（按下 + 释放）
    ///
    /// 使用 CGEvent API 创建键盘事件并发送到系统事件流。
    /// .cghidEventTap 表示事件注入点为 HID（人机接口设备）层级，
    /// 模拟的按键与物理按键行为一致。
    ///
    /// - Parameters:
    ///   - keyCode: macOS 虚拟键码（与 HotkeyManager 中的键码映射一致）
    ///   - flags: 修饰键标志（如 .maskCommand 表示 Command 键）
    private func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        // 创建事件源，使用 HID 系统状态以获取最准确的键盘状态
        let source = CGEventSource(stateID: .hidSystemState)

        // 创建并发送 "按下" 事件
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cghidEventTap)
        }

        // 创建并发送 "释放" 事件
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// 使用 Unicode 方式输入单个字符
    ///
    /// 对于中文、日文、emoji 等非 ASCII 字符，无法直接映射到物理键码。
    /// CGEvent 提供了 keyboardSetUnicodeString 方法，可以直接将 Unicode
    /// 字符附加到键盘事件上，绕过键码映射。
    ///
    /// - Parameter character: 要输入的单个字符
    private func typeCharacter(_ character: Character) {
        let source = CGEventSource(stateID: .hidSystemState)

        // 将 Swift Character 转换为 UniChar（UTF-16 编码单元）
        var char = UniChar(String(character).utf16.first ?? 0)

        // 创建按下事件，将 Unicode 字符附加上去
        // virtualKey 传 0 表示不使用物理键码
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
            keyDown.post(tap: .cghidEventTap)
        }

        // 释放事件（不需要附加 Unicode 字符串）
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 权限检查

    /// 检查应用是否拥有辅助功能权限
    ///
    /// 辅助功能权限是向其他应用发送模拟按键事件的前提条件。
    /// 如果没有权限，CGEvent.post() 将静默失败（不会报错但也不会生效）。
    /// 传入 kAXTrustedCheckOptionPrompt = true 会在没有权限时弹出系统授权提示。
    ///
    /// - Returns: 是否已获得辅助功能权限
    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
