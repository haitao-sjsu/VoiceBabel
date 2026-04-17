// HotkeyManager.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 全局快捷键管理器 —— 基于 Option 键手势的输入检测。
//
// 职责：
//   通过 NSEvent 全局/本地监听器检测 Option 键的三种手势，并通过回调通知调用方。
//   同时监听 ESC 键用于取消录音/处理。
//
// 支持的手势：
//   1. 按住 Option > 400ms → Push-to-Talk（松开结束录音）
//   2. 单击 Option（<400ms 内松开）→ 切换长聊模式
//   3. 双击 Option（两次单击间隔 <400ms）→ 切换翻译模式
//   4. ESC 键 → 取消当前录音或处理
//
// 状态机：
//   idle → optionDown（按下，启动 400ms 计时器）
//     → pushToTalkActive（计时器到期，长按确认）→ idle（松开）
//     → waitingSecondTap（快速松开，等待双击）→ idle（超时=单击 / 再次按下=双击）
//
// 冲突避免：
//   - Option + 其他修饰键（Shift/Cmd/Ctrl）→ 取消检测
//   - Option 按住期间按其他键（如 Tab）→ 取消检测
//   - 左右 Option 键均可触发
//
// 依赖：
//   - EngineeringOptions：optionHoldThreshold（按住阈值）、doubleTapWindow（双击窗口）
//   - Log：日志输出
//
// 架构角色：
//   由 AppDelegate 创建并配置回调，连接到 AppController 的录音控制方法。

import Cocoa

class HotkeyManager {

    // MARK: - 回调

    /// Push-to-Talk 开始（Option 按住超过阈值）
    var onPushToTalkStart: (() -> Void)?

    /// Push-to-Talk 结束（Option 松开）
    var onPushToTalkStop: (() -> Void)?

    /// 单击 Option 键（切换长聊模式 / 取消智能等待）
    /// Option 按下后在 400ms 内松开，且双击窗口过期后触发
    var onSingleTap: (() -> Void)?

    /// 双击 Option 键（切换翻译模式）
    var onDoubleTap: (() -> Void)?

    /// ESC 键按下（取消录音/处理）
    var onEscPressed: (() -> Void)?

    // MARK: - 状态机

    /// 手势检测状态
    private enum DetectorState {
        case idle              // 无活动
        case optionDown        // Option 已按下，等待判断是按住还是快速释放
        case pushToTalkActive  // 按住超过阈值，Push-to-Talk 录音中
        case waitingSecondTap  // 快速释放后，等待第二次按下（双击检测）
    }

    private var state: DetectorState = .idle

    // MARK: - 定时器

    /// 按住检测定时器（400ms 后触发 Push-to-Talk）
    private var holdTimer: DispatchWorkItem?

    /// 双击检测定时器（400ms 窗口过期后触发单击）
    private var doubleTapTimer: DispatchWorkItem?

    // MARK: - 事件监听器

    private var globalFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?

    /// 追踪 Option 键的上一个状态，用于检测按下/松开边沿
    private var wasOptionPressed: Bool = false

    // MARK: - 初始化

    deinit {
        stopMonitoring()
    }

    // MARK: - 公共方法

    /// 开始监听 Option 键手势
    func startMonitoring() {
        // 全局监听（应用不在前台时）
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }

        // 本地监听（应用在前台时，如菜单栏打开）
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        Log.i(LocaleManager.shared.logLocalized("Option key gesture monitoring started"))
    }

    /// 停止监听
    func stopMonitoring() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        globalKeyMonitor = nil
        localFlagsMonitor = nil
        localKeyMonitor = nil
        cancelAllTimers()
        state = .idle
        wasOptionPressed = false
        Log.i(LocaleManager.shared.logLocalized("Option key gesture monitoring stopped"))
    }

    // MARK: - 事件处理

    /// 处理修饰键状态变化
    private func handleFlagsChanged(_ event: NSEvent) {
        let isOptionPressed = event.modifierFlags.contains(.option)

        // 检查是否有其他修饰键同时按下（Cmd、Ctrl、Shift）
        let otherModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.option, .capsLock, .numericPad, .function])
        let hasOtherModifiers = !otherModifiers.isEmpty

        let wasPressed = wasOptionPressed
        wasOptionPressed = isOptionPressed

        if isOptionPressed && !wasPressed {
            // Option 刚按下
            if hasOtherModifiers {
                // Option + 其他修饰键 → 取消检测
                cancelAndReset()
                return
            }
            onOptionPressed()
        } else if !isOptionPressed && wasPressed {
            // Option 刚松开
            onOptionReleased()
        } else if hasOtherModifiers && (state == .optionDown || state == .waitingSecondTap) {
            // 在检测过程中按了其他修饰键 → 取消
            cancelAndReset()
        }
    }

    /// 处理普通按键（非修饰键）
    private func handleKeyDown(_ event: NSEvent) {
        // ESC 键（keyCode 53）：取消录音/处理
        if event.keyCode == 53 {
            Log.i(LocaleManager.shared.logLocalized("ESC key detected"))
            onEscPressed?()
            return
        }

        if state == .optionDown || state == .waitingSecondTap {
            // Option 按住期间或等待双击期间按了其他键 → 取消检测，不干扰正常快捷键
            Log.d("Option gesture cancelled: other key detected (keyCode: \(event.keyCode))")
            cancelAndReset()
        }
    }

    // MARK: - 状态转换

    /// Option 键按下
    private func onOptionPressed() {
        switch state {
        case .idle:
            // 开始检测：启动 400ms 计时器
            state = .optionDown
            startHoldTimer()

        case .waitingSecondTap:
            // 在双击窗口内再次按下 → 双击确认！
            cancelAllTimers()
            state = .idle
            Log.i(LocaleManager.shared.logLocalized("Option double-tap detected"))
            onDoubleTap?()

        case .pushToTalkActive, .optionDown:
            // 不应该发生（Option 已按下时又收到按下事件），忽略
            break
        }
    }

    /// Option 键松开
    private func onOptionReleased() {
        switch state {
        case .optionDown:
            // 在 400ms 阈值内松开 → 可能是单击或双击的第一击
            cancelAllTimers()
            state = .waitingSecondTap
            startDoubleTapTimer()

        case .pushToTalkActive:
            // Push-to-Talk 结束
            state = .idle
            Log.i(LocaleManager.shared.logLocalized("Push-to-Talk ended (Option key released)"))
            onPushToTalkStop?()

        case .idle, .waitingSecondTap:
            break
        }
    }

    // MARK: - 定时器管理

    /// 启动按住检测定时器
    private func startHoldTimer() {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .optionDown else { return }
            self.state = .pushToTalkActive
            Log.i(LocaleManager.shared.logLocalized("Push-to-Talk started (Option key held") + " >\(EngineeringOptions.optionHoldThreshold)s)")
            self.onPushToTalkStart?()
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.optionHoldThreshold, execute: work)
    }

    /// 启动双击检测定时器
    private func startDoubleTapTimer() {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .waitingSecondTap else { return }
            self.state = .idle
            Log.i(LocaleManager.shared.logLocalized("Option single-tap detected"))
            self.onSingleTap?()
        }
        doubleTapTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EngineeringOptions.doubleTapWindow, execute: work)
    }

    /// 取消所有定时器
    private func cancelAllTimers() {
        holdTimer?.cancel()
        holdTimer = nil
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
    }

    /// 取消检测并重置状态
    private func cancelAndReset() {
        Log.d("HotkeyManager: gesture cancelled and reset")
        cancelAllTimers()
        state = .idle
    }
}
