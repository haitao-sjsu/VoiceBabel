# 条件编译 `#if canImport(Translation)` 的替代方案

## 背景

WhisperUtil 目前使用 `#if canImport(Translation)` + `@available(macOS 15.0, *)` 双层护栏来隔离 Apple Translation Framework（macOS 15+ 才可用）。用户的顾虑：

1. 担心发布时需要针对 macOS 14 和 macOS 15+ 分别打两个二进制包，运维麻烦。
2. 代码里散布的 `#if` 块丑陋，影响阅读。

本文解答这两个顾虑，给出替代方案与推荐路线。

## 现状盘点

项目里 `#if canImport(Translation)` 出现在 5 个文件，共约 13 处：

| 文件 | 处数 | 用途 |
|------|------|------|
| `Services/LocalAppleTranslationService.swift` | 2 | 整个文件类型包在 `#if` 里；两处 `@available(macOS 15.0, *)` |
| `AppDelegate.swift` | 2 | 实例化 + 注入到 AppController |
| `Core/AppController.swift` | 3 | 保存 service 引用 + setter |
| `Core/TranslationManager.swift` | 4 | 引擎分派（apple 路径）+ 可用性判断 |
| `WhisperUtilTests/LocalAppleTranslationServiceTests.swift` | 1 | 测试文件 |

## A. 先澄清两个事实

### A.1 一个二进制就够用，不需要分平台发版

Swift 的链接模型：

- **SDK** 决定编译期能看到哪些符号（类型、函数）。
- **Deployment Target** 决定二进制支持的最低 macOS 版本。
- 当 deployment target（macOS 14.0）低于某框架引入版本（Translation.framework 只在 14.4+）时，Xcode **自动弱链接**（weak link）该框架。

弱链接的意义：在老系统（macOS 14）上，弱链接符号解析为 NULL，只要运行时不执行到它们就不会崩溃。`@available(macOS 15.0, *)` 就是编译器层面的强制守卫 —— 你不加这个护栏编译器直接报错，加了之后运行时进不了那段代码。

**结论：Xcode 17 + SDK 15 + deployment target 14.0 + `@available` 守卫 = 一个二进制跑遍 macOS 14 / 15 / 16+。**

### A.2 `#if canImport(Translation)` 在当前项目里是死代码

`canImport(X)` 是**编译期**检查：当前 SDK 里能不能 `import X`。

- Xcode 17 自带 macOS 15+ SDK → `canImport(Translation)` 永远为 true
- 除非有人拿 Xcode 15（macOS 14 SDK）来编译，才会为 false

本项目已经钉死在 Xcode 17 / SDK 15+，所以 `#if canImport(Translation)` 的 else 分支永远不会被编译到。**它只是安慰剂，没有实际保护作用。**

`#if canImport(...)` 这种模式的真正用途是**跨平台**代码（比如 iOS + Linux 共享一份 Swift 文件时守卫 `UIKit`），不是用来做同平台的 OS 版本门禁。

## B. 替代方案

### 方案 1：直接删除 `#if canImport`，只留 `@available`（最小改动）

```swift
import Translation   // 无条件导入；框架自动弱链接

@available(macOS 15.0, *)
final class LocalAppleTranslationService {
    // ...
}
```

调用点：

```swift
if #available(macOS 15.0, *) {
    let service = LocalAppleTranslationService()
    // use
}
```

- 零改动成本，纯删除 `#if` 和对应 `#endif`。
- 二进制大小不变（弱链接结果同现状）。
- macOS 14 上仍然安全：`@available` 守卫保证相关代码不会执行。

### 方案 2：协议抽象 + 工厂（最优雅，架构受益）

```swift
// 对所有版本都可见的协议
protocol LocalTranslator {
    func translate(text: String, sourceLanguage: String?, targetLanguage: String) async throws -> String
}

// 仅 macOS 15+ 的实现
@available(macOS 15.0, *)
final class AppleTranslator: LocalTranslator {
    // 现 LocalAppleTranslationService 的内容
}

// 工厂集中收敛版本判断
enum LocalTranslatorFactory {
    static func make() -> LocalTranslator? {
        if #available(macOS 15.0, *) { return AppleTranslator() }
        return nil
    }
}
```

使用方（TranslationManager / AppController）永远只接触 `LocalTranslator?`：

```swift
class TranslationManager {
    let localTranslator: LocalTranslator?  // 不再看到 Any?、不再 if canImport

    init(cloudOpenAIService: CloudOpenAIService, localTranslator: LocalTranslator?) {
        self.cloudOpenAIService = cloudOpenAIService
        self.localTranslator = localTranslator
    }

    private func isEngineAvailable(_ engine: String) -> Bool {
        switch engine {
        case "cloud": return !(KeychainHelper.load() ?? "").isEmpty
        case "apple": return localTranslator != nil
        default: return false
        }
    }
}
```

收益：
- `TranslationManager`、`AppController`、`AppDelegate` 彻底摆脱 `#if`，也摆脱当前的 `Any?` 类型擦除。
- 版本判断收敛到一个工厂，符合"单一决策点"原则。
- Mock 测试容易：提供 `MockLocalTranslator` 就能覆盖翻译路径。

### 方案 3：`if #available` 就地分派（无新抽象）

对于只有几个调用点的情况：

```swift
func translate(text: String) async throws -> TranslationResult {
    if #available(macOS 15.0, *) {
        return try await runAppleThenCloud(text: text)
    } else {
        return try await runCloudOnly(text: text)
    }
}
```

比 `@available` 更灵活 —— 可以在同一函数里写两条路径，而 `@available` 只能整体屏蔽声明。

### 方案 4（不推荐）：`dlsym` 运行时解析

C 系的 `dlopen` + `dlsym` 理论上能避开 import。但 Swift 的泛型、async、类型系统让这条路在 Swift 类上几乎无法实践。对 WhisperUtil 无价值。

## C. 取舍对比

| 方案 | 代码整洁度 | 二进制大小 | 崩溃安全性 | 开发体验 | 可测试性 |
|------|------------|------------|------------|----------|----------|
| 当前（`#if canImport` + `@available`） | 低（噪音大） | 相同 | 安全 | 散落 | 一般（`Any?` 擦除） |
| 1. 删 `#if`，留 `@available` | 中 | 相同 | 安全 | 简单 | 一般 |
| 2. 协议 + 工厂 | **高** | 相同 | 安全 | **最佳**（单一决策点） | **最佳**（易 mock） |
| 3. `if #available` 就地 | 高 | 相同 | 安全 | 简单调用点好 | 一般 |
| 4. `dlsym` | 低 | 相同 | 脆弱 | 差 | 差 |

## D. 推荐路线

**阶段 1（立即可做，低成本）：方案 1 — 删除所有 `#if canImport(Translation)`。**

理由：
- 该守卫在当前 Xcode 17 生态下是死代码，移除没有回归风险。
- 纯机械删除，不触碰任何逻辑。
- 一个二进制跨 macOS 14/15+ 的结论本来就成立，这步只是把冗余代码清掉。

影响范围（5 个文件的 13 处）：
- `Services/LocalAppleTranslationService.swift` — 删外层 `#if` / `#endif`
- `AppDelegate.swift` — 删两处 `#if` 包裹
- `Core/AppController.swift` — 删三处 `#if` 包裹（同时把 `private var localAppleTranslationService: Any?` 恢复为正常类型）
- `Core/TranslationManager.swift` — 删四处 `#if` 包裹（同理，`var localAppleTranslationService: Any?` 可改为 `LocalAppleTranslationService?`）
- `WhisperUtilTests/LocalAppleTranslationServiceTests.swift` — 删一处

**阶段 2（后续优化，非必需）：方案 2 — 引入 `LocalTranslator` 协议。**

触发时机：
- 未来要增加第二个本地翻译后端（比如社区贡献的开源本地翻译模型）
- 或者想把 `TranslationManager` 里的 `Any?` 类型擦除彻底消除

此时引入协议能让 `TranslationManager` 更干净，版本判断从 manager 下沉到工厂。

## E. 执行要点（阶段 1）

1. **保留**：
   - `@available(macOS 15.0, *)` 所有标注 —— 这是运行时安全的唯一保障，绝对不能删。
   - `import Translation` —— 改为无条件 import。
   - 弱链接由 Xcode 自动处理，不需要改 project.pbxproj。
2. **删除**：
   - 所有 `#if canImport(Translation)` / `#endif` 成对。
3. **简化类型**：
   - `AppController.localAppleTranslationService: Any?` → 可以直接保留 `Any?`（因为 `@available` 限制），或进一步改为在引用点加 `@available` 标注的可选类型 `LocalAppleTranslationService?` 配合 `@available(macOS 15.0, *)` 属性标注（Swift 允许 `@available` 标注存储属性）。

4. **验证**：
   - `make build` 必须一次通过
   - `make dev` 启动后日志应有 `Apple 翻译服务已初始化`（macOS 15+）或不出现（macOS 14）
   - 对方案 1，建议在 CI 上加一个 `--deployment-target 14.0` 的构建测试，确认不出现 `@available` 泄漏

## F. 与 "Services/CLAUDE.md" 规则的一致性

项目已有规则"**No dead code. Unused methods attract copy-paste reuse of their bad patterns.**"

`#if canImport(Translation)` 的 else 分支永不触发，正好符合"死代码"的定义。删除它既是清理技术债，也是对这条规则的贯彻。

## 参考

- Apple Developer: [Using weak linking to target multiple OS versions](https://developer.apple.com/documentation/swift/availability_condition)
- WWDC24 "Meet the Translation API" — Apple 官方 sample 不使用 `#if canImport`，仅用 `@available` + `if #available`
- Swift Evolution SE-0141 Availability by Swift version — `@available` 与 `if #available` 的语义差异
