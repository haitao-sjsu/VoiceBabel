# 语音转文字 / 语音输入产品市场调研报告

> 调研日期：2026-03-26
> 调研范围：全球竞品分析 + 开源 STT 模型现状

---

## 第一部分：竞品分析

### 1. 竞品总览表

| 产品 | 公司 | 平台 | 定价模式 | 本地/云端 | 技术栈 |
|------|------|------|----------|-----------|--------|
| Wispr Flow | Wispr | Mac/Win/iOS/Android | $10/月 | 云端 | Llama (微调) + 自研 STT |
| SuperWhisper | SuperWhisper | Mac/Win/iOS/iPad | $8.49/月 或 $249 终身 | 本地+云端 | Whisper (多模型) |
| MacWhisper | Jordi Bruin (独立开发) | Mac/iOS/iPad | €59 一次性 / Pro $79.99 | 本地 | Whisper |
| VoiceInk | Beingpax (独立开发) | Mac | $25-49 一次性 | 本地 | Whisper |
| Voibe | Voibe | Mac | $99 终身 / $44.10/年 | 本地 | Whisper |
| Buzz | 开源社区 | Mac/Win/Linux | 免费开源 | 本地 | Whisper/Whisper.cpp/Faster-Whisper |
| OpenWhispr | 开源社区 | Mac/Win/Linux | 免费 / Pro $8/月 | 本地+云端 | Whisper + Parakeet |
| Spokenly | Spokenly | Mac | 免费 (BYOK) | 本地+云端 | Whisper + Parakeet |
| BetterDictation | BetterDictation | Mac | $39-149 终身 | 云端 | 未公开 |
| SpeakMac | SpeakMac | Mac | $19 一次性 | 本地 | Whisper |
| Aqua Voice | Aqua Voice | Mac | $8-10/月 | 云端 | 自研 Avalon 模型 |
| Willow Voice | Willow Voice | Mac | $15/月 | 云端 | 自研 |
| Typeless | Typeless | Mac/Win/iOS/Android | $12/月 | 云端 | 未公开 |
| Whisper Notes | 独立开发 | Mac/iOS | $6.99 一次性 | 本地 | Whisper |
| 讯飞输入法 | 科大讯飞 | iOS/Android/Mac/Win | 免费 (含增值服务) | 云端 | 自研 ASR |
| 讯飞听见 | 科大讯飞 | Web/移动端 | 0.06-0.33元/分钟 | 云端 | 自研 ASR |
| 搜狗输入法 | 腾讯/搜狗 | iOS/Android/Win | 免费 | 云端 | 自研 ASR |
| 百度输入法 | 百度 | iOS/Android/Win | 免费 | 云端 | 自研 ASR |

---

### 2. 重点竞品详细分析

#### 2.1 Wispr Flow — 当前市场领导者

**基本信息：**
- 平台：Mac (2024.10)、Windows (2025.03)、iOS (2025.06)、Android (2026.02)
- 定价：$10/月，一个订阅覆盖全平台
- 技术：云端处理，基于微调 Llama 模型 + 自研 STT pipeline，由 Baseten 提供低延迟推理

**核心功能：**
- 系统级语音输入，在任何 app 中工作
- AI 自动清理：去除口头禅、重复、自动格式化
- 语气匹配：根据 app 和上下文自动调整文风
- 100+ 语言支持，含混合语言识别
- 150-184 WPM 输出速度
- 隐私模式：开启后零数据存储

**优势：**
- 跨平台覆盖最全
- AI 文本后处理能力最强（不只是转写，而是"说话变写作"）
- 品牌知名度高，Product Hunt 明星产品
- 延迟低 (100+ tokens 在 250ms 内处理)

**劣势：**
- 完全依赖云端，无离线模式
- 按月付费，长期成本高（5年 $600）
- 隐私敏感用户可能不放心

**WhisperUtil 可以学习的：**
- AI 文本后处理（清理、格式化）是核心差异化能力
- 系统级输入法体验比独立 app 窗口更好
- "语气匹配"功能有很大市场需求

---

#### 2.2 SuperWhisper — 全功能型

**基本信息：**
- 平台：Mac/Win/iOS/iPad，一个 Pro license 通用
- 定价：免费版 / $8.49/月 / $84.99/年 / $249.99 终身
- 技术：内置多个 Whisper 模型（Nano/Fast/Pro/Ultra），支持离线

**核心功能：**
- 自定义模式 (Custom Modes)：不同任务使用不同 AI 模型配置
- 支持 GPT/Claude/Llama 作为后处理
- 离线工作，完全本地处理
- 100+ 语言
- 会议助手：录制、转写、自动摘要
- SOC 2 Type II 认证，HIPAA 合规

**优势：**
- 功能最丰富，可定制性最强
- 离线本地处理，隐私保护好
- 企业级安全认证

**劣势：**
- 终身价格偏高 ($249.99)
- 功能复杂，学习曲线较陡

**WhisperUtil 可以学习的：**
- Custom Modes 概念：不同场景切换不同模型+后处理配置
- 会议助手是增值功能方向

---

#### 2.3 MacWhisper — 转写专精

**基本信息：**
- 开发者：独立开发者 Jordi Bruin
- 平台：Mac/iOS/iPad
- 定价：€59 一次性 (Gumroad) / Pro $79.99 (App Store)
- 已售近 30 万份
- Product Hunt 评分 4.8/5 (近 1900 条评价)

**核心功能：**
- 文件/录音转写（非实时语音输入）
- YouTube 视频转写
- 50+ 导出格式
- 批量处理、监控文件夹
- 播客章节检测
- 说话人分离
- AI 文本清理

**优势：**
- 转写功能全面，专业级
- 一次性购买，性价比高
- 用户口碑极好

**劣势：**
- 更侧重"文件转写"而非"实时语音输入"
- 实时 dictation 非核心功能

---

#### 2.4 VoiceInk — 开源标杆

**基本信息：**
- GitHub: 4300+ stars, 570+ forks (截至 2026.03)
- 平台：Mac
- 定价：$25-49 一次性 / 开源可自行编译免费使用
- 许可：GPL v3
- 最新版本：v1.72 (2026.03)

**核心功能：**
- 100% 本地 Whisper 处理
- Power Mode：检测当前 app 和 URL，自动切换配置
- 100+ 语言
- 即时转写

**优势：**
- 开源，代码可审查
- 价格低廉
- 社区活跃
- Power Mode 是独特亮点

**劣势：**
- 仅限 Mac
- 功能相对基础

**WhisperUtil 可以学习的：**
- Power Mode（按 app 自动切换配置）是很好的功能
- 开源策略值得参考

---

#### 2.5 OpenWhispr — 新兴全平台开源

**基本信息：**
- 平台：Mac/Win/Linux
- 定价：免费（本地模型 + BYOK）/ Pro $8/月
- 技术：Whisper + NVIDIA Parakeet

**核心功能：**
- 多 AI 提供商支持（OpenAI/Anthropic/Gemini/Groq/Mistral/本地）
- Agent Mode：流式 AI 对话覆盖
- Google Calendar 集成
- 实时会议转写
- 笔记系统 + 全文搜索

**优势：**
- 免费基础版 + 多引擎支持
- BYOK 模式灵活
- 功能创新（Agent Mode）

---

#### 2.6 Spokenly — 免费 + Parakeet

**基本信息：**
- 平台：Mac
- 定价：完全免费，无限制
- 技术：本地 Whisper + Parakeet (通过 FluidAudio CoreML)

**核心功能：**
- 支持 NVIDIA Parakeet TDT (通过 FluidAudio SDK 在 Apple Neural Engine 运行)
- 本地处理 + BYOK 云端可选
- 无字数/次数限制

**意义：**
- Parakeet 通过 FluidAudio/CoreML 已经可以在 Mac 上本地运行
- 这意味着 WhisperUtil 也可以考虑集成 Parakeet 作为本地引擎选项

---

#### 2.7 中国市场竞品

##### 讯飞输入法
- 市场占有率：26.04%（中国输入法市场第二）
- 语音识别率：98%
- 支持 23 种方言 + 30 种外语
- 400字/分钟输入速度
- 免费，含 AI 大模型功能
- 集成讯飞星火大模型
- 有 macOS 版本，支持 ARM 和 Intel

##### 讯飞听见（独立语音转文字服务）
- 套餐价格：0.06-0.33 元/分钟
- 会员方案：98 元/月起 (50小时)
- 实时转写：9.9 元/月
- 专业级转写服务

##### 搜狗输入法
- 市场占有率：54.64%（中国输入法市场第一）
- 语音输入是重要功能，但非独立工具
- 免费

##### 百度输入法
- 市场占有率：14.60%
- 集成大模型 AI 语音输入
- 支持方言和多语言切换
- 免费

---

### 3. 市场趋势总结

#### 定价趋势
- **免费层**：Spokenly、Buzz、VoiceInk (自编译)、Gboard
- **低价一次性**：Whisper Notes ($6.99)、SpeakMac ($19)、BetterDictation ($39)、VoiceInk ($25-49)
- **中价一次性**：MacWhisper (€59)、Voibe ($99)
- **高价终身**：SuperWhisper ($249.99)
- **订阅制**：Wispr Flow ($10/月)、Aqua Voice ($8-10/月)、Willow Voice ($15/月)、Typeless ($12/月)

#### 技术趋势
1. **Parakeet 崛起**：NVIDIA Parakeet 通过 FluidAudio SDK 已可在 Apple Neural Engine 运行，多款产品（Spokenly、VoiceInk）已集成
2. **AI 后处理成为标配**：从原始转写到智能格式化、语气匹配
3. **BYOK 模式流行**：用户自带 API key，降低产品成本
4. **隐私/离线成为卖点**：本地处理是重要差异化

#### 对 WhisperUtil 的启示
1. **考虑集成 Parakeet**：通过 FluidAudio CoreML 在 Neural Engine 上运行，英文精度更高
2. **AI 后处理能力**：添加文本清理、格式化、去口头禅功能
3. **Power Mode / Custom Modes**：按场景/app 自动切换配置
4. **定价参考**：一次性 $19-49 是低端市场甜蜜点

---

## 第二部分：开源 STT 模型全景 (2025-2026)

### 1. 模型总览表

| 模型 | 机构 | 参数量 | 英文 WER | 中文 CER | 速度 | 语言数 | 许可证 | 移动端部署 |
|------|------|--------|----------|----------|------|--------|--------|-----------|
| **Whisper Large V3** | OpenAI | 1.55B | ~7.4% | ~8-12% | 基准 | 99+ | MIT | 较难 (大) |
| **Whisper Large V3 Turbo** | OpenAI | 809M | ~7.75% | ~9-13% | 6x V3 | 99+ | MIT | 可行 |
| **Distil-Whisper Large V3** | HuggingFace | 756M | ~14.93% | 仅英文 | 6.3x V3 | 仅英文 | MIT | 可行 |
| **Whisper.cpp** | ggml-org | 同 Whisper | 同 Whisper | 同 Whisper | C++ 优化 | 99+ | MIT | 支持 |
| **Faster-Whisper** | SYSTRAN | 同 Whisper | 同 Whisper | 同 Whisper | 4x Whisper | 99+ | MIT | CPU/GPU |
| **WhisperKit** | Argmax | 同 Whisper | 2.2% (优化后) | - | ANE 优化 | 99+ | MIT | Apple 专属 |
| **Qwen3-ASR-1.7B** | 阿里云 | 1.7B | ~4.50% | ~4.97% | RTF 0.13 | 52 | Apache 2.0 | 可行 (MLX) |
| **Qwen3-ASR-0.6B** | 阿里云 | 0.6B | ~6-8% | ~6-8% | RTF 0.064 | 52 | Apache 2.0 | 已验证 |
| **FireRedASR2-LLM** | 小红书 | ~1B+ | ~9.67%* | 2.89% | - | 中英 | Apache 2.0 | 待验证 |
| **FireRedASR2-AED** | 小红书 | ~1.1B | - | ~3.18% | 高效 | 中英 | Apache 2.0 | 可行 |
| **Canary-Qwen 2.5B** | NVIDIA | 2.5B | 5.63% | - | RTFx 418 | 25 | CC-BY-4.0 | 较难 (大) |
| **Parakeet TDT 1.1B** | NVIDIA | 1.1B | ~1.8% (LS) | 不支持 | RTFx >2000 | 仅英文 | CC-BY-4.0 | CoreML 已支持 |
| **Moonshine Tiny** | Useful Sensors | 27M | ~12.81% | 仅英文 | 5x Whisper tiny | 仅英文 | MIT | 专为边缘设计 |
| **SenseVoice Small** | 阿里(通义) | ~200M | - | 优于 Whisper | 15x Whisper L | 50+ | MIT | 极低延迟 |
| **Fun-ASR-Nano** | 阿里(通义) | - | - | ~4.55% | 实时 | 31 | MIT | 支持 |
| **Granite Speech 3.3** | IBM | ~9B | 5.85% | - | - | 多语言 | Apache 2.0 | 太大 |
| **Apple SpeechAnalyzer** | Apple | 未公开 | 中等 (约Whisper mid) | - | 2.2x MacWhisper L3T | 多语言 | 平台内置 | iOS 26+ |

> *FireRedASR2 的英文指标为 Avg-All-24 混合指标

---

### 2. 重点模型详细分析

#### 2.1 Qwen3-ASR (阿里云) — 2026 年最佳中文开源模型

**发布日期：** 2026 年 1 月 30 日

**模型变体：**
- Qwen3-ASR-1.7B：旗舰版，SOTA 精度
- Qwen3-ASR-0.6B：效率版，最佳精度-效率平衡
- Qwen3-ForcedAligner-0.6B：非自回归对齐模型

**中文性能（关键数据）：**
| 数据集 | Qwen3-ASR-1.7B | GPT-4o-Transcribe | Whisper-L-v3 | Gemini-2.5 |
|--------|----------------|-------------------|--------------|------------|
| WenetSpeech (test_net) | 4.97 CER | 15.30 CER | 6.84 CER | 6.15 CER |
| WenetSpeech (test_meeting) | 5.88 CER | 14.43 CER | 9.86 CER | - |
| AISHELL-2 | 2.71 CER | - | - | 11.62 CER |
| 粤语 (Fleurs-yue) | 3.98 CER | 4.98 CER | - | - |
| 22 种方言混合 | 15.94 CER | 45.37 CER | - | - |
| 极端噪声普通话 | 16.17 CER | - | 63.17 CER | - |

**英文性能：**
| 数据集 | Qwen3-ASR-1.7B | GPT-4o-Transcribe |
|--------|----------------|-------------------|
| LibriSpeech (clean) | 1.63 WER | 1.39 WER |
| LibriSpeech (other) | 3.38 WER | 3.75 WER |
| GigaSpeech | 8.45 WER | 25.50 WER |
| 带口音英语 | 16.07 WER | 28.56 WER |

**推理速度：**
- 0.6B: TTFT 92ms, RTF 0.064 (128 并发), 吞吐量 2000 秒/秒
- 1.7B: RTF 0.13 (128 并发)

**Apple Silicon 部署：**
- 已有 mlx-qwen3-asr 项目和 qwen3-asr-swift 项目
- CoreML 模型可用（ANE 编码器 + MLX 文本解码器）
- M2 Max 上 RTF 0.06 — 比 whisper.cpp 的 Whisper-large-v3 快 40%
- 需要 macOS 14+ / iOS 17+
- 首次下载后完全离线运行

**许可证：** Apache 2.0

**评价：** 在中文（普通话 + 方言）识别上大幅超越 GPT-4o-Transcribe（CER 差距 2-3 倍），英文也有竞争力。0.6B 版本已验证可在 Apple Silicon 上高效运行。**这是 WhisperUtil 最值得考虑集成的中文模型。**

---

#### 2.2 FireRedASR2 (小红书) — 2026 年中文 SOTA

**发布日期：** 2026 年 2 月

**模型变体：**
- FireRedASR2-LLM：最高精度
- FireRedASR2-AED (1.1B)：平衡精度与效率
- FireRedVAD：语音活动检测 (100+ 语言)
- FireRedLID：语言识别 (100+ 语言, 20+ 中文方言)
- FireRedPunc：标点恢复

**中文性能（CER）：**
| 评估维度 | FireRedASR2-LLM | Qwen3-ASR-1.7B | Doubao-ASR | Fun-ASR |
|----------|----------------|----------------|-----------|---------|
| 普通话 (4 集平均) | **2.89%** | 3.76% | 3.69% | 4.16% |
| 方言 (19 集平均) | **11.55%** | 11.85% | 15.39% | 12.76% |
| 综合 (24 集平均) | **9.67%** | - | - | - |

**特色：**
- 唱歌歌词识别表现突出
- 实际应用场景（短视频、直播、字幕、语音输入）相比开源基线和商业方案降低 24-40% CER
- 支持 20+ 中文方言

**许可证：** Apache 2.0

**评价：** 中文普通话识别精度目前开源模型中最高，但生态系统不如 Qwen3-ASR 成熟，Apple Silicon 部署还需验证。

---

#### 2.3 SenseVoice Small (阿里通义) — 极低延迟

**核心优势：**
- 非自回归架构，处理 10 秒音频仅需 70ms
- 比 Whisper-Large 快 15 倍
- 中文和粤语识别有优势
- 支持 50+ 语言 + 语音情感检测 + 音频事件检测

**适用场景：** 对延迟极度敏感的实时应用

**许可证：** MIT

---

#### 2.4 NVIDIA Parakeet TDT — 英文最强

**核心数据：**
- Parakeet TDT 1.1B 在 Open ASR Leaderboard 排名第一
- LibriSpeech WER 约 1.8%
- RTFx >2000（速度极快）
- 通过 FluidAudio SDK 已可在 Apple Neural Engine 运行

**局限：** 仅支持英文

**Apple 生态集成：**
- FluidAudio SDK 已发布 37 个版本，1500 GitHub stars
- VoiceInk、Spokenly 等产品已使用
- CoreML 优化版本可用

---

#### 2.5 WhisperKit (Argmax) — Apple 生态最佳

**核心数据：**
- 优化后的 Large V3 Turbo 在 Neural Engine 上: 2.2% WER, 0.46s 延迟
- 实时流式转写
- 支持 VAD、说话人分离、时间戳

**WWDC 2025 Apple SpeechAnalyzer：**
- Apple 推出 SpeechAnalyzer 框架 (iOS 26+)
- 精度约等于 Whisper 中等模型
- 速度是 MacWhisper Large V3 Turbo 的 2.2 倍
- 完全设备端处理
- 不需要下载额外模型

---

#### 2.6 Moonshine — 极致轻量

**核心数据：**
- Tiny 版本仅 27M 参数
- 比 Whisper Tiny 快 5 倍，精度相当 (~12.81% WER)
- Medium Streaming 版本: 250M 参数，WER 低于 Whisper Large V3
- 专为边缘设备和实时转写设计

**局限：** 仅支持英文

---

### 3. 关键问题回答

#### "2026 年是否有开源模型能匹配 GPT-4o-Transcribe 的质量，特别是中文？"

**回答：是的，而且在中文上已经超越了。**

**中文方面：**
- **Qwen3-ASR-1.7B** 在中文（普通话）上的 CER 为 4.97%，而 GPT-4o-Transcribe 为 15.30%（WenetSpeech test_net），差距高达 3 倍。
- **FireRedASR2-LLM** 更进一步，普通话 CER 降至 2.89%。
- 在方言识别上差距更大：Qwen3-ASR 的 22 方言混合 CER 为 15.94%，GPT-4o 为 45.37%。

**英文方面：**
- GPT-4o-Transcribe 在干净英文读语音上仍然领先（LibriSpeech clean: 1.39% vs Qwen3-ASR 1.63%）
- 但在带口音英语（16.07% vs 28.56%）和 GigaSpeech（8.45% vs 25.50%）等真实场景下，Qwen3-ASR 反而更好

**结论：对于中英双语用户，Qwen3-ASR 已经可以替代 GPT-4o-Transcribe，且在中文上有显著优势。**

---

### 4. WhisperUtil 的技术路线建议

#### 短期（可立即实施）：
1. **集成 Qwen3-ASR-0.6B**：通过 mlx-qwen3-asr 或 CoreML，作为中文优先的本地模型选项
   - M2 Max RTF 0.06，足够实时使用
   - 首次下载后完全离线
   - Apache 2.0 许可证，商业友好

2. **集成 NVIDIA Parakeet TDT**：通过 FluidAudio CoreML SDK，作为英文优先的本地模型选项
   - 英文精度最高
   - 已有成熟的 Apple 生态工具链

#### 中期：
3. **模型自动选择**：根据检测到的语言自动切换模型（中文 -> Qwen3-ASR, 英文 -> Parakeet）
4. **AI 后处理 Pipeline**：添加文本清理、格式化功能，对标 Wispr Flow

#### 长期：
5. **自托管云端服务**：使用 Qwen3-ASR-1.7B 部署云端，提供免费/低成本的转写服务
   - 单 GPU 可处理高并发（2000 秒音频/秒 @ 128 并发）
   - 精度超越 GPT-4o-Transcribe（中文）

---

### 5. 开源模型许可证汇总

| 模型 | 许可证 | 商业使用 |
|------|--------|----------|
| Whisper (全系列) | MIT | 完全自由 |
| WhisperKit | MIT | 完全自由 |
| Qwen3-ASR | Apache 2.0 | 完全自由 |
| FireRedASR2 | Apache 2.0 | 完全自由 |
| SenseVoice | MIT | 完全自由 |
| Fun-ASR / Paraformer | MIT | 完全自由 |
| Parakeet TDT | CC-BY-4.0 | 需署名 |
| Canary-Qwen | CC-BY-4.0 | 需署名 |
| Moonshine | MIT | 完全自由 |
| Granite Speech | Apache 2.0 | 完全自由 |

---

## 附录：数据来源

- [SuperWhisper 官网](https://superwhisper.com/)
- [MacWhisper - Gumroad](https://goodsnooze.gumroad.com/l/macwhisper)
- [VoiceInk GitHub](https://github.com/Beingpax/VoiceInk)
- [Wispr Flow 技术架构](https://wisprflow.ai/post/technical-challenges)
- [Wispr Flow 定价](https://wisprflow.ai/pricing)
- [Voibe 定价](https://www.getvoibe.com/pricing/)
- [OpenWhispr 官网](https://openwhispr.com/)
- [Spokenly 官网](https://spokenly.app/)
- [Buzz GitHub](https://github.com/chidiwilliams/buzz)
- [Qwen3-ASR 技术报告](https://arxiv.org/html/2601.21337v1)
- [Qwen3-ASR GitHub](https://github.com/QwenLM/Qwen3-ASR)
- [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr/)
- [qwen3-asr-swift](https://github.com/ivan-digital/qwen3-asr-swift)
- [FireRedASR2 技术报告](https://arxiv.org/html/2603.10420v1)
- [FireRedASR GitHub](https://github.com/FireRedTeam/FireRedASR)
- [SenseVoice GitHub](https://github.com/FunAudioLLM/SenseVoice)
- [FunASR GitHub](https://github.com/modelscope/FunASR)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- [FluidAudio / Parakeet CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
- [MacParakeet](https://github.com/moona3k/macparakeet)
- [Moonshine](https://github.com/usefulsensors/moonshine)
- [NVIDIA Canary-Qwen](https://huggingface.co/nvidia/canary-qwen-2.5b)
- [Northflank STT 基准测试 2026](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [Apple SpeechAnalyzer / Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)
- [讯飞输入法官网](https://srf.xunfei.cn/)
- [讯飞听见](https://www.iflyrec.com/)
- [Whisper Notes](https://whispernotes.app/)
- [SpeakMac](https://www.speakmac.app/)
- [BetterDictation](https://spokenly.app/comparison/better-dictation)
- [Aqua Voice vs Wispr Flow](https://www.getvoibe.com/resources/aqua-voice-vs-wispr-flow/)
- [Willow Voice 定价](https://willowvoice.com/pricing)
