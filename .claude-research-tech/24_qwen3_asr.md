# Qwen3-ASR 语音识别模型调研

> 调研日期：2026-04-14
> 调研目的：评估 Qwen3-ASR 在 WhisperUtil 项目中替代/补充 WhisperKit 的可行性，重点关注中英文混合转写（code-switching）和 Apple Silicon 端侧部署

---

## 核心结论（先说重点）

**Qwen3-ASR 是目前中英文混合转写的最佳开源本地方案。** 它在中文 ASR 准确率上大幅领先 Whisper large-v3（WenetSpeech WER: 4.97% vs 9.86%），英语也略优（GigaSpeech WER: 8.45% vs 9.76%），支持 52 种语言/方言（含 22 种中文方言），且已有成熟的 Swift 实现（speech-swift）可通过 SPM 集成。

**但集成工作量不小。** speech-swift 使用 MLX 推理（非 CoreML/ANE），0.6B 模型在 Apple Silicon 上的 RTF 约 0.15-0.27（3.7-6.3x 实时），远慢于 WhisperKit 通过 ANE 运行的速度。内存占用约 1.2GB（0.6B 模型），也高于 WhisperKit 在 ANE 上的表现。目前没有 CoreML/ANE 优化版本。

**推荐策略：中期引入。** 当前 WhisperKit + gpt-4o-transcribe 组合仍然可用。等 speech-swift 进一步成熟、或出现 CoreML 转换方案后，Qwen3-ASR 将是替换 WhisperKit 本地模式的首选。

---

## 第一部分：Qwen3-ASR 概述

### 1.1 产品定位

Qwen3-ASR 是阿里云通义团队（Qwen Team）于 2026 年 1 月 29 日发布的开源 ASR 模型系列，属于 Qwen3 语音生态的一部分（同期还有 Qwen3-TTS、Qwen3-Omni 等）。定位为"all-in-one"语音识别模型，集成语言识别 + ASR + 时间戳对齐。

### 1.2 模型家族

| 模型 | 参数量 | 编码器参数 | 编码器隐藏层 | 磁盘大小 | 用途 |
|------|--------|-----------|------------|---------|------|
| Qwen3-ASR-1.7B | 1.7B | 300M | 1024 | ~4.7 GB (BF16) | 旗舰 ASR |
| Qwen3-ASR-0.6B | ~0.9B | 180M | 896 | ~1.9 GB (BF16) | 高效 ASR，端侧部署首选 |
| Qwen3-ForcedAligner-0.6B | 0.6B | - | - | - | 时间戳对齐（11种语言） |

注：0.6B 的命名指 LLM 解码器部分的参数量，加上编码器后总参数约 0.9B。

### 1.3 架构详解

**LALM（Large Audio-Language Model）范式：**

```
音频 → 128维Fbank → Conv2D (8x下采样) → AuT编码器 → 投影层 → Qwen3 LLM解码器 → 文本
```

这是一个 **编码器-解码器（Encoder-Decoder）** 架构，与 Whisper 的架构类型相同，但有关键区别：

- **编码器**：AuT（Audio Transformer），非 Conformer。使用 Conv2D 做 8 倍下采样，产出 12.5Hz token 率（每秒音频压缩为 12.5 个 token）
- **注意力机制**：动态 Flash Attention，窗口大小 1-8 秒，支持流式和离线统一推理
- **RoPE**：交错多维 RoPE（Interleaved Multi-dimensional RoPE），sections [24, 20, 20]，跨时间和空间维度
- **解码器**：Qwen3 LLM（0.6B 或 1.7B），自回归生成文本
- **投影层**：线性投影，将音频特征映射到 LLM 嵌入空间

**与 Whisper 的架构对比：**

| 维度 | Qwen3-ASR | Whisper |
|------|-----------|---------|
| 范式 | LALM（音频-语言模型） | 传统 Encoder-Decoder |
| 编码器 | AuT (Audio Transformer) | Transformer |
| 解码器 | Qwen3 LLM | Transformer Decoder |
| 下采样 | Conv2D 8x | Conv1D 2x |
| Token 率 | 12.5 Hz | 50 Hz |
| 注意力 | 动态窗口 Flash Attention | 全局注意力 |
| 预训练数据 | ~4000万小时伪标签 | ~68万小时监督 |
| 流式支持 | 原生（动态窗口） | 不原生（需分段） |

### 1.4 训练数据

- **AuT 编码器预训练**：约 4000 万小时伪标签 ASR 数据，以中英文为主
- **整体预训练**：3 万亿 token
- **ASR SFT**：多语言数据 + 流式数据 + 上下文偏置数据（与预训练数据不重叠）
- **RL 阶段**：约 5 万条语音（35% 中英文 + 35% 多语言 + 30% 功能性数据）

### 1.5 许可证

**Apache 2.0** -- 完全开源，商用无限制。

---

## 第二部分：多语种混杂（Code-Switching）能力

### 2.1 支持的语言

**30 种语言**：中文 (zh)、英语 (en)、粤语 (yue)、阿拉伯语 (ar)、德语 (de)、法语 (fr)、西班牙语 (es)、葡萄牙语 (pt)、印尼语 (id)、意大利语 (it)、韩语 (ko)、俄语 (ru)、泰语 (th)、越南语 (vi)、日语 (ja)、土耳其语 (tr)、印地语 (hi)、马来语 (ms)、荷兰语 (nl)、瑞典语 (sv)、丹麦语 (da)、芬兰语 (fi)、波兰语 (pl)、捷克语 (cs)、菲律宾语 (fil)、波斯语 (fa)、希腊语 (el)、匈牙利语 (hu)、马其顿语 (mk)、罗马尼亚语 (ro)

**22 种中文方言**：安徽、东北、福建、甘肃、贵州、河北、河南、湖北、湖南、江西、宁夏、山东、陕西、山西、四川、天津、云南、浙江、粤语（港/粤）、吴语、闽南语

### 2.2 Code-Switching 能力评估

**官方技术报告中没有专门的 code-switching 基准测试。** 这是一个遗憾的发现。Qwen3-ASR 的技术报告（arXiv 2601.21337）只对单语言分别评测，没有提供中英混杂、日英混杂等语言对的专项 CER/WER 数据。

**但有间接证据表明 code-switching 能力较强：**

1. **语言识别准确率 97.9%**（30 种语言平均），显著高于 Whisper large-v3 的 94.1%。高精度的语言检测是 code-switching 的前提
2. **支持单段音频内的语言切换**：官方描述明确支持"在单个音频文件中检测语言切换并用对应语言模型转写"
3. **训练数据以中英文为主**（4000 万小时中大部分为中英文），中英混合场景应有较好覆盖
4. **LALM 架构优势**：以 LLM 作为解码器，具备跨语言上下文理解能力，天然适合处理语言混合
5. **22 种中文方言支持**：能处理方言-普通话-英语的复杂混合场景

**与 Whisper 的 code-switching 对比（推测性评估）：**

| 维度 | Qwen3-ASR | Whisper large-v3 |
|------|-----------|------------------|
| 语言识别精度 | 97.9% | 94.1% |
| 中文方言支持 | 22 种 | 有限 |
| 架构适合度 | LALM + 高精度语言检测 | 传统 Enc-Dec |
| 中英混杂评测数据 | 无公开基准 | 无公开基准 |
| 社区反馈 | 中英混合表现良好 | 中英混合一般 |

**结论**：虽然缺乏正式的 code-switching 基准测试，但从架构设计、语言识别精度和训练数据组成来看，Qwen3-ASR 在中英混合场景的表现应显著优于 Whisper。这也与 Parakeet 调研中的结论一致。

### 2.3 各语言 WER/CER 基准测试

#### 英语

| 数据集 | Qwen3-ASR-1.7B | Qwen3-ASR-0.6B | Whisper-large-v3 | GPT-4o | Gemini-2.5-Pro |
|--------|---------------|----------------|-----------------|--------|---------------|
| LibriSpeech clean | **1.63** | 2.11 | 1.51 | 1.39 | 2.89 |
| LibriSpeech other | **3.38** | 4.55 | 3.97 | 3.75 | 3.56 |
| GigaSpeech | **8.45** | 8.88 | 9.76 | 25.50 | 9.37 |
| CommonVoice-en | **7.39** | 9.92 | 9.90 | 9.08 | 14.49 |
| TEDLIUM | **4.50** | - | 6.84 | 7.69 | 6.15 |
| VoxPopuli | **9.15** | - | 12.05 | 10.29 | 11.36 |

#### 中文（普通话）

| 数据集 | Qwen3-ASR-1.7B | Qwen3-ASR-0.6B | Whisper-large-v3 | GPT-4o | Gemini-2.5-Pro |
|--------|---------------|----------------|-----------------|--------|---------------|
| WenetSpeech net | **4.97** | 5.97 | 9.86 | 15.30 | 14.43 |
| WenetSpeech meeting | **5.88** | 6.88 | 19.11 | 32.27 | 13.47 |
| AISHELL-2 | **2.71** | 3.15 | 5.06 | 4.24 | 11.62 |
| SpeechIO | **2.88** | - | 7.56 | 12.86 | 5.30 |

#### 中文方言

| 数据集 | Qwen3-ASR-1.7B | Whisper-large-v3 |
|--------|---------------|-----------------|
| KeSpeech（方言集） | **5.10** | 28.79 |
| Fleurs-yue（粤语） | **3.98** | 9.18 |
| CV-yue（粤语） | **7.57** | 16.23 |
| CV-zh-tw（台湾华语） | **3.77** | 7.84 |
| WenetSpeech-Yue short | **5.82** | 32.26 |
| WenetSpeech-Yue long | **8.85** | 46.64 |

**中文方言是 Qwen3-ASR 碾压 Whisper 的领域。** KeSpeech 上 5.10% vs 28.79%，差距达 5.6 倍。

#### 多语言

| 数据集 | Qwen3-ASR-1.7B | Whisper-large-v3 |
|--------|---------------|-----------------|
| MLS（8种语言） | **8.55** | 8.62 |
| CommonVoice（13种语言） | **9.18** | 10.77 |
| MLC-SLM（11种语言） | **12.74** | 15.68 |
| Fleurs（12种语言） | **4.90** | 5.27 |
| News-Multilingual（15种语言） | **12.80** | 14.80 |

#### 歌唱/音乐识别

| 数据集 | Qwen3-ASR-1.7B | Whisper-large-v3 | GPT-4o |
|--------|---------------|-----------------|--------|
| M4Singer | **5.98** | 13.58 | 16.77 |
| MIR-1k-vocal | **6.25** | 11.71 | 11.87 |
| Opencpop | **3.08** | 9.52 | 7.93 |
| EntireSongs-zh | **13.91** | N/A | 34.86 |

#### 语言识别准确率

| 数据集 | Qwen3-ASR-1.7B | Whisper-large-v3 |
|--------|---------------|-----------------|
| MLS | 99.9% | 99.9% |
| CommonVoice | **98.7%** | 92.7% |
| MLC-SLM | **94.1%** | 89.2% |
| Fleurs | **98.7%** | 94.6% |
| **平均** | **97.9%** | 94.1% |

---

## 第三部分：macOS / Apple Silicon 运行情况

### 3.1 speech-swift（原 qwen3-asr-swift）

**项目概况：**
- GitHub: github.com/ivan-digital/qwen3-asr-swift（现更名为 soniqo/speech-swift）
- Stars: 621+，Forks: 73+
- 许可证：Apache 2.0
- 最新版本：v0.0.9（2026 年 4 月）
- 在 Swift Forums 上有官方发布帖

**核心功能（远超单纯 ASR）：**

| 类别 | 模型 | 参数量 | 后端 |
|------|------|--------|------|
| ASR | Qwen3-ASR (0.6B/1.7B) | 0.6B-1.7B | MLX |
| ASR | Parakeet TDT | 600M | CoreML |
| ASR | Parakeet EOU（流式） | 120M | CoreML |
| ASR | Omnilingual ASR | 300M-7B | CoreML/MLX 混合 |
| TTS | Qwen3-TTS | 0.6B-1.7B | MLX |
| TTS | CosyVoice3 | 0.5B | MLX |
| TTS | Kokoro | 82M | CoreML/ANE |
| 语音对话 | PersonaPlex | 7B | MLX |
| VAD | Silero | 小 | 流式 |
| 说话人分离 | Pyannote + WeSpeaker | - | - |
| 降噪 | DeepFilterNet3 | 2.1M | CoreML/ANE |
| 对齐 | Qwen3-ForcedAligner | 0.6B | MLX |

**集成方式：Swift Package Manager (SPM)**

```swift
.package(url: "https://github.com/soniqo/speech-swift", from: "0.0.9")
```

模块化设计，每个模型是独立的 SPM target，按需引入：

```swift
import Qwen3ASR  // 只引入 ASR

let model = try await Qwen3ASRModel.fromPretrained()
let result = model.transcribe(audio: audioBuffer, sampleRate: 16000)
```

**API 设计：**
- 同步转写：`model.transcribe(audio:, sampleRate:)`
- 流式转写：`for await partial in model.transcribeStream(audio:, sampleRate:)`
- 内置 SwiftUI 组件：`TranscriptionView`、`TranscriptionStore`

**系统要求：**
- Swift 5.9+, Xcode 15+
- macOS 14+ / iOS 17+
- Apple Silicon（M1-M4），不支持 x86/Rosetta
- 需要 Metal Toolchain（否则 MLX 无法加载 metallib）

**性能数据：**
- RTF（实时因子）：0.15-0.27（即 3.7x-6.3x 实时速度），在 M2 Max 上
- PersonaPlex 语音对话：RTF ~0.94（M2 Max）
- Parakeet TDT（CoreML）：32x 实时

**模型缓存**：权重缓存在 `~/Library/Caches/qwen3-speech/`，支持 `offlineMode: true` 离线运行。

**HTTP API 服务器**：内置 `audio-server` CLI，暴露 REST + WebSocket 端点，包括 OpenAI Realtime API 兼容的 `/v1/realtime` WebSocket。

**局限性：**
- Qwen3-ASR 走 MLX（GPU），非 CoreML/ANE，性能和功耗不如 ANE 路径
- 项目仍在 v0.x 阶段，API 可能变化
- 3 个 open issues
- Metal Toolchain 依赖可能在某些环境下出问题

### 3.2 mlx-qwen3-asr（Python 实现）

**项目概况：**
- GitHub: github.com/moona3k/mlx-qwen3-asr
- 纯 Python，基于 Apple MLX 框架
- 无 PyTorch 依赖（核心转写部分）

**性能（M4 Pro，0.6B 模型）：**

| 精度 | 延迟（2.5秒音频） | RTF | 备注 |
|------|-----------------|-----|------|
| FP16 | 0.46s | 0.08 | 12.5x 实时 |
| 8-bit 量化 | - | 3.11x 更快 | 质量损失极小（+0.04pp WER） |
| 4-bit 量化 | - | 4.68x 更快 | 质量有损（+0.43pp WER） |

**内存占用：**
- 0.6B 模型：~1.2 GB
- 1.7B 模型：~3.4 GB

**功能特性：**
- 30 种语言 + 22 种中文方言
- 词级时间戳（通过 ForcedAligner）
- 说话人分离（基于 pyannote）
- 长音频支持（每段最长 20 分钟）
- 流式推理（KV-cache 重用）
- 麦克风实时捕获
- HTTP 服务器（OpenAI API 兼容）
- 多种输出格式（txt, json, srt, vtt, tsv）
- 量化支持（4-bit, 8-bit）
- 推测解码（0.6B 草稿 + 1.7B 验证）
- 462 个单元测试

**WER 测试（MLX 实现）：**

| 数据集 | 0.6B | 1.7B |
|--------|------|------|
| LibriSpeech clean | 2.29% | 1.99% |
| LibriSpeech other | 4.20% | 3.45% |
| FLEURS 10语言 | 9.37% | 6.70% |

与 PyTorch 官方实现对比：67% 的样本产生完全相同的文本输出。

### 3.3 antirez/qwen-asr（C 实现）

由 Redis 创始人 antirez 开发的纯 C 实现，值得关注：

- 零外部依赖（仅需 C 标准库 + BLAS）
- 使用内存映射加载 BF16 safetensors，接近即时加载
- Apple Silicon 上使用 NEON 优化
- **不打算支持 MPS/Metal**，优先 Linux 服务器

**性能（M3 Max，0.6B）：**
- 11 秒音频：1.4 秒推理（~8x 实时）
- 89 秒音频（分段模式）：13.1 秒推理（~6.78x 实时）
- 流式模式：~4.69x 实时

### 3.4 CoreML 转换可行性

**目前没有官方 CoreML 版本。** 可行性分析：

| 因素 | 评估 |
|------|------|
| 编码器（AuT） | Conv2D + Transformer，CoreML 支持良好，可转换 |
| 动态窗口注意力 | 需要定制，CoreML 对动态形状支持有限 |
| LLM 解码器（Qwen3） | 自回归生成，CoreML 支持但效率不如 MLX |
| MRoPE | 非标准 RoPE 变体，需要手动实现 |
| ANE 适配 | 编码器可能上 ANE，解码器困难 |

**总结**：CoreML 转换技术上可行但工作量大，且自回归解码器在 ANE 上效率不高。MLX 路径可能仍是 Apple Silicon 上的最优选择。

### 3.5 与 WhisperKit 在 Apple Silicon 上的对比

| 维度 | Qwen3-ASR (speech-swift/MLX) | WhisperKit (CoreML/ANE) |
|------|------------------------------|------------------------|
| 推理后端 | MLX (GPU) | CoreML (ANE) |
| RTF（实时倍率） | 3.7-6.3x | 15-30x |
| 内存占用 | ~1.2 GB (0.6B) | ~800 MB (Turbo), ~1.5 GB (v3) |
| 中文 WER | **极优**（AISHELL-2: 2.71%） | 一般（AISHELL-2: ~5%） |
| 英语 WER | **略优**（GigaSpeech: 8.45%） | 较好（~9-10%） |
| 方言支持 | **22 种中文方言** | 有限 |
| 语言识别 | **97.9%** | 依赖 Whisper（~94%） |
| 功耗 | 较高（GPU 推理） | 较低（ANE 推理） |
| 流式支持 | 原生支持 | 需分段处理 |
| 成熟度 | v0.x，活跃开发中 | 成熟，生产级 |
| 集成难度 | SPM，模块化 | SPM，成熟 API |

---

## 第四部分：流式/实时转录能力

### 4.1 流式架构

Qwen3-ASR 的流式推理不是事后补丁，而是架构设计的一部分：

- **动态注意力窗口**：1-8 秒，短窗口用于流式，长窗口用于离线
- **chunk 大小**：默认 2 秒
- **策略**：5-token fallback，保持最后 4 个 chunk 不固定
- **统一模型**：同一个模型同时支持流式和离线，无需切换

### 4.2 流式性能

| 指标 | Qwen3-ASR-1.7B | Qwen3-ASR-0.6B |
|------|----------------|----------------|
| TTFT（首 token 延迟） | ~102ms | ~92ms |
| RTF @ 并发128 | 0.105 | 0.064 |

**流式 vs 离线 WER 对比：**

| 模型 | 模式 | LibriSpeech clean|other | Fleurs-en | Fleurs-zh | 平均 |
|------|------|----------------------|-----------|-----------|------|
| 1.7B | 离线 | 1.63 \| 3.38 | 3.35 | 2.41 | **2.69** |
| 1.7B | 流式 | 1.95 \| 4.51 | 4.02 | 2.84 | **3.33** |

流式模式的 WER 仅比离线高约 0.6 个百分点，质量损失可接受。

### 4.3 在 speech-swift 中的流式支持

```swift
for await partial in model.transcribeStream(audio: audioBuffer, sampleRate: 16000) {
    switch partial {
    case .partial(let text):
        // 中间结果
    case .final(let text):
        // 最终结果
    }
}
```

speech-swift 还集成了 Parakeet EOU（120M 参数）用于端点检测（end-of-utterance），可辅助流式 ASR 判断用户是否说完。

---

## 第五部分：与 Canary-Qwen-2.5B 的关系

### 5.1 Canary-Qwen-2.5B 是什么？

**NVIDIA Canary-Qwen-2.5B 不是阿里的 Qwen3-ASR。** 它是 NVIDIA NeMo 团队的产品，与阿里 Qwen 团队无直接关系。

**名字中的 "Qwen" 来源**：Canary-Qwen-2.5B 使用 **Qwen3-1.7B LLM 作为解码器组件**，但编码器是 NVIDIA 自己的 FastConformer（来自 canary-1b-flash）。NVIDIA 将 FastConformer 编码器的音频特征通过线性投影 + LoRA 连接到 Qwen3 LLM，构成了一个 SALM（Speech-Augmented Language Model）。

### 5.2 对比

| 维度 | Canary-Qwen-2.5B | Qwen3-ASR-1.7B |
|------|-------------------|----------------|
| 开发者 | NVIDIA NeMo | 阿里云 Qwen Team |
| 参数量 | 2.5B | 1.7B |
| 架构 | FastConformer + Qwen3 LLM | AuT + Qwen3 LLM |
| 语言 | **仅英语** | 30 种语言 + 22 种中文方言 |
| Open ASR 排名 | #1（WER 5.63%） | 未参加排名 |
| 英语平均 WER | **5.63%** | 需看具体数据集 |
| 中文 | **不支持** | **极优** |
| 训练数据 | 23.4 万小时 | ~4000 万小时 |
| 框架依赖 | NVIDIA NeMo | transformers / vLLM |
| macOS 支持 | 无（需要 NVIDIA GPU） | 有（MLX/speech-swift） |
| 许可证 | CC-BY-4.0 | Apache 2.0 |

### 5.3 结论

Canary-Qwen-2.5B 是英语专用模型，在 Open ASR Leaderboard 上排名第一但不支持中文，且无法在 Apple Silicon 上运行。对 WhisperUtil 项目无实际价值。

---

## 第六部分：已知问题和局限性

### 6.1 模型层面

1. **无官方 code-switching 基准测试**：虽然声称支持语言混合，但技术报告未提供专项评测数据
2. **流式模式需要 vLLM 后端**：官方 Python 实现的流式推理仅通过 vLLM 支持
3. **无法指定输出语言**：通过 vLLM serve 部署时，用户无法强制指定 ASR 输出语言（GitHub Issue #93）
4. **GPU 显存控制异常**：vLLM 后端的 `--gpu-memory-utilization` 参数不生效（Issue #20）
5. **流式 ASR 微调代码未开源**：仅提供离线 ASR 微调

### 6.2 Apple Silicon 层面

1. **无 CoreML/ANE 优化**：目前只能通过 MLX（GPU）运行，功耗和速度不如 ANE
2. **speech-swift 仍在 v0.x**：API 可能变化，生产稳定性待验证
3. **MLX 实现与 PyTorch 不完全一致**：仅 67% 样本产生完全相同输出
4. **1.7B 模型内存占用较大**：~3.4 GB，在 8GB RAM 设备上可能紧张
5. **Metal Toolchain 依赖**：缺少时 MLX 推理会失败

### 6.3 集成层面

1. **没有 WhisperKit 那样的一键集成体验**：需要更多手动配置
2. **模型下载体积**：0.6B 约 1.9GB，1.7B 约 4.7GB，首次下载需要时间
3. **不支持 x86/Rosetta**：仅限 Apple Silicon

---

## 第七部分：对 WhisperUtil 的影响与建议

### 7.1 集成可行性评估

| 评估维度 | 结论 |
|---------|------|
| Swift 可用性 | **可行**：speech-swift 提供完整 SPM 包 |
| API 兼容性 | **良好**：同步/流式 API 设计清晰 |
| 性能 | **可接受**：3.7-6.3x 实时（0.6B），足够日常使用 |
| 内存 | **可接受**：~1.2GB（0.6B），现代 Mac 均可承受 |
| 准确率 | **优秀**：中文大幅领先 WhisperKit |
| 流式 | **支持**：speech-swift 提供流式 API |
| 稳定性 | **待验证**：v0.x 阶段 |

### 7.2 集成工作量

预估需要 **3-5 天**：

1. **Day 1**：添加 speech-swift SPM 依赖，创建 `ServiceLocalQwen` 类
2. **Day 2**：实现与现有 `RecordingController` 的对接，处理音频格式转换
3. **Day 3**：实现模型下载/缓存管理，添加设置 UI
4. **Day 4**：流式模式集成和测试
5. **Day 5**：边缘情况处理、性能调优、内存优化

### 7.3 推荐策略

**短期（现在）**：维持 WhisperKit + gpt-4o-transcribe 现状。对于中英混合场景，Cloud 模式的 gpt-4o-transcribe 表现已足够好。

**中期（speech-swift 到 v1.0 时）**：引入 Qwen3-ASR 作为本地模式的替代选项：
- 在 Local 模式下提供 WhisperKit / Qwen3-ASR 双选
- 中文用户推荐 Qwen3-ASR，英语用户可继续用 WhisperKit
- 利用 speech-swift 的模块化设计，仅引入 Qwen3ASR target

**长期**：关注以下发展：
- speech-swift 是否会增加 Qwen3-ASR 的 CoreML/ANE 路径
- Qwen 团队是否会发布更小的端侧专用模型（如 0.3B）
- 社区是否会出现 Qwen3-ASR 的 CoreML 转换工具

### 7.4 架构集成方案

```
RecordingController
    +-- Services/ServiceLocalWhisper (WhisperKit, CoreML/ANE) ← 现有
    +-- Services/ServiceLocalQwen (speech-swift, MLX/GPU) ← 新增
    +-- Services/ServiceCloudOpenAI (HTTP) ← 现有
    +-- Services/ServiceRealtimeOpenAI (WebSocket) ← 现有
```

用户在 Settings 中选择 Local 模式时，可进一步选择引擎：
- WhisperKit（速度快，英语优先）
- Qwen3-ASR（准确率高，中文/多语言优先）

---

## 附录：信息来源

### 官方资源
- [Qwen3-ASR GitHub](https://github.com/QwenLM/Qwen3-ASR)
- [Qwen3-ASR-1.7B HuggingFace](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)
- [Qwen3-ASR-0.6B HuggingFace](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)
- [Qwen3-ASR 技术报告 (arXiv)](https://arxiv.org/abs/2601.21337)
- [Qwen Blog: Qwen3-ASR 发布公告](https://qwen.ai/blog?id=qwen3asr)

### Apple Silicon 实现
- [speech-swift (原 qwen3-asr-swift)](https://github.com/ivan-digital/qwen3-asr-swift)
- [speech-swift Swift Forums 帖子](https://forums.swift.org/t/speech-swift-on-device-speech-processing-for-apple-silicon-asr-tts-diarization-speech-to-speech/85182)
- [speech-swift Swift Package Index](https://swiftpackageindex.com/soniqo/speech-swift)
- [mlx-qwen3-asr (Python MLX)](https://github.com/moona3k/mlx-qwen3-asr)
- [antirez/qwen-asr (C 实现)](https://github.com/antirez/qwen-asr)
- [speech-swift 架构与性能博客](https://blog.ivan.digital/qwen3-asr-swift-on-device-asr-tts-for-apple-silicon-architecture-and-benchmarks-27cbf1e4463f)

### MLX 量化版本
- [mlx-community/Qwen3-ASR-0.6B-8bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit)
- [mlx-community/Qwen3-ASR-0.6B-bf16](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-bf16)

### NVIDIA Canary 相关
- [nvidia/canary-qwen-2.5b HuggingFace](https://huggingface.co/nvidia/canary-qwen-2.5b)
- [NVIDIA Canary-Qwen-2.5B 技术论坛](https://forums.developer.nvidia.com/t/nvidia-canary-qwen-2-5b-open-source-asr-llm-for-superior-transcription-and-summarization/339387)

### 综合评测
- [BrightCoding: Qwen3-ASR 52 Languages](https://blog.brightcoding.dev/2026/04/07/qwen3-asr-the-revolutionary-speech-tool-for-52-languages)
- [Northflank: Best Open Source STT in 2026](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [EmergentMind: Qwen3-ASR-1.7B 概览](https://www.emergentmind.com/topics/qwen3-asr-1-7b)
- [VoicePing: 离线语音转写基准](https://voiceping.net/en/blog/research-offline-speech-transcription-benchmark/)
