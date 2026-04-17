# Groq 语音识别 API 调研

日期：2026-04-14

## 摘要

Groq 基于自研 LPU（Language Processing Unit）芯片提供超高速 Whisper 推理服务，API 格式与 OpenAI 兼容。提供三个语音识别模型：whisper-large-v3（$0.111/小时）、whisper-large-v3-turbo（$0.04/小时）、distil-whisper-large-v3-en（$0.02/小时，仅英文）。速度方面，Groq Whisper 达到 216-240x 实时速度因子，远超 OpenAI 端点。由于 API 端点格式兼容 OpenAI，WhisperUtil 项目迁移成本极低——仅需修改 base URL 和 API Key。但 Groq 本质上运行的是开源 Whisper 模型，不支持 OpenAI 的 gpt-4o-transcribe 等新一代模型，转录精度不及 OpenAI 最新方案。建议作为补充选项（低成本 / 高速度场景）而非完全替代。

---

## Part 1：Groq 公司与 LPU 芯片概述

### 1.1 公司背景

Groq 成立于 2016 年，由前 Google TPU 团队成员创立，专注于 AI 推理加速。公司核心产品是 LPU（Language Processing Unit），一种专为自回归语言模型推理设计的处理器架构。

> 注意区分：Groq（AI 推理芯片公司）与 Grok（xAI 的大语言模型）是完全不同的实体。

### 1.2 LPU 架构特点

| 特性 | 说明 |
|------|------|
| 设计理念 | 软件优先（software-first），专为线性代数计算设计 |
| 执行模型 | 确定性执行（deterministic execution），无分支预测、无缓存、无乱序执行 |
| 内存架构 | 数百 MB 片上 SRAM 作为主存储（非缓存），访问延迟极低 |
| 芯片互联 | 近同步（plesiosynchronous）芯片间协议，数百个 LPU 协同如单核 |
| 编译器 | 静态调度，编译器完全控制执行时序，可精确预测数据到达时间 |

### 1.3 速度优势的根源

传统 GPU 推理受限于"内存墙"（Memory Wall）——模型权重在 HBM 与计算单元间的传输带宽成为瓶颈。LPU 通过将权重存储在片上 SRAM 中、使用确定性流水线执行，从架构层面消除了这一瓶颈。

---

## Part 2：Groq 语音识别产品

### 2.1 可用模型

| 模型 ID | 基础模型 | 参数量 | 语言支持 | 速度因子 | 价格（/小时音频） |
|---------|---------|--------|---------|---------|------------------|
| `whisper-large-v3` | OpenAI Whisper Large V3 | 15.5 亿 | 多语言（99 种） | 217x | $0.111 |
| `whisper-large-v3-turbo` | OpenAI Whisper Large V3 Turbo | ~8 亿（裁剪版） | 多语言 | 228x | $0.04 |
| `distil-whisper-large-v3-en` | Distil-Whisper | 7.56 亿 | 仅英文 | 240x | $0.02 |

所有模型均基于开源 Whisper 系列，Groq 在自有 LPU 硬件上进行推理加速，不修改模型本身。

### 2.2 API 端点

```
转录：POST https://api.groq.com/openai/v1/audio/transcriptions
翻译：POST https://api.groq.com/openai/v1/audio/translations
```

### 2.3 技术规格

| 项目 | 规格 |
|------|------|
| 最大文件大小 | 25 MB（直传），可通过 `url` 参数指定远程文件（上限约 100 MB，但有报告不稳定） |
| 支持音频格式 | flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm |
| 音频预处理 | 自动降采样至 16 kHz 单声道 |
| 多音轨 | 仅转录第一音轨 |
| 最小计费单位 | 10 秒/请求（不足 10 秒按 10 秒计费） |

---

## Part 3：多语种混杂（Code-Switching）支持

### 3.1 本质

Groq 运行的是原版 OpenAI Whisper 模型，因此多语种混杂能力完全取决于 Whisper 模型本身，与 Groq 硬件无关。

### 3.2 Whisper 的 Code-Switching 能力

**优势：**
- Whisper Large V3 在 100 万小时弱标注音频 + 400 万小时伪标注音频上训练，覆盖 99 种语言
- 官方声称对 code-switching 有较好的支持，能保留语言切换的原始流向
- 英文 LibriSpeech（干净）WER 约 2.0%；Fleurs 多语言平均 WER 约 10.6%

**已知问题：**
- Whisper 本质上是为单语言音频设计的。`language` 参数一次只能指定一种语言
- 用户社区反馈：中英混杂时表现不稳定——有时能正确保留双语，有时会将全部内容翻译为单一语言
- 不同语言间的性能差异大，低资源语言准确率显著下降
- 相比 OpenAI 的 gpt-4o-transcribe 系列（内置更强的多语言理解），原版 Whisper 在混杂场景中明显处于劣势

### 3.3 对 WhisperUtil 的影响

WhisperUtil 当前使用 gpt-4o-transcribe，其 code-switching 能力显著优于原版 Whisper。如果切换到 Groq（即回退到 Whisper Large V3），中英混杂转录质量可能会下降。这是 Groq 方案的最大短板。

---

## Part 4：收费情况

### 4.1 价格对比

| 服务 | 模型 | 价格（/小时音频） | 价格（/分钟音频） |
|------|------|------------------|------------------|
| **Groq** | whisper-large-v3 | $0.111 | $0.00185 |
| **Groq** | whisper-large-v3-turbo | $0.04 | $0.000667 |
| **Groq** | distil-whisper-large-v3-en | $0.02 | $0.000333 |
| **OpenAI** | gpt-4o-transcribe | — | $0.006 |
| **OpenAI** | gpt-4o-mini-transcribe | — | $0.003 |
| **OpenAI** | whisper-1 | — | $0.006 |

**价格优势：**
- Groq whisper-large-v3-turbo 约为 OpenAI gpt-4o-mini-transcribe 的 **1/4.5 价格**
- Groq distil-whisper 约为 OpenAI gpt-4o-mini-transcribe 的 **1/9 价格**

### 4.2 免费额度

Groq 提供免费 API 访问，Speech-to-Text 模型免费额度：

| 限制项 | 免费额度 |
|--------|---------|
| 请求速率（RPM） | 20 次/分钟 |
| 每日请求数（RPD） | 2,000 次/天 |
| 吞吐量 | 约 2 小时音频/每小时时钟时间 |

注意：速率限制是组织级别的（不是 per API key），同一组织下多个 key 共享配额。

### 4.3 付费层级

Groq 提供开发者付费层级（Dev Tier）和企业私有部署方案，付费后限额大幅提升。具体付费层级限额需在 Groq Console 查看或联系 sales@groq.com。

---

## Part 5：API 兼容性分析

### 5.1 与 OpenAI API 的兼容性

Groq 有意设计了 OpenAI 兼容的 API 路径：

```
OpenAI:  https://api.openai.com/openai/v1/audio/transcriptions
Groq:    https://api.groq.com/openai/v1/audio/transcriptions
```

**兼容的参数：**

| 参数 | 说明 | Groq 支持 |
|------|------|----------|
| `file` | 音频文件 | 支持 |
| `model` | 模型名称 | 支持（需替换为 Groq 模型名） |
| `language` | ISO-639-1 语言代码 | 支持 |
| `prompt` | 提示文本 | 支持 |
| `response_format` | 返回格式（json, text, srt, verbose_json, vtt） | 支持 |
| `temperature` | 采样温度 | 支持 |
| `timestamp_granularities` | 时间戳粒度 | 支持 |

**认证方式：** 使用 `Authorization: Bearer <GROQ_API_KEY>` Header，格式与 OpenAI 相同。

### 5.2 不兼容项

- **模型名不同**：OpenAI 使用 `gpt-4o-transcribe` 等，Groq 使用 `whisper-large-v3` 等
- **无 gpt-4o 系列**：Groq 仅托管开源 Whisper 模型，不提供 OpenAI 专有的 gpt-4o-transcribe 系列
- **url 参数**：Groq 支持通过 `url` 参数传入远程音频文件 URL（OpenAI 不支持此参数）

---

## Part 6：速度优势

### 6.1 速度因子对比

"速度因子"（Speed Factor / Real-Time Factor）= 每秒钟可转录的音频秒数。

| 服务/模型 | 速度因子 | 说明 |
|----------|---------|------|
| Groq whisper-large-v3 | 217x | Artificial Analysis 基准测试 |
| Groq whisper-large-v3-turbo | 228x | Artificial Analysis 基准测试 |
| Groq distil-whisper | 240x | 最快 |
| OpenAI whisper-1 | ~35-40x | 估算值 |
| OpenAI gpt-4o-transcribe | 未公开 | 体感快于 whisper-1 |

### 6.2 实际体验

对于 WhisperUtil 的典型使用场景（几秒到几十秒的短音频片段），Groq 的速度优势体现为：
- 网络延迟占比更高，推理时间几乎可忽略
- 短音频场景下体感差异可能不大（均在毫秒级）
- 长音频场景下优势明显（例如 1 小时音频，Groq 约 15-17 秒完成 vs OpenAI 约 1.5 分钟）

---

## Part 7：集成方式与迁移成本

### 7.1 WhisperUtil 当前架构

项目相关代码：
- `Config/EngineeringOptions.swift` 定义 API URL（`whisperTranscribeURL`, `whisperTranslateURL`）
- `Services/ServiceCloudOpenAI.swift` 实现 HTTP 转录/翻译调用

当前硬编码 OpenAI 端点：
```swift
static let whisperTranscribeURL = "https://api.openai.com/v1/audio/transcriptions"
static let whisperTranslateURL = "https://api.openai.com/v1/audio/translations"
```

### 7.2 迁移方案

由于 Groq API 格式兼容 OpenAI，迁移步骤非常简单：

1. **添加 Groq API Key 存储**：在 KeychainHelper 中增加 Groq Key 的存取
2. **添加服务提供商选项**：在设置界面添加 Cloud 模式下的服务商选择（OpenAI / Groq）
3. **动态切换 Base URL**：根据选择的服务商替换 base URL（`api.openai.com` → `api.groq.com`）
4. **动态切换模型名**：OpenAI 模式用 `gpt-4o-transcribe`，Groq 模式用 `whisper-large-v3-turbo`
5. **翻译端点**：Groq 同样支持 `/audio/translations`，可直接复用

**预估工作量：** 约 1-2 小时，主要是 UI 和配置层的修改，核心网络逻辑无需改动。

### 7.3 建议的实现策略

```
EngineeringOptions / SettingsStore:
  - 新增 cloudProvider 枚举：.openai | .groq
  - 根据 provider 返回不同的 baseURL 和默认 model

ServiceCloudOpenAI:
  - 将 URL 构建改为基于 baseURL + path
  - model 参数从 provider 配置读取

KeychainHelper:
  - 新增 groqAPIKey 的存取方法

SettingsView:
  - Cloud 模式下新增 Provider 选择器
  - 对应显示不同的 API Key 输入框和模型选择
```

---

## Part 8：已知问题与局限性

### 8.1 功能局限

| 问题 | 说明 |
|------|------|
| 无 gpt-4o 系列模型 | 只能使用开源 Whisper，转录精度低于 OpenAI 最新方案 |
| Code-switching 较弱 | 原版 Whisper 的多语种混杂不如 gpt-4o-transcribe |
| 无实时流式 API | Groq 目前未提供类似 OpenAI Realtime API 的 WebSocket 流式转录 |
| 无说话人识别 | 不支持类似 gpt-4o-transcribe-diarize 的说话人分离功能 |

### 8.2 稳定性问题

| 问题 | 说明 |
|------|------|
| 大文件上传不稳定 | 社区报告 37-47 MB 文件触发 "Entity Too Large" 错误，尽管文档标称支持 100 MB |
| 免费层速率限制紧 | 20 RPM / 2000 RPD，高频使用易触发限流 |
| 服务可用性 | 作为创业公司，长期服务稳定性和 SLA 不及 OpenAI |

### 8.3 对 WhisperUtil 场景的具体影响

- **短音频场景**（WhisperUtil 典型用法）：速度优势不明显，25 MB 限制足够
- **中英混杂**：如果用户经常中英混说，Groq 体验可能不如 OpenAI
- **免费额度**：2000 次/天对个人用户足够，每次请求几秒音频不会触发限制
- **翻译功能**：Groq 翻译端点同样基于 Whisper，功能与 OpenAI 的 whisper-1 翻译相当

---

## Part 9：结论与建议

### 9.1 评估总结

| 维度 | Groq | OpenAI | 胜出 |
|------|------|--------|------|
| 转录速度 | 217-240x 实时 | ~35-40x 实时 | Groq |
| 转录精度 | Whisper 级别 | gpt-4o 级别 | OpenAI |
| Code-switching | 较弱 | 较强 | OpenAI |
| 价格 | $0.04/小时起 | $0.18/小时起 | Groq |
| 免费额度 | 有（2000次/天） | 无 | Groq |
| API 兼容性 | OpenAI 兼容 | 原生 | 平 |
| 流式转录 | 不支持 | 支持（Realtime API） | OpenAI |
| 迁移成本 | 极低 | — | — |

### 9.2 建议

**作为补充选项，不作为替代。** 具体建议：

1. **实现为可选 Provider**：在 Cloud 模式下添加 Groq 作为可选服务商，用户可自行选择
2. **默认仍用 OpenAI**：gpt-4o-transcribe 的精度和 code-switching 能力对 WhisperUtil 的核心体验至关重要
3. **Groq 适用场景**：对转录精度要求不高、主要使用单一语言、追求极低成本的用户
4. **优先级建议**：中低优先级。当前 OpenAI 方案工作良好，Groq 集成工作量虽小但增加了维护面

---

## Part 10: 补充：跨语言对 Code-Switching 评测数据

### 各服务多语言对 CS 支持矩阵

| 服务 | 支持的 CS 语言对 | 日+英 | 中+日 | 西+英 | 韩+英 | 印地+英 |
|------|-----------------|:-----:|:-----:|:-----:|:-----:|:------:|
| Deepgram Nova-3 | en/es/fr/de/hi/ru/pt/ja/it/nl 共10语互切 | ✅ | ❌ | ✅ | ❌ | ✅ |
| Speechmatics | 专门双语包：cmn+en, ar+en, ms+en, ta+en, fil+en | ❌ | ❌ | ⚠️ 需特殊配置 | ❌ | ❌ |
| Soniox | 宣称 60+ 语言统一模型自动检测 | ❓ 无专项数据 | ❓ | ❓ | ❓ | ❓ |
| Whisper/gpt-4o-transcribe | 理论99语言，无专门CS优化 | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| ElevenLabs | 仅优化印度语-英语 | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| Mistral Voxtral | 声称13语言切换，无专项数据 | ❓ | ❓ | ❓ | ❓ | ❓ |
| Apple SFSpeechRecognizer | 单语言，不支持CS | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Groq (Whisper)** | **同 Whisper 模型** | **⚠️** | **⚠️** | **⚠️** | **⚠️** | **⚠️** |

**结论：没有一个服务能覆盖所有语言对的 code-switching。** Groq 运行的是原版开源 Whisper 模型，其 CS 能力完全等同于 Whisper 本身——理论上支持 99 种语言但无专门 CS 优化，所有语言对均标记为 ⚠️。与 OpenAI 的 gpt-4o-transcribe 相比，Groq 在 CS 场景下处于明确劣势。

### Code-Switching 专用评测数据集

| 数据集 | 语言对 | 规模 | 说明 |
|--------|--------|------|------|
| ASCEND | 中-英 | 10.62h, 23人 | 香港自发对话 |
| SEAME | 中-英 / 马来-英 | ~30h, 92人 | 新加坡/马来西亚，MER 最佳 ~14.2% |
| CS-FLEURS (Interspeech 2025) | 52 语言, 113 对 | 三子集 | 目前最大规模多语 CS 基准 |
| SwitchLingua (NeurIPS 2025) | 12 语言, 63 民族 | 420K 文本 + 80h 音频 | 提出新指标 SAER |
| Miami Bangor | 西-英 | ~35h | 迈阿密西英双语对话 |
| CS-Dialogue | 中-英 | 104h | 2025年新发布，自发对话 |

### Whisper 各语言对 CS 实测表现

- **中英**：MER 约 14-20%（SEAME），经常把整句识别为单一语言
- **韩英**：微调后 CER 可降 1.7%，基线较差
- **日英**：无专项公开数据
- **西英**：西语单语好，但 CS 场景缺评测
- **gpt-4o-transcribe vs Whisper v3**：OpenAI 称改善但无具体数据

> 对 Groq 而言，上述 Whisper CS 实测数据直接适用——Groq 的 whisper-large-v3 和 whisper-large-v3-turbo 在 CS 场景下的表现与原版 Whisper 完全一致。中英 MER 14-20% 意味着每 5-7 个词就有一个错误，对于中英混杂的日常使用场景体验不佳。这进一步印证了"Groq 作为补充选项而非替代"的建议——需要 CS 的用户应继续使用 OpenAI gpt-4o-transcribe。

### 学术界核心趋势

- 参数高效微调(LoRA/Adapter) + 语言识别引导解码 + 合成数据增强是三大主线
- 微调后 MER 可相对降 4-7%

---

## 参考来源

- [Groq 官方定价页](https://groq.com/pricing)
- [Groq Speech to Text 文档](https://console.groq.com/docs/speech-to-text)
- [Whisper Large v3 模型文档](https://console.groq.com/docs/model/whisper-large-v3)
- [Whisper Large v3 Turbo 发布博客](https://groq.com/blog/whisper-large-v3-turbo-now-available-on-groq-combining-speed-quality-for-speech-recognition)
- [Distil-Whisper 发布博客](https://groq.com/blog/distil-whisper-is-now-available-to-the-developer-community-on-groqcloud-for-faster-and-more-efficient-speech-recognition)
- [Groq LPU 架构说明](https://groq.com/lpu-architecture)
- [Groq Whisper 164x 速度基准](https://groq.com/blog/groq-runs-whisper-large-v3-at-a-164x-speed-factor-according-to-new-artificial-analysis-benchmark)
- [Groq Rate Limits 文档](https://console.groq.com/docs/rate-limits)
- [Groq API 免费层级限制（2026）](https://www.grizzlypeaksoftware.com/articles/p/groq-api-free-tier-limits-in-2026-what-you-actually-get-uwysd6mb)
- [OpenAI Whisper GitHub - 多语言讨论](https://github.com/openai/whisper/discussions/2009)
- [Artificial Analysis Whisper 基准](https://artificialanalysis.ai/speech-to-text/models/whisper)
