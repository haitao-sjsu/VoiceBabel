// NetworkHealthMonitor.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 网络健康探测器 —— 用于 Cloud API 回退到本地后自动检测网络恢复。
//
// 职责：
//   在 Cloud API 因网络问题回退到本地 WhisperKit 后，持续探测网络是否恢复，
//   恢复后通过 onCloudRecovered 回调通知 AppDelegate 切回 Cloud 模式。
//
// 探测策略：
//   1. NWPathMonitor 实时监测网络接口状态（无网络时跳过 HTTP 探测，避免浪费）
//   2. Timer 定期（默认 30s）发送轻量 HEAD 请求到 api.openai.com/v1/models
//   3. HTTP 200 响应 → 网络已恢复 → 停止探测 → 触发 onCloudRecovered
//   4. 用户手动切换 API 模式时，AppDelegate 调用 stopMonitoring() 停止探测
//
// 依赖：
//   - Network.NWPathMonitor：网络接口状态监测
//   - EngineeringOptions：cloudProbeInterval（探测间隔）
//
// 架构角色：
//   由 AppDelegate 创建并配置 onCloudRecovered 回调。
//   在 RecordingController.onError 中触发 startMonitoring()，
//   在用户手动切换模式或网络恢复时 stopMonitoring()。

import Foundation
import Network

class NetworkHealthMonitor {

    // MARK: - 回调

    /// 探测到 Cloud API 恢复时的回调
    var onCloudRecovered: (() -> Void)?

    // MARK: - 配置

    /// API 密钥（用于 HEAD 请求认证）
    private let apiKey: String

    /// 探测间隔（秒）
    private let probeInterval: TimeInterval

    // MARK: - 状态

    /// 是否正在探测
    private(set) var isMonitoring: Bool = false

    /// 网络路径监控器
    private var pathMonitor: NWPathMonitor?

    /// 当前是否有网络
    private var hasNetwork: Bool = false

    /// 探测定时器
    private var probeTimer: Timer?

    /// 探测请求的 URL
    private let probeURL = URL(string: "https://api.openai.com/v1/models")!

    /// 探测请求超时（秒）
    private let probeTimeout: TimeInterval = 5

    // MARK: - 初始化

    init(apiKey: String, probeInterval: TimeInterval = EngineeringOptions.cloudProbeInterval) {
        self.apiKey = apiKey
        self.probeInterval = probeInterval
    }

    // MARK: - 公共方法

    /// 开始网络健康探测
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        Log.i(LocaleManager.shared.logLocalized("NetworkHealthMonitor: starting Cloud API probe") + " (interval \(Int(probeInterval))s)")

        // 启动网络路径监控
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            self?.hasNetwork = connected
            Log.d("NetworkHealthMonitor: network status -> \(connected ? "connected" : "disconnected")")
        }
        pathMonitor?.start(queue: DispatchQueue.global(qos: .utility))

        // 启动定期探测（在主线程创建 Timer）
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.probeTimer = Timer.scheduledTimer(
                withTimeInterval: self.probeInterval,
                repeats: true
            ) { [weak self] _ in
                self?.probeCloudAPI()
            }
        }
    }

    /// 停止网络健康探测
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        Log.i(LocaleManager.shared.logLocalized("NetworkHealthMonitor: stopped probing"))

        probeTimer?.invalidate()
        probeTimer = nil

        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - 私有方法

    /// 发送轻量 HEAD 请求探测 Cloud API 可达性
    private func probeCloudAPI() {
        // 没有网络接口时跳过探测
        guard hasNetwork else {
            Log.d("NetworkHealthMonitor: no network, skipping probe")
            return
        }

        var request = URLRequest(url: probeURL)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = probeTimeout

        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self, self.isMonitoring else { return }

            if let error = error {
                Log.d("NetworkHealthMonitor: probe failed - \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                Log.i(LocaleManager.shared.logLocalized("NetworkHealthMonitor: Cloud API recovered"))
                DispatchQueue.main.async {
                    self.stopMonitoring()
                    self.onCloudRecovered?()
                }
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code >= 400 && code < 500 {
                    Log.w("NetworkHealthMonitor: probe returned client error: \(code)")
                } else {
                    Log.d("NetworkHealthMonitor: probe returned non-200 status: \(code)")
                }
            }
        }
        task.resume()
    }

    deinit {
        stopMonitoring()
    }
}
