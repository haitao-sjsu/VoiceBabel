# WhisperKit 自动模型选择：基于硬件的最优模型推荐

> 调研日期：2026-03-26
> 目标：为 WhisperUtil 设计基于用户硬件的 Whisper 模型自动选择策略

---

## Part 1: WhisperKit 硬件要求

### 最低系统要求

| 要求项 | 最低版本 |
|--------|---------|
| macOS | 14.0 (Sonoma) |
| Xcode | 16.0 |
| 架构 | arm64 (Apple Silicon) |

### Apple Silicon 支持状态

WhisperKit 专为 Apple Silicon 设计，充分利用 CoreML 框架和 Neural Engine：

| 芯片系列 | 支持状态 | Neural Engine | 备注 |
|----------|---------|--------------|------|
| M1 | 完全支持 | 16 核 ANE | 基准参考平台 |
| M1 Pro/Max/Ultra | 完全支持 | 16 核 ANE | 更多 GPU 核心和内存带宽 |
| M2 | 完全支持 | 16 核 ANE | 性能提升约 15-20% |
| M2 Pro/Max/Ultra | 完全支持 | 16 核 ANE | 高端配置支持更大模型 |
| M3 | 完全支持 | 16 核 ANE | 动态缓存优化 |
| M3 Pro/Max/Ultra | 完全支持 | 16 核 ANE | 最佳性能配置 |
| M4 | 完全支持 | 16 核 ANE (38 TOPS) | 最新最快 |
| M4 Pro/Max | 完全支持 | 16 核 ANE | 顶级性能 |

### Intel Mac 支持

**WhisperKit 不支持 Intel Mac。** WhisperKit 依赖 CoreML 的 Neural Engine 加速，而 Intel Mac 没有 Neural Engine。虽然 CoreML 可以在 Intel Mac 上用 CPU/GPU 回退执行，但 WhisperKit 明确要求 arm64 架构（macOS 14+），因此 Intel Mac 完全排除在外。

> 如需在 Intel Mac 上运行本地 Whisper，替代方案是 whisper.cpp（通过 C++ 端口支持 x86_64）。

### CoreML 计算单元

CoreML 提供以下计算单元选项：

| 计算单元 | 枚举值 | 说明 |
|---------|--------|------|
| 全部 | `.all` | CPU + GPU + Neural Engine，默认且推荐 |
| CPU + Neural Engine | `.cpuAndNeuralEngine` | 跳过 GPU |
| CPU + GPU | `.cpuAndGPU` | 跳过 Neural Engine |
| 仅 CPU | `.cpuOnly` | 最慢，仅 CPU |

WhisperKit 默认使用 `.all`，CoreML 会自动将模型不同部分调度到最合适的硬件上。Neural Engine 执行 Transformer 核心计算，GPU 处理音频特征提取，CPU 负责预/后处理。

### 各模型内存需求（CoreML/ANE 推理）

| 模型 | 参数量 | 磁盘大小（CoreML） | 运行时内存（估算） |
|------|--------|-------------------|-------------------|
| tiny | 39M | ~80 MB | ~300 MB |
| base | 74M | ~150 MB | ~500 MB |
| small | 244M | ~500 MB | ~1.0 GB |
| medium | 769M | ~1.5 GB | ~2.5 GB |
| large-v2 | 1550M | ~3.1 GB | ~4.5 GB |
| large-v3 | 1550M | ~3.1 GB | ~4.5 GB |
| large-v3 (量化 626MB) | 1550M | ~626 MB | ~2.5 GB |
| large-v3 (量化 547MB) | 1550M | ~547 MB | ~2.0 GB |
| large-v3-turbo | ~809M | ~1.6 GB | ~3.0 GB |
| large-v3-turbo (量化 632MB) | ~809M | ~632 MB | ~2.0 GB |
| distil-large-v3 | 756M | ~1.5 GB | ~2.5 GB |
| distil-large-v3 (量化 594MB) | 756M | ~594 MB | ~2.0 GB |

> 注意：CoreML 在 ANE 上执行时内存使用通常远低于 PyTorch GPU 推理的 VRAM 需求。上表为实际 macOS 运行估算值。量化模型（混合精度 INT4/INT8）显著降低内存和磁盘占用。

---

## Part 2: 可用 Whisper 模型

### WhisperKit CoreML 模型完整列表

以下为 `argmaxinc/whisperkit-coreml` HuggingFace 仓库中所有可用模型：

#### 标准模型（未压缩 CoreML）

| 模型名称 | 原始参数量 | 语言 | 估算磁盘大小 |
|---------|-----------|------|-------------|
| `openai_whisper-tiny` | 39M | 多语言 | ~80 MB |
| `openai_whisper-tiny.en` | 39M | 仅英文 | ~80 MB |
| `openai_whisper-base` | 74M | 多语言 | ~150 MB |
| `openai_whisper-base.en` | 74M | 仅英文 | ~150 MB |
| `openai_whisper-small` | 244M | 多语言 | ~500 MB |
| `openai_whisper-small.en` | 244M | 仅英文 | ~500 MB |
| `openai_whisper-medium` | 769M | 多语言 | ~1.5 GB |
| `openai_whisper-medium.en` | 769M | 仅英文 | ~1.5 GB |
| `openai_whisper-large-v2` | 1550M | 多语言 | ~3.1 GB |
| `openai_whisper-large-v3` | 1550M | 多语言 | ~3.1 GB |
| `openai_whisper-large-v3-v20240930` | 1550M | 多语言 | ~3.1 GB |

#### Turbo 模型（编码器优化版，更快推理）

| 模型名称 | 备注 |
|---------|------|
| `openai_whisper-large-v2_turbo` | large-v2 的 ANE 优化版 |
| `openai_whisper-large-v3_turbo` | large-v3 的 ANE 优化版 |
| `openai_whisper-large-v3-v20240930_turbo` | 最新 large-v3 的 ANE 优化版 |

#### 量化压缩模型

| 模型名称 | 磁盘大小 | 压缩方式 |
|---------|---------|---------|
| `openai_whisper-small_216MB` | 216 MB | 混合精度量化 |
| `openai_whisper-small.en_217MB` | 217 MB | 混合精度量化 |
| `openai_whisper-large-v2_949MB` | 949 MB | 混合精度量化 |
| `openai_whisper-large-v2_turbo_955MB` | 955 MB | 混合精度量化 |
| `openai_whisper-large-v3_947MB` | 947 MB | 混合精度量化 |
| `openai_whisper-large-v3_turbo_954MB` | 954 MB | 混合精度量化 |
| `openai_whisper-large-v3-v20240930_547MB` | 547 MB | 混合精度量化（最高压缩比）|
| `openai_whisper-large-v3-v20240930_626MB` | 626 MB | 混合精度量化 |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | 632 MB | 混合精度量化 + Turbo |

#### Distil-Whisper 模型（蒸馏版）

| 模型名称 | 磁盘大小 | 备注 |
|---------|---------|------|
| `distil-whisper_distil-large-v3` | ~1.5 GB | 蒸馏版，2 层解码器 |
| `distil-whisper_distil-large-v3_turbo` | ~1.5 GB | 蒸馏版 + ANE 优化 |
| `distil-whisper_distil-large-v3_594MB` | 594 MB | 蒸馏版 + 量化 |
| `distil-whisper_distil-large-v3_turbo_600MB` | 600 MB | 蒸馏版 + 量化 + Turbo |

### 模型性能对比

| 模型 | WER（英文） | WER（中文估算）| RTF（M1）| RTF（M4）| 适用场景 |
|------|-----------|-------------|---------|---------|---------|
| tiny | ~7.7% | ~25%+ | ~0.05x | ~0.02x | 极速草稿、低端设备 |
| base | ~5.9% | ~18%+ | ~0.08x | ~0.03x | 快速转录、一般用途 |
| small | ~4.3% | ~12% | ~0.15x | ~0.06x | 良好平衡点 |
| medium | ~3.5% | ~8% | ~0.3x | ~0.12x | 高质量通用转录 |
| large-v3 | ~2.5% | ~5% | ~0.8x | ~0.3x | 最高精度 |
| large-v3 (626MB) | ~2.8% | ~6% | ~0.5x | ~0.2x | 高精度 + 低磁盘 |
| large-v3-turbo | ~2.7% | ~5.5% | ~0.4x | ~0.15x | 高精度 + 快速 |
| distil-large-v3 | ~3.0% | ~7% | ~0.25x | ~0.1x | 快速 + 较高精度 |

> RTF (Real-Time Factor) 越低越快。RTF < 1.0 表示比实时快。例如 RTF=0.3x 表示 1 分钟音频只需 0.3 分钟处理。
> 中文 WER 为估算值，实际取决于口音、领域和音频质量。

### 实用性评估

对于 WhisperUtil（macOS 菜单栏工具，短音频片段）的实用模型：

- **最佳性价比**：`openai_whisper-large-v3-v20240930_626MB`（当前默认，精度高、磁盘占用合理）
- **极致精度**：`openai_whisper-large-v3-v20240930_turbo_632MB`（Turbo 版本更快）
- **内存受限 (8GB RAM)**：`openai_whisper-small_216MB` 或 `distil-whisper_distil-large-v3_594MB`
- **极速需求**：`openai_whisper-tiny` 或 `openai_whisper-base`

---

## Part 3: macOS 硬件检测方法

### 3.1 检测总内存 (RAM)

```swift
import Foundation

let totalRAM = ProcessInfo.processInfo.physicalMemory
let totalRAMGB = Double(totalRAM) / 1_073_741_824.0  // bytes → GB
print("Total RAM: \(String(format: "%.1f", totalRAMGB)) GB")
// 例：8.0 GB / 16.0 GB / 24.0 GB / 32.0 GB / 64.0 GB / 96.0 GB / 128.0 GB / 192.0 GB
```

### 3.2 检测 Apple Silicon vs Intel

```swift
import Foundation

/// 检测是否为 Apple Silicon（arm64 架构）
var isAppleSilicon: Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}

/// 运行时检测（考虑 Rosetta 情况）
func machineArchitecture() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
        }
    }
    return machine  // "arm64" 或 "x86_64"
}
```

### 3.3 获取具体芯片型号

```swift
import Foundation

/// 通过 sysctl 获取硬件型号标识符（如 "Mac14,2"）
func hardwareModelIdentifier() -> String {
    var size: Int = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}

/// 实用方法：获取 CPU 品牌字符串
func cpuBrandString() -> String {
    var size: Int = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var brand = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
    return String(cString: brand)
    // Apple Silicon: "Apple M2 Pro"
    // Intel: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"
}
```

### 3.4 获取 CPU 核心数

```swift
/// 性能核心数
func performanceCoreCount() -> Int {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0)
    return Int(count)
}

/// 能效核心数
func efficiencyCoreCount() -> Int {
    var count: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("hw.perflevel1.physicalcpu", &count, &size, nil, 0)
    return Int(count)
}

/// 总逻辑 CPU 数
let cpuCount = ProcessInfo.processInfo.processorCount
let activeCPU = ProcessInfo.processInfo.activeProcessorCount
```

### 3.5 Neural Engine 可用性检测

Neural Engine 无法直接通过 API 查询核心数，但可通过以下方式间接判断：

```swift
import CoreML

/// 检测 Neural Engine 是否可用
/// 所有 Apple Silicon Mac 都有 ANE，Intel Mac 没有
func isNeuralEngineAvailable() -> Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}

/// Neural Engine TOPS（万亿次运算/秒）参考值：
/// M1: 11 TOPS, M2: 15.8 TOPS, M3: 18 TOPS, M4: 38 TOPS
```

### 3.6 GPU 核心数检测

```swift
import Metal

func gpuInfo() -> String? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    return device.name  // 例 "Apple M2 Pro"
    // GPU 核心数需要通过型号映射表获取：
    // M1: 7-8 核, M1 Pro: 14-16, M1 Max: 24-32, M1 Ultra: 48-64
    // M2: 8-10, M2 Pro: 16-19, M2 Max: 30-38, M2 Ultra: 60-76
    // M3: 8-10, M3 Pro: 14-18, M3 Max: 30-40, M3 Ultra: 60-80
    // M4: 10, M4 Pro: 16-20, M4 Max: 32-40
}
```

### 3.7 综合硬件信息获取（推荐实现）

```swift
struct DeviceInfo {
    let totalRAMGB: Double
    let isAppleSilicon: Bool
    let cpuBrand: String        // "Apple M2 Pro"
    let modelIdentifier: String  // "Mac14,12"
    let processorCount: Int
    let architecture: String     // "arm64" / "x86_64"

    static func current() -> DeviceInfo {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0

        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)

        size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)

        var systemInfo = utsname()
        uname(&systemInfo)
        let arch = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        return DeviceInfo(
            totalRAMGB: ram,
            isAppleSilicon: arch == "arm64",
            cpuBrand: String(cString: brand),
            modelIdentifier: String(cString: model),
            processorCount: ProcessInfo.processInfo.processorCount,
            architecture: arch
        )
    }
}
```

---

## Part 4: 自动模型选择策略

### 4.1 基于 RAM 的选择策略

RAM 是最关键的约束因素。macOS 系统本身占用约 3-4 GB，加上 WhisperUtil 和其他应用，可用内存有限。

| 总 RAM | 可用于模型（估算） | 推荐模型 | 备选 |
|--------|-------------------|---------|------|
| 8 GB | ~2-3 GB | `openai_whisper-small_216MB` | `distil-whisper_distil-large-v3_594MB` |
| 16 GB | ~6-8 GB | `openai_whisper-large-v3-v20240930_626MB` | `openai_whisper-large-v3-v20240930_turbo_632MB` |
| 24 GB | ~10-12 GB | `openai_whisper-large-v3-v20240930_turbo_632MB` | `openai_whisper-large-v3` (未量化) |
| 32 GB+ | ~14+ GB | `openai_whisper-large-v3-v20240930_turbo_632MB` | `openai_whisper-large-v3` (未量化) |
| 64 GB+ | 充裕 | `openai_whisper-large-v3-v20240930_turbo_632MB` | 同上 |

### 4.2 基于芯片的细分策略

```
if !isAppleSilicon {
    → 不支持本地模式，提示用户使用 Cloud 模式
}

// Apple Silicon 设备按芯片等级细分
M1 基础款 (8GB):
    → small_216MB（安全选择）
    → distil-large-v3_594MB（激进选择，可能内存紧张）

M1 Pro/Max (16-64GB):
    → large-v3-v20240930_626MB（默认）
    → large-v3-v20240930_turbo_632MB（更快）

M2 及以上 (8GB):
    → small_216MB 或 distil-large-v3_594MB

M2 及以上 (16GB+):
    → large-v3-v20240930_turbo_632MB（充分利用更快的 ANE）

M3/M4 (16GB+):
    → large-v3-v20240930_turbo_632MB（ANE 性能最强）
```

### 4.3 考虑首次下载 vs 运行时内存

| 因素 | 权重 | 说明 |
|------|------|------|
| 运行时内存 | 最高 | 直接决定模型能否加载 |
| 下载大小 | 中等 | 影响首次体验，但只需下载一次 |
| 磁盘空间 | 较低 | Mac 通常有足够存储 |
| 推理速度 | 中等 | 影响用户体验流畅度 |

### 4.4 推荐算法

```swift
func recommendedModel(for device: DeviceInfo) -> String {
    guard device.isAppleSilicon else {
        // Intel Mac 不支持 WhisperKit
        return ""
    }

    let ramGB = device.totalRAMGB

    if ramGB >= 16 {
        // 16GB+ → 量化 large-v3 turbo（最佳精度速度平衡）
        return "openai_whisper-large-v3-v20240930_turbo_632MB"
    } else if ramGB >= 12 {
        // 12GB → 量化 large-v3（精度优先）
        return "openai_whisper-large-v3-v20240930_626MB"
    } else if ramGB >= 8 {
        // 8GB → distil 或 small
        // distil-large-v3 精度更好但内存稍高
        // small 更安全
        return "openai_whisper-small_216MB"
    } else {
        // < 8GB（理论上 Apple Silicon Mac 最低 8GB，此分支不应到达）
        return "openai_whisper-tiny"
    }
}
```

### 4.5 用户覆盖

应允许用户手动覆盖自动选择：

```
设置界面：
  本地模型: [自动推荐 ▾]
             ├─ 自动推荐（根据设备）     ← 默认
             ├─ tiny (~80MB, 最快)
             ├─ small (~216MB, 平衡)
             ├─ large-v3 (~626MB, 最准)
             └─ large-v3 turbo (~632MB, 快+准)
```

---

## Part 5: WhisperKit 内置设备支持

### 5.1 `modelSupport(for:)` API

WhisperKit 内置了设备级模型推荐系统：

```swift
// WhisperKit 源码中的核心 API
public func modelSupport(for deviceIdentifier: String = WhisperKit.deviceName()) -> ModelSupport

// ModelSupport 结构体
struct ModelSupport {
    let `default`: String     // 该设备的默认推荐模型
    let supported: [String]   // 该设备支持的所有模型列表
}

// DeviceSupport 结构体
struct DeviceSupport {
    let identifiers: [String]  // 设备标识符列表（如 ["Mac14,2", "Mac14,3"]）
    let chipName: String       // 芯片名称
    let modelSupport: ModelSupport
}
```

**工作原理**：使用设备标识符（如 `Mac14,2`）进行最长前缀匹配，找到最具体的硬件配置，返回该设备的推荐模型。

**使用方式**：

```swift
// 方式 1：不指定模型，WhisperKit 自动选择
let kit = try await WhisperKit(WhisperKitConfig())
// WhisperKit 内部调用 modelSupport() 获取默认模型

// 方式 2：获取推荐后让用户确认
let support = whisperKit.modelSupport()
print("推荐模型: \(support.default)")
print("支持模型: \(support.supported)")
```

### 5.2 模型仓库与自动下载

WhisperKit 的模型分发流程：

1. **模型仓库**：`argmaxinc/whisperkit-coreml`（HuggingFace Hub）
2. **自动下载**：`WhisperKitConfig(download: true)` 时自动从 HuggingFace 下载
3. **缓存位置**：`~/.cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/`
4. **后台下载**：支持 `useBackgroundDownloadSession: true`

### 5.3 模型缓存与存储

```
~/.cache/huggingface/hub/
  └── models--argmaxinc--whisperkit-coreml/
      ├── refs/
      ├── snapshots/
      │   └── <commit-hash>/
      │       ├── openai_whisper-large-v3-v20240930_626MB/
      │       │   ├── AudioEncoder.mlmodelc/
      │       │   ├── TextDecoder.mlmodelc/
      │       │   ├── MelSpectrogram.mlmodelc/
      │       │   └── ...
      │       └── openai_whisper-small_216MB/
      │           └── ...
      └── .locks/
```

### 5.4 多模型共存

**支持**。可以下载多个模型到本地缓存，切换时无需重新下载：

```swift
// 模型 A 已缓存，切换到模型 B
let configB = WhisperKitConfig(model: "openai_whisper-small_216MB", download: true)
let kitB = try await WhisperKit(configB)
// 如果 small 已缓存则直接加载，否则下载

// 内存压力时的回退策略
// WhisperKit 本身不自动回退，但应用层可以实现：
do {
    let kit = try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_626MB"))
} catch {
    // 加载失败（可能内存不足），回退到更小模型
    let kit = try await WhisperKit(WhisperKitConfig(model: "openai_whisper-small_216MB"))
}
```

---

## Part 6: WhisperUtil 实用建议

### 6.1 默认模型选择表

| 设备配置 | 默认模型 | 下载大小 | 预期 WER（中文）|
|---------|---------|---------|---------------|
| Apple Silicon, 8GB RAM | `openai_whisper-small_216MB` | 216 MB | ~12% |
| Apple Silicon, 16GB RAM | `openai_whisper-large-v3-v20240930_turbo_632MB` | 632 MB | ~5.5% |
| Apple Silicon, 24GB+ RAM | `openai_whisper-large-v3-v20240930_turbo_632MB` | 632 MB | ~5.5% |
| Intel Mac | 不支持本地模式 | — | — |

### 6.2 实现方案：WhisperKit 内置推荐 + 自定义覆盖

**推荐方案**：优先使用 WhisperKit 的 `modelSupport(for:)` API，因为 Argmax 团队会持续更新设备-模型映射关系。仅在需要更细致控制时使用自定义逻辑。

```swift
// 推荐实现
func selectModel() -> String {
    // 1. 用户手动指定 → 最高优先级
    if let userOverride = SettingsStore.shared.localModelOverride,
       !userOverride.isEmpty {
        return userOverride
    }

    // 2. 使用 WhisperKit 内置推荐
    // WhisperKitConfig(model: nil) → 自动使用 modelSupport() 推荐
    // 但我们可能需要预先知道模型名以显示 UI

    // 3. 自定义补充逻辑（基于 RAM 的额外约束）
    let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    if ramGB < 12 {
        return "openai_whisper-small_216MB"
    } else {
        return "openai_whisper-large-v3-v20240930_turbo_632MB"
    }
}
```

### 6.3 用户设置界面

建议在设置面板中添加：

```
本地模型设置:
  ┌──────────────────────────────────────────┐
  │ 模型选择: [自动 (推荐) ▾]                    │
  │                                          │
  │ 当前模型: large-v3 turbo (632MB)           │
  │ 状态: ✓ 已下载                              │
  │ 设备: Apple M2 Pro, 16GB RAM               │
  │                                          │
  │ [手动选择模型...]                            │
  └──────────────────────────────────────────┘
```

手动选择时显示每个模型的简要描述（大小、精度级别、推荐内存），并标记当前设备是否适合。

### 6.4 下载 UX

1. **首次下载**：显示进度条和预估时间
2. **空间检查**：下载前检查可用磁盘空间（`FileManager.default.attributesOfFileSystem`）
3. **后台下载**：使用 `useBackgroundDownloadSession: true`
4. **暂停/恢复**：HuggingFace Hub 支持断点续传
5. **多模型管理**：提供 "管理已下载模型" 入口，可删除不用的模型释放空间

```swift
// 磁盘空间检查示例
func hasEnoughDiskSpace(requiredMB: Int) -> Bool {
    let homeURL = FileManager.default.homeDirectoryForCurrentUser
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: homeURL.path),
       let freeSize = attrs[.systemFreeSize] as? Int64 {
        let freeMB = freeSize / (1024 * 1024)
        return freeMB > Int64(requiredMB) + 500  // 预留 500MB 余量
    }
    return false
}
```

### 6.5 回退策略

```
加载模型失败时的回退链：

1. 尝试加载用户选择/自动推荐的模型
   ↓ 失败（内存不足 / 文件损坏）
2. 回退到更小的模型（large→small→base→tiny）
   ↓ 全部失败
3. 提示用户切换到 Cloud 模式
4. 如果网络不可用，显示错误信息

实现：
func loadModelWithFallback() async {
    let fallbackChain = [
        selectModel(),                           // 推荐模型
        "openai_whisper-small_216MB",             // 回退 1
        "openai_whisper-base",                    // 回退 2
        "openai_whisper-tiny"                     // 回退 3
    ]

    for model in fallbackChain {
        do {
            let config = WhisperKitConfig(model: model, download: true)
            self.whisperKit = try await WhisperKit(config)
            self.currentModel = model
            Log.i("模型加载成功: \(model)")
            return
        } catch {
            Log.w("模型 \(model) 加载失败: \(error), 尝试下一个...")
        }
    }

    Log.e("所有本地模型加载失败，建议切换到 Cloud 模式")
    // 触发 UI 提示
}
```

### 6.6 当前代码需要修改的地方

当前 WhisperUtil 在 `EngineeringOptions` 中硬编码了模型名称：

```swift
// Config/EngineeringOptions.swift:112
static let localWhisperModel = "openai_whisper-large-v3-v20240930_626MB"
```

建议改为动态选择：

1. 在 `SettingsStore` 中添加 `localWhisperModel` 属性（持久化到 UserDefaults）
2. 添加 `localWhisperModelAutoSelect` 布尔开关（默认 true）
3. 在 `AppDelegate` 初始化时，如果 autoSelect=true，调用 `selectModel()` 更新设置
4. `ServiceLocalWhisper.loadModel()` 从 `SettingsStore` 读取模型名称
5. 模型变更时需要重新加载 WhisperKit 实例

---

## 总结

| 要点 | 结论 |
|------|------|
| 是否需要自动选择？ | 是，8GB Mac 使用 large-v3 会导致内存压力 |
| 最佳实现方式 | RAM 阈值判断 + WhisperKit modelSupport() 辅助 |
| 8GB 推荐 | `openai_whisper-small_216MB` (216MB 下载, ~1GB 运行内存) |
| 16GB+ 推荐 | `openai_whisper-large-v3-v20240930_turbo_632MB` (632MB 下载, ~2GB 运行内存) |
| Intel 支持 | 不支持，自动引导到 Cloud 模式 |
| 用户覆盖 | 必须支持，高级用户可能有特殊需求 |
| 回退策略 | large→small→base→tiny→Cloud 模式 |
| WhisperKit 内置支持 | 有 `modelSupport(for:)` API，可利用 |
