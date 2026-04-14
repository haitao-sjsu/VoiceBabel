# API Key 安全管理方案

## Part 1: 现状分析

### 1.1 当前存储位置

API Key 硬编码在 `Config/EngineeringOptions.swift` 第 38 行：

```swift
static let apiKey = "sk-proj-eCDKnsp..."
```

虽然该文件已加入 `.gitignore`，并提供了 `EngineeringOptions.swift.template` 模板供新环境克隆后手动填写，但密钥仍以明文形式存在于源代码中。

### 1.2 API Key 的完整引用链

从源头到最终使用，API Key 经过以下路径传播：

| 步骤 | 文件 | 行号 | 说明 |
|------|------|------|------|
| 1. 定义 | `Config/EngineeringOptions.swift` | 38 | `static let apiKey = "sk-proj-..."` |
| 2. 组装 | `Config/Config.swift` | 29, 52 | `let openaiApiKey: String` ← `EngineeringOptions.apiKey` |
| 3. 分发 | `AppDelegate.swift` | 121 | `ServiceCloudOpenAI(apiKey: config.openaiApiKey, ...)` |
| 3. 分发 | `AppDelegate.swift` | 127 | `ServiceRealtimeOpenAI(apiKey: config.openaiApiKey, ...)` |
| 3. 分发 | `AppDelegate.swift` | 136 | `ServiceTextCleanup(apiKey: config.openaiApiKey)` |
| 3. 分发 | `AppDelegate.swift` | 160 | `NetworkHealthMonitor(apiKey: config.openaiApiKey)` |
| 4. 使用 | `Services/ServiceCloudOpenAI.swift` | 131, 242 | `Bearer \(apiKey)` HTTP Header |
| 4. 使用 | `Services/ServiceRealtimeOpenAI.swift` | 104 | `Bearer \(apiKey)` WebSocket Header |
| 4. 使用 | `Services/ServiceTextCleanup.swift` | 118 | `Bearer \(apiKey)` HTTP Header |
| 4. 使用 | `Utilities/NetworkHealthMonitor.swift` | 126 | `Bearer \(apiKey)` HEAD 请求 |

共 **4 个消费者**，全部通过 `AppDelegate.setupComponents()` 在启动时注入。

### 1.3 当前方案的安全风险

| 风险 | 严重程度 | 说明 |
|------|----------|------|
| 源码泄露 | 高 | 如果 `.gitignore` 配置出错或开发者误操作 `git add -A`，密钥将提交到版本控制 |
| 编译产物暴露 | 中 | 字符串常量编译后以明文嵌入二进制文件，可通过 `strings WhisperUtil` 提取 |
| 共享困难 | 低 | 每个用户/开发者需要手动修改源码填入自己的密钥 |
| 单密钥绑定 | 低 | 密钥与代码绑定，无法在运行时切换或更新 |

---

## Part 2: macOS 安全存储方案对比

### 2.1 macOS Keychain（Security.framework）

**原理**：macOS Keychain 是操作系统提供的加密凭据存储，数据使用用户登录密码派生的密钥加密。应用通过 `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete` 四个 C 函数操作。

**优点**：
- OS 级加密，数据存储在 `~/Library/Keychains/` 的加密数据库中
- 应用删除后数据默认保留（可选清除）
- macOS 标准实践，所有原生密码管理器都使用它
- 沙盒应用自动获得 Keychain 访问权限（无需额外 entitlement）
- 支持访问控制（可要求用户认证后才能读取）

**缺点**：
- C API 较繁琐（需要构造 `CFDictionary` 查询）
- 首次访问可能弹出 Keychain 授权弹窗（非沙盒应用）
- 调试时错误信息不直观（`OSStatus` 错误码）

**Swift 封装示例**：

```swift
import Security

enum KeychainHelper {

    private static let service = "com.whisperutil.api"
    private static let account = "openai-api-key"

    /// 保存 API Key 到 Keychain
    static func save(apiKey: String) -> Bool {
        guard let data = apiKey.data(using: .utf8) else { return false }

        // 先尝试删除已有条目（避免 errSecDuplicateItem）
        delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.e("Keychain 保存失败: \(status)")
        }
        return status == errSecSuccess
    }

    /// 从 Keychain 读取 API Key
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// 从 Keychain 删除 API Key
    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 检查 Keychain 中是否存在 API Key
    static func exists() -> Bool {
        return load() != nil
    }
}
```

### 2.2 UserDefaults

**原理**：数据以 plist 文件存储在 `~/Library/Preferences/com.whisperutil.plist`。

**优点**：
- 极其简单，WhisperUtil 现有的 `SettingsStore` 已经使用此机制
- 无需额外依赖

**缺点**：
- **不安全**：plist 文件以明文存储，任何有文件系统访问权限的进程都可读取
- `defaults read com.whisperutil` 命令即可查看所有内容
- 不适合存储敏感凭据

**结论**：**不推荐** 用于 API Key 存储。

### 2.3 加密文件（Application Support + CryptoKit）

**原理**：使用 CryptoKit 的 AES-GCM 加密后存储到 `~/Library/Application Support/WhisperUtil/`。

**优点**：
- 完全自主控制加密方式
- 可以与其他配置数据一起管理

**缺点**：
- 加密密钥本身需要安全存储（又回到了 Keychain 的问题）
- 需要自己实现所有加密/解密/密钥派生逻辑
- 过度工程化——Keychain 已经提供了同等或更好的安全性

**结论**：**不推荐**。如果需要加密存储，直接使用 Keychain 更简单可靠。

### 2.4 环境变量 / .env 文件

**原理**：通过 `ProcessInfo.processInfo.environment["OPENAI_API_KEY"]` 读取。

**优点**：
- 在服务端开发中是标准做法
- 开发调试方便

**缺点**：
- **对普通用户极不友好**——需要修改 shell profile 或 launchd plist
- macOS GUI 应用无法直接读取 shell 环境变量（除非通过 launchd 设置或从 Terminal 启动）
- 不适合面向终端用户的桌面应用

**结论**：**不推荐** 用于 WhisperUtil 这类面向普通用户的 macOS 应用。

### 2.5 推荐方案

**macOS Keychain** 是 WhisperUtil 的最佳选择，理由：

1. **安全性**：OS 级加密，是 macOS 上存储凭据的标准方式
2. **复杂度适中**：封装后仅需 `save()` / `load()` / `delete()` 三个方法
3. **用户体验**：沙盒应用访问 Keychain 无需额外授权弹窗
4. **持久性**：应用更新不丢失密钥，重装后可选保留
5. **行业标准**：MacWhisper、VoiceInk 等同类应用均采用 Keychain 或类似方案

结合 **SettingsStore** 管理 "是否已设置密钥" 的状态标记（非密钥本身），可以在 UI 中正确显示配置状态。

---

## Part 3: UI 设计

### 3.1 设置面板布局

在 `SettingsView.swift` 现有的 4 个 Section 之前，新增一个 "API 密钥" Section，放在最顶部位置：

```
设置面板布局：
1. API 密钥  <-- 新增（最顶部，最重要的配置）
2. 语言
3. 转写
4. 翻译
5. 通用
```

### 3.2 API 密钥 Section 设计

```
+-- API 密钥 ----------------------------------------------+
|                                                           |
|  OpenAI API Key                                           |
|  [***************************kFJ2]  [清除]                |
|  OK 密钥有效                                              |
|                                                           |
|  [获取 API Key ->]              [验证连接]                |
|                                                           |
+-----------------------------------------------------------+
```

**未设置密钥时**：
```
+-- API 密钥 ----------------------------------------------+
|                                                           |
|  OpenAI API Key                                           |
|  [请输入 API Key...]                                      |
|  !! 需要 API Key 才能使用网络转写和翻译功能               |
|                                                           |
|  [获取 API Key ->]              [保存]                    |
|                                                           |
+-----------------------------------------------------------+
```

### 3.3 UX 关键考量

| 需求 | 方案 |
|------|------|
| 遮盖输入 | 使用 `SecureField`，输入时显示圆点而非明文 |
| 显示尾部 | 保存后显示 `*****kFJ2`（仅展示最后 4 位，方便用户确认是哪个 Key） |
| 验证连接 | 点击"验证连接"按钮后调用 `GET /v1/models` 轻量验证 |
| 错误提示 | 验证失败时直接在输入框下方显示红色错误文本 |
| 清除密钥 | "清除"按钮删除 Keychain 中的密钥并重置 UI |
| 获取链接 | "获取 API Key" 按钮打开 `https://platform.openai.com/api-keys` |
| 粘贴体验 | SecureField 天然支持 Cmd+V 粘贴，用户从 OpenAI 网站复制后直接粘贴 |

### 3.4 竞品参考

| 应用 | API Key 管理方式 |
|------|------------------|
| **MacWhisper** | 设置面板中有专门的 API Key 输入框，使用 SecureField，支持验证 |
| **VoiceInk** | 首次启动引导用户输入 API Key，存储在 Keychain 中 |
| **SuperWhisper** | 提供自有后端服务（订阅制），用户无需自行提供 API Key |
| **Whisper Transcription** | 设置中提供 API Key 输入和测试按钮 |

WhisperUtil 应参考 MacWhisper 的做法——在设置面板中提供简洁的 API Key 管理入口。

### 3.5 SwiftUI 示例代码

```swift
// SettingsView.swift 中新增的 Section

// MARK: - API 密钥
Section("API 密钥") {
    if store.hasApiKey {
        // 已设置密钥：显示遮蔽的 Key + 清除按钮
        HStack {
            Text("OpenAI API Key")
            Spacer()
            Text(store.maskedApiKey)
                .foregroundColor(.secondary)
                .font(.system(.body, design: .monospaced))
            Button("清除") {
                store.clearApiKey()
            }
            .foregroundColor(.red)
        }

        // 验证状态
        HStack {
            switch store.apiKeyStatus {
            case .valid:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("密钥有效")
                    .foregroundColor(.green)
            case .invalid(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .foregroundColor(.red)
            case .unchecked:
                EmptyView()
            }
            Spacer()
            Button("验证连接") {
                store.validateApiKey()
            }
            .disabled(store.isValidatingKey)
        }
    } else {
        // 未设置密钥：输入框
        SecureField("请输入 OpenAI API Key", text: $store.apiKeyInput)
            .onSubmit { store.saveApiKey() }

        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("需要 API Key 才能使用网络转写和翻译功能")
                .foregroundColor(.secondary)
                .font(.caption)
        }

        HStack {
            Button("获取 API Key") {
                NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!)
            }
            Spacer()
            Button("保存") {
                store.saveApiKey()
            }
            .disabled(store.apiKeyInput.isEmpty)
        }
    }
}
```

---

## Part 4: 代码重构计划

### 4.1 新增文件：`Config/KeychainHelper.swift`

新建 Keychain 操作封装（代码见 Part 2.1），提供 `save()` / `load()` / `delete()` / `exists()` 四个静态方法。

### 4.2 修改 `Config/EngineeringOptions.swift`

**删除** `apiKey` 字段：

```swift
// 删除以下行：
static let apiKey = "sk-proj-..."
```

API Key 不再属于 EngineeringOptions（工程级配置），而是属于用户级配置，通过 Keychain 管理。

### 4.3 修改 `Config/Config.swift`

将 `openaiApiKey` 改为从 Keychain 加载：

```swift
struct Config {
    let openaiApiKey: String  // 保留字段，但来源变更
    // ... 其他字段不变

    static func load() -> Config {
        let apiKey = KeychainHelper.load() ?? ""  // 无密钥时返回空字符串

        let config = Config(
            openaiApiKey: apiKey,  // <-- 改为从 Keychain 读取
            whisperModel: EngineeringOptions.whisperModel,
            // ... 其他不变
        )

        if apiKey.isEmpty {
            Log.w("配置: 未设置 OpenAI API Key，网络功能不可用")
        }

        return config
    }
}
```

### 4.4 修改 `Config/SettingsStore.swift`

新增 API Key 相关的状态管理属性和方法：

```swift
@MainActor
final class SettingsStore: ObservableObject {
    // ... 现有属性不变

    // ---- 新增 API Key 管理 ----

    /// API Key 输入框绑定值（仅在输入时使用，不持久化到 UserDefaults）
    @Published var apiKeyInput: String = ""

    /// 是否已设置 API Key（从 Keychain 判断）
    @Published var hasApiKey: Bool = false

    /// 遮盖后的 API Key（如 "*****kFJ2"）
    @Published var maskedApiKey: String = ""

    /// API Key 验证状态
    @Published var apiKeyStatus: ApiKeyStatus = .unchecked

    /// 是否正在验证中
    @Published var isValidatingKey: Bool = false

    /// API Key 变更通知（通知 AppDelegate 重建 Services）
    @Published var apiKeyVersion: Int = 0

    enum ApiKeyStatus {
        case unchecked
        case valid
        case invalid(String)
    }

    private init() {
        // ... 现有初始化代码 ...

        // 初始化 API Key 状态
        self.hasApiKey = KeychainHelper.exists()
        if let key = KeychainHelper.load() {
            self.maskedApiKey = Self.maskApiKey(key)
        }
    }

    /// 保存 API Key 到 Keychain
    func saveApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        if KeychainHelper.save(apiKey: key) {
            hasApiKey = true
            maskedApiKey = Self.maskApiKey(key)
            apiKeyInput = ""  // 清空输入框
            apiKeyStatus = .unchecked
            apiKeyVersion += 1  // 触发 AppDelegate 重建 Services
            Log.i("API Key 已保存到 Keychain")
        } else {
            apiKeyStatus = .invalid("保存失败，请重试")
            Log.e("API Key 保存到 Keychain 失败")
        }
    }

    /// 清除 API Key
    func clearApiKey() {
        KeychainHelper.delete()
        hasApiKey = false
        maskedApiKey = ""
        apiKeyStatus = .unchecked
        apiKeyVersion += 1
        Log.i("API Key 已从 Keychain 清除")
    }

    /// 验证 API Key（异步调用 /v1/models）
    func validateApiKey() {
        guard let key = KeychainHelper.load(), !key.isEmpty else {
            apiKeyStatus = .invalid("未设置 API Key")
            return
        }

        isValidatingKey = true
        apiKeyStatus = .unchecked

        Task {
            let result = await ApiKeyValidator.validate(apiKey: key)
            await MainActor.run {
                self.isValidatingKey = false
                self.apiKeyStatus = result
            }
        }
    }

    /// 遮盖 API Key，仅显示最后 4 位
    private static func maskApiKey(_ key: String) -> String {
        guard key.count > 4 else { return "****" }
        let suffix = String(key.suffix(4))
        return "*****\(suffix)"
    }
}
```

### 4.5 修改 `AppDelegate.swift`

关键变更：监听 `apiKeyVersion` 变化，在 API Key 更新时重建相关 Services。

```swift
// 在 setupComponents() 的 Combine 监听部分新增：
settingsStore.$apiKeyVersion.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
    guard let self = self else { return }
    self.rebuildServicesWithNewApiKey()
}.store(in: &cancellables)
```

新增方法：

```swift
/// 当 API Key 变更时重建所有依赖 API Key 的服务
private func rebuildServicesWithNewApiKey() {
    let newKey = KeychainHelper.load() ?? ""

    if newKey.isEmpty {
        Log.w("API Key 已清除，网络功能将不可用")
        // 如果当前是网络模式，自动切换到本地模式
        if recordingController.currentApiMode != .local {
            recordingController.userDidChangeApiMode(.local)
            statusBarController.setApiMode(.local)
            statusBarController.showNotification(
                title: "WhisperUtil",
                message: "API Key 已清除，已切换到本地识别模式"
            )
        }
        return
    }

    // 重建服务（仅在 idle 状态下安全重建）
    whisperService = ServiceCloudOpenAI(
        apiKey: newKey,
        model: config.whisperModel,
        language: settingsStore.whisperLanguage
    )
    realtimeService = ServiceRealtimeOpenAI(
        apiKey: newKey,
        language: settingsStore.whisperLanguage
    )
    textCleanupService = ServiceTextCleanup(apiKey: newKey)
    networkHealthMonitor = NetworkHealthMonitor(apiKey: newKey)

    // 重新注入到 RecordingController
    recordingController.updateServices(
        whisperService: whisperService,
        realtimeService: realtimeService,
        textCleanupService: textCleanupService
    )

    Log.i("API Key 已更新，服务已重建")
    statusBarController.showNotification(
        title: "WhisperUtil",
        message: "API Key 已更新"
    )
}
```

注意：`RecordingController` 需要新增 `updateServices()` 方法，允许在运行时替换服务实例。

### 4.6 修改 `RecordingController.swift`

新增方法允许动态替换服务：

```swift
/// 动态更新服务实例（API Key 变更时调用）
func updateServices(
    whisperService: ServiceCloudOpenAI,
    realtimeService: ServiceRealtimeOpenAI,
    textCleanupService: ServiceTextCleanup
) {
    guard currentState == .idle || currentState == .error else {
        Log.w("RecordingController: 当前状态 \(currentState) 不允许更新服务")
        return
    }
    self.whisperService = whisperService
    self.realtimeService = realtimeService
    self.textCleanupService = textCleanupService
}
```

### 4.7 修改 `UI/SettingsView.swift`

在 `Form` 的最顶部插入 API 密钥 Section（代码见 Part 3.5）。

### 4.8 各 Service 文件的修改

`ServiceCloudOpenAI.swift`、`ServiceRealtimeOpenAI.swift`、`ServiceTextCleanup.swift`、`NetworkHealthMonitor.swift` **无需修改**。它们已经通过构造函数注入 API Key，设计上与 Key 来源解耦。

### 4.9 迁移计划

为平滑过渡，支持以下迁移策略：

1. **新增 KeychainHelper.swift**，实现 Keychain 读写
2. **保留 EngineeringOptions.apiKey 作为过渡期 fallback**：

```swift
// Config.swift - 过渡期 load()
static func load() -> Config {
    // 优先从 Keychain 读取，fallback 到 EngineeringOptions（过渡期）
    let apiKey = KeychainHelper.load() ?? EngineeringOptions.apiKey

    // 如果 Keychain 为空但 EngineeringOptions 有值，自动迁移
    if KeychainHelper.load() == nil && !EngineeringOptions.apiKey.isEmpty
       && EngineeringOptions.apiKey != "YOUR_OPENAI_API_KEY_HERE" {
        KeychainHelper.save(apiKey: EngineeringOptions.apiKey)
        Log.i("配置: 已将 API Key 从源码迁移到 Keychain")
    }

    // ... 其余不变
}
```

3. **迁移完成后**：将 `EngineeringOptions.apiKey` 改为空字符串或删除
4. **更新 .gitignore 说明**：EngineeringOptions.swift 不再包含敏感信息，可考虑纳入版本控制

### 4.10 无 Key 时的行为

当未设置 API Key 时：

| 功能 | 行为 |
|------|------|
| 本地转写 (WhisperKit) | 正常工作，无需 API Key |
| 网络 API 转写 | 禁用，提示用户设置 API Key |
| 实时 API 转写 | 禁用，提示用户设置 API Key |
| 翻译 (两步法) | 禁用 |
| 文本优化 | 禁用，使用原始转录文本 |
| 设置面板 API 模式选项 | Cloud/Realtime 选项旁显示 "需要 API Key" 提示 |

在 `RecordingController.beginRecording()` 中增加检查：

```swift
func beginRecording(mode: RecordingMode) {
    // 检查 API Key（非本地模式需要）
    if currentApiMode != .local && (KeychainHelper.load() ?? "").isEmpty {
        onError?("请先在设置中配置 OpenAI API Key")
        return
    }
    // ... 现有逻辑
}
```

---

## Part 5: API Key 验证

### 5.1 轻量验证端点

推荐使用 `GET /v1/models`——这是 OpenAI 文档中最轻量的认证端点：

```swift
enum ApiKeyValidator {

    /// 验证 API Key 是否有效
    /// 使用 GET /v1/models 端点（只返回模型列表，不消耗 token）
    static func validate(apiKey: String) async -> SettingsStore.ApiKeyStatus {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            return .invalid("URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .invalid("无效响应")
            }

            switch httpResponse.statusCode {
            case 200:
                return .valid
            case 401:
                return .invalid("API Key 无效或已过期")
            case 403:
                return .invalid("API Key 权限不足")
            case 429:
                // 429 说明 Key 是有效的，只是速率受限
                return .valid
            default:
                return .invalid("验证失败 (HTTP \(httpResponse.statusCode))")
            }
        } catch {
            return .invalid("网络错误: \(error.localizedDescription)")
        }
    }
}
```

### 5.2 验证时机

| 时机 | 说明 |
|------|------|
| 保存时 | 用户在设置面板输入并保存 API Key 后**自动触发**验证 |
| 手动触发 | 用户点击"验证连接"按钮时 |
| 首次使用时 | 可选——在第一次调用 API 时检测 401 错误并提示 |
| **不推荐**定期验证 | 避免不必要的网络请求 |

### 5.3 错误处理策略

在 `ServiceCloudOpenAI` 和其他 Service 的响应处理中，增加对 401 状态码的特殊处理：

```swift
if httpResponse.statusCode == 401 {
    // API Key 无效——通知用户检查设置
    completion(.failure(WhisperError.apiError(401, "API Key 无效或已过期，请在设置中检查")))
    return
}
```

---

## Part 6: 安全最佳实践

### 6.1 日志安全

**当前风险**：`Log.d("Realtime: 请求头已设置 (Authorization + OpenAI-Beta)")` 这行没有泄露 Key，但需要确保未来修改中不会把 Key 打印到日志。

**规则**：
- 所有 `Log.i/d/e/w` 调用中**绝不**包含 API Key 原文
- 可以记录 Key 的遮盖版本（`*****kFJ2`）
- 在 `KeychainHelper.save()` 中不要打印 Key 值

### 6.2 崩溃报告

如果未来接入 Sentry / Crashlytics 等崩溃收集服务：
- 确保 `apiKey` 属性不会被序列化到崩溃上下文中
- 在发送前过滤包含 `Authorization` 或 `Bearer` 的 HTTP Header 日志

### 6.3 内存安全

对于 WhisperUtil 的威胁模型（个人桌面工具），内存中的明文 API Key 是可接受的风险。如需进一步加固：
- API Key 在 `String` 中以 UTF-8 明文存在，这是 Swift 的标准行为
- 可以考虑在不需要时将引用置 nil（但 Swift 的 ARC 不保证立即释放）
- 实际上，macOS 桌面应用中的内存攻击面极小，无需过度防护

### 6.4 开源准备

如果未来考虑开源 WhisperUtil：

1. **Git 历史清理**：`EngineeringOptions.swift` 当前包含明文 API Key。开源前需要：
   ```bash
   # 使用 git filter-repo 从所有历史中删除敏感文件
   git filter-repo --path Config/EngineeringOptions.swift --invert-paths
   ```
   或者使用 BFG Repo-Cleaner 替换特定字符串。

2. **模板文件**：已有 `EngineeringOptions.swift.template`，迁移到 Keychain 后该文件可以删除 apiKey 相关行。

3. **文档**：在 README 中说明用户需要在设置面板中输入自己的 API Key。

### 6.5 App Transport Security (ATS)

WhisperUtil 已经使用 HTTPS 连接 OpenAI API（`https://api.openai.com`），符合 ATS 要求。`Bearer` token 在 HTTPS 传输层加密，不存在中间人窃取风险。无需额外配置。

### 6.6 沙盒与 Keychain

如果 WhisperUtil 未来启用 App Sandbox（上架 Mac App Store 必须）：
- 沙盒应用自动获得自己的 Keychain 访问组，无需 Keychain Sharing entitlement
- 应用卸载后 Keychain 数据会被系统清除（沙盒行为）
- 非沙盒应用（当前状态）的 Keychain 数据在卸载后保留

---

## 实施优先级

| 优先级 | 任务 | 工作量 |
|--------|------|--------|
| P0 | 新增 `KeychainHelper.swift` | 小 |
| P0 | 修改 `Config.swift` 改为从 Keychain 读取（含迁移逻辑） | 小 |
| P0 | 修改 `SettingsStore.swift` 新增 API Key 管理属性 | 中 |
| P0 | 修改 `SettingsView.swift` 新增 API Key 输入 Section | 中 |
| P1 | 新增 `ApiKeyValidator.swift` 实现验证逻辑 | 小 |
| P1 | 修改 `AppDelegate.swift` 监听 Key 变更并重建 Services | 中 |
| P1 | 修改 `RecordingController.swift` 新增无 Key 检查 + `updateServices()` | 小 |
| P2 | 删除 `EngineeringOptions.swift` 中的 apiKey 字段 | 小 |
| P2 | 清理 git 历史中的敏感信息 | 小 |

总预估工作量：约 1-2 小时的代码变更。
