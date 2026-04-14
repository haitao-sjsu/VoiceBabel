# 音频压缩技术研究报告

## 摘要

本报告研究了音频压缩技术在语音识别场景下的应用，重点分析了 WhisperUtil 项目当前采用的 AAC 16kHz 24kbps M4A 压缩方案。核心发现：(1) 当前方案在 macOS 平台上是合理且实用的选择，AAC 24kbps 已接近语音场景的最低推荐比特率；(2) Opus 编解码器在低比特率语音压缩方面性能优于 AAC，但 Apple AVFoundation 不原生支持 Opus 编码，引入需要第三方库；(3) Whisper API 内部会将所有音频重采样为 16kHz，因此项目的采样率选择完全正确；(4) 当前方案的压缩比和上传延迟已经很好地平衡了质量与效率，建议维持现状，仅在遇到瓶颈时考虑调整比特率到 32kbps。

## 详细报告

### 1. 音频压缩基本原理

#### 1.1 有损压缩 vs 无损压缩

**无损压缩（Lossless）** 恢复后的 PCM 数据与原始数据完全一致，典型格式包括 FLAC 和 ALAC。压缩比通常在 2:1 ~ 3:1 之间，通过消除数据冗余（如相邻采样值的相似性）来减小体积。

**有损压缩（Lossy）** 恢复后的数据与原始数据存在差异，但这些差异在人耳感知上不可察觉（或可接受）。压缩比可达 10:1 甚至更高。典型格式包括 AAC、MP3、Opus。有损压缩利用了人类听觉的心理声学特性，去除人耳不敏感的信息。

#### 1.2 时域压缩 vs 频域压缩

**时域（Time Domain）**：原始 PCM 音频是时域信号，表示振幅随时间的变化。时域压缩直接处理采样值序列，方法包括差分编码（DPCM）、线性预测编码（LPC）等。SILK（Opus 的语音子编码器）就使用了线性预测技术。

**频域（Frequency Domain）**：通过变换（如 MDCT，修正离散余弦变换）将时域信号转换为频率分量。频域压缩根据人耳对不同频率的敏感度，优先保留重要频率、丢弃不重要的频率分量。大多数现代有损编解码器（AAC、MP3、Opus 的 CELT 部分）都使用频域压缩。

**心理声学模型**：有损压缩的核心。利用以下原理减少数据量：
- **绝对听觉阈值**：人耳对极低和极高频率不敏感，这些成分可以丢弃
- **频率掩蔽**：强信号会掩盖附近频率的弱信号
- **时间掩蔽**：强信号前后短时间内的弱信号不可感知

### 2. 关键参数解析

#### 2.1 采样率（Sample Rate）

| 采样率 | 频率范围 | 典型用途 |
|--------|----------|----------|
| 8 kHz | 0-4 kHz | 电话语音 |
| 16 kHz | 0-8 kHz | 宽带语音、语音识别（Whisper） |
| 24 kHz | 0-12 kHz | OpenAI Realtime API |
| 44.1 kHz | 0-22.05 kHz | CD 音质、音乐 |
| 48 kHz | 0-24 kHz | 专业音频、视频 |

**对文件大小的影响**：采样率直接成比例影响文件大小。16kHz 的数据量是 48kHz 的 1/3。

**对语音识别的影响**：Whisper 模型训练时使用 16kHz 采样率，API 会自动将所有输入重采样到 16kHz。因此，使用高于 16kHz 的采样率录制只会增加文件大小和上传时间，不会提升识别效果。

#### 2.2 比特率（Bit Rate）

| 比特率 | AAC 语音质量 | Opus 语音质量 | 适用场景 |
|--------|-------------|--------------|----------|
| 16 kbps | 很差 | 清晰可懂 | Opus 低带宽通话 |
| 24 kbps | 可接受（最低推荐） | 优秀 | 语音转写 |
| 32 kbps | 良好 | 优秀 | 语音转写（推荐） |
| 64 kbps | 优秀 | 透明 | 高质量语音 |
| 128 kbps | 透明 | 透明 | 音乐 |

**对文件大小的影响**：比特率直接决定每秒音频的数据量。24kbps 表示每秒 3KB，1 分钟录音约 180KB。

**对识别准确率的影响**：根据社区测试，Whisper 在 32kbps 以上的 AAC 音频上表现稳定，24kbps 仍可接受但已接近下限。低于此值可能引入编码伪影，影响转写准确率。

#### 2.3 声道数（Channels）

语音识别场景应始终使用单声道（Mono）。立体声（Stereo）会使文件大小翻倍，但对转写零收益。Whisper 在处理时也会将立体声混合为单声道。

#### 2.4 位深度（Bit Depth）

| 位深度 | 动态范围 | 用途 |
|--------|----------|------|
| 16-bit | 96 dB | CD 音质，语音足够 |
| 24-bit | 144 dB | 专业录音 |
| 32-bit float | ~1500 dB | 内部处理（如项目的 Float32 缓冲区） |

语音场景下 16-bit 完全足够。项目内部使用 Float32 处理（方便计算），最终编码时由 AAC 编码器决定量化精度。

### 3. 常见格式比较

| 格式 | 类型 | 容器 | 比特率范围 | 延迟 | 语音质量（32kbps） | Whisper 支持 | 平台兼容性 |
|------|------|------|-----------|------|-------------------|-------------|-----------|
| AAC-LC | 有损 | M4A/MP4 | 16-320 kbps | 中 | 良好 | 支持（m4a） | 极广（Apple 原生） |
| HE-AAC v1 | 有损 | M4A/MP4 | 16-80 kbps | 中 | 良好+ | 支持（m4a） | 广泛 |
| HE-AAC v2 | 有损 | M4A/MP4 | 16-48 kbps | 中 | 良好（仅立体声有效） | 支持（m4a） | 广泛 |
| Opus | 有损 | OGG/WebM | 6-510 kbps | 极低 | 优秀 | 不直接支持* | 需第三方库（macOS） |
| MP3 | 有损 | MP3 | 32-320 kbps | 中 | 一般 | 支持 | 极广 |
| FLAC | 无损 | FLAC | ~500-1000 kbps | 低 | 完美 | 支持 | 广泛 |
| WAV | 无压缩 | WAV | ~256 kbps（16-bit 16kHz） | 无 | 完美 | 支持 | 极广 |
| OGG Vorbis | 有损 | OGG | 32-500 kbps | 中 | 良好 | 支持（ogg） | 广泛 |

*注：OpenAI Whisper API 支持 ogg 容器但不直接支持 .opus 扩展名。

**文件大小估算（1 分钟 16kHz 单声道语音）**：

| 格式 | 配置 | 估算大小 |
|------|------|---------|
| WAV 16-bit | 无压缩 | ~1.92 MB |
| FLAC | 无损压缩 | ~0.8-1.2 MB |
| AAC 64kbps | M4A | ~480 KB |
| AAC 32kbps | M4A | ~240 KB |
| AAC 24kbps | M4A | ~180 KB |
| Opus 24kbps | OGG | ~180 KB |
| Opus 16kbps | OGG | ~120 KB |

### 4. 语音场景最佳实践

#### 4.1 语音 vs 音乐场景的关键区别

| 特征 | 语音 | 音乐 |
|------|------|------|
| 频率范围 | 85 Hz - 8 kHz（足够） | 20 Hz - 20 kHz |
| 动态范围 | 较小 | 很大 |
| 所需采样率 | 16 kHz 足够 | 44.1/48 kHz |
| 所需比特率 | 24-64 kbps | 128-320 kbps |
| 声道需求 | 单声道 | 立体声 |
| 编码优化方向 | 语音模型（LPC 等） | 频谱保真度 |

#### 4.2 语音转写场景的推荐配置

**最佳平衡（推荐）**：
- 采样率：16 kHz
- 声道：单声道
- 格式：AAC (M4A) 或 Opus (OGG)
- 比特率：32 kbps
- 理由：32kbps 是多项测试中语音质量不受明显影响的安全线

**最小体积（激进）**：
- 采样率：16 kHz
- 声道：单声道
- 格式：Opus (OGG)
- 比特率：16 kbps
- 理由：Opus 在 16kbps 下语音仍清晰可懂，但需要引入第三方库

**最大兼容性（保守）**：
- 采样率：16 kHz
- 声道：单声道
- 格式：WAV 16-bit
- 比特率：256 kbps（无压缩）
- 理由：零编码开销，零质量损失，适合本地处理

### 5. 项目当前方案分析

#### 5.1 当前配置

```
格式：M4A（AAC-LC 编码）
采样率：16 kHz
比特率：24 kbps
声道：单声道
位深度：由 AAC 编码器决定
回退方案：WAV 16-bit（AAC 编码失败时）
```

#### 5.2 优点

1. **采样率选择正确**：16kHz 精确匹配 Whisper 模型要求，没有浪费带宽
2. **单声道正确**：语音转写不需要立体声
3. **AAC 格式兼容性好**：macOS AVFoundation 原生支持编码，Whisper API 支持 M4A 格式
4. **压缩比优秀**：相比 WAV，AAC 24kbps 可将文件缩小约 10:1
5. **有 WAV 回退**：编码失败时仍能正常工作，提高了可靠性
6. **工程选项可控**：通过 `EngineeringOptions.enableAudioCompression` 可关闭压缩
7. **代码结构清晰**：AudioEncoder 作为无状态工具类，职责单一

#### 5.3 潜在风险与不足

1. **24kbps 偏激进**：处于 AAC 语音编码的最低推荐值。在某些复杂语音场景下（多人说话、背景噪音、非英语语言），可能引入足以影响转写的编码伪影
2. **无法使用 Opus**：受限于 AVFoundation 不支持 Opus 编码。Opus 在同等比特率下语音质量明显优于 AAC
3. **临时文件 I/O**：AVAudioFile 必须写入磁盘临时文件，无法纯内存操作，增加了一次磁盘写入 + 读取
4. **采样拷贝效率**：`encodeToM4A` 中逐个元素拷贝到 PCM buffer，可以用 `memcpy` / `UnsafeMutablePointer` 优化

#### 5.4 压缩效果估算

| 录音时长 | WAV 大小 | AAC 24kbps 大小 | 压缩比 |
|----------|----------|----------------|--------|
| 5 秒 | 160 KB | ~15 KB | ~10:1 |
| 30 秒 | 960 KB | ~90 KB | ~10:1 |
| 1 分钟 | 1.92 MB | ~180 KB | ~10:1 |
| 5 分钟 | 9.6 MB | ~900 KB | ~10:1 |

### 6. 优化建议

#### 6.1 短期建议（低成本、低风险）

**建议 A：将比特率从 24kbps 提升到 32kbps**
- 改动：仅修改 `Constants.aacBitRate` 从 24000 到 32000
- 效果：文件大小增加约 33%（每分钟从 ~180KB 到 ~240KB），但仍远小于 WAV
- 收益：更安全的编码质量余量，减少极端场景下编码伪影影响转写的风险
- 代价：几乎可忽略。多出的 ~60KB/分钟 对上传延迟影响微乎其微

**建议 B：优化采样数据拷贝**
- 改动：将 for 循环拷贝替换为 `memcpy` 操作
- 收益：减少 CPU 开销，对长录音更明显

```swift
// 当前实现（逐元素拷贝）
for (index, sample) in samples.enumerated() {
    channelData[index] = sample
}

// 优化实现（批量拷贝）
samples.withUnsafeBufferPointer { srcPtr in
    channelData.update(from: srcPtr.baseAddress!, count: samples.count)
}
```

#### 6.2 中期建议（需要评估）

**建议 C：探索 HE-AAC v1**
- HE-AAC (High Efficiency AAC) 在低比特率下比 AAC-LC 表现更好
- macOS AVFoundation 支持 HE-AAC 编码（`kAudioFormatMPEG4AAC_HE`）
- 在 24kbps 下，HE-AAC 的语音质量应优于 AAC-LC
- 需要测试 Whisper API 对 HE-AAC 编码的 M4A 文件是否正常处理

**建议 D：根据录音时长动态调整比特率**
- 短录音（<30秒）：使用较高比特率（48-64kbps），因为总大小仍然很小
- 长录音（>2分钟）：使用较低比特率（24-32kbps），控制总大小

#### 6.3 长期建议（高成本）

**建议 E：引入 Opus 编码**
- 通过 [swift-opus](https://github.com/alta/swift-opus) 等第三方库实现
- Opus 在 16-24kbps 下语音质量远超 AAC
- 但需要额外依赖，增加维护成本
- 且 Whisper API 对 Opus 格式支持不完善（需封装在 OGG 容器中）
- 除非项目对极低带宽环境有强需求，否则 ROI 较低

#### 6.4 不建议的改动

- **不建议提高采样率**：Whisper 内部使用 16kHz，提高采样率只增加体积
- **不建议使用 MP3**：在同等比特率下 AAC 质量优于 MP3，且 MP3 编码在 AVFoundation 中支持不如 AAC
- **不建议移除 WAV 回退**：保留作为安全网，代码成本极低

### 7. 总结

项目当前的 AAC 16kHz 24kbps M4A 方案是一个在 macOS 平台上合理且实用的选择。它利用了系统原生编码能力，避免了第三方依赖，压缩效率约 10:1，显著减少了上传数据量。最值得考虑的改进是将比特率微调到 32kbps，以获得更好的质量安全余量，而代价几乎可忽略不计。更激进的优化（如引入 Opus）需要权衡额外的工程复杂度，当前阶段性价比不高。

## 来源 (Sources)

- [Optimal Audio Input Settings for OpenAI Whisper Speech-to-Text](https://gist.github.com/danielrosehill/06fb17e7462980f99efa9fdab2335a14) -- Whisper API 音频输入最佳实践总结
- [Optimise OpenAI Whisper API: Audio Format, Sampling Rate and Quality](https://dev.to/mxro/optimise-openai-whisper-api-audio-format-sampling-rate-and-quality-29fj) -- Whisper API 格式/采样率/质量优化实测
- [What minimum bitrate should I use for whisper?](https://community.openai.com/t/what-minimum-bitrate-should-i-use-for-whisper/178210) -- OpenAI 社区关于 Whisper 最低比特率的讨论
- [Optimal sample rate for input audio? (openai/whisper #870)](https://github.com/openai/whisper/discussions/870) -- Whisper 采样率讨论，确认内部使用 16kHz
- [Which audio file format is best? (openai/whisper #41)](https://github.com/openai/whisper/discussions/41) -- Whisper 格式选择讨论
- [Opus vs AAC: Which Audio Format is Best for You in 2026?](https://www.hitpaw.com/other-audio-formats-tips/opus-vs-aac.html) -- Opus 与 AAC 全面比较
- [AAC vs Opus Compared: Quality Tests, Latency & Best Use Cases (2026)](https://vibbit.ai/blog/aac-vs-opus-audio) -- AAC 与 Opus 在不同比特率下的质量测试
- [Comparison - Opus Codec (Official)](https://opus-codec.org/comparison/) -- Opus 官方性能比较数据
- [Lossy audio compression: principles, methods, misconceptions](https://www.tonestack.net/articles/digital-audio-compression/lossy-audio-compression-primer.html) -- 有损压缩原理详解
- [The Principles of Audio Compression Technology: Algorithms and Formats](https://www.ampvortex.com/the-principles-of-audio-compression-technology-algorithms-and-formats/) -- 压缩算法与格式原理
- [Why The Audio Compression Format Impacts the Speech to Text Transcription Accuracy](https://medium.com/ibm-watson-speech-services/why-the-audio-compression-format-impacts-the-speech-to-text-transcription-accuracy-84da6438024c) -- 压缩格式对语音转写准确率的影响分析
- [Support for opus file format - OpenAI Developer Community](https://community.openai.com/t/support-for-opus-file-format/1127125) -- Whisper API 对 Opus 格式支持现状
- [Working with the Opus Audio Codec in Swift](https://nickarner.com/notes/working-with-the-opus-audio-codec-in-swift---august-26-2024/) -- 在 Swift 中使用 Opus 编解码器
- [swift-opus (GitHub)](https://github.com/alta/swift-opus) -- Swift Opus 编解码库
- [Create transcription - OpenAI API Reference](https://platform.openai.com/docs/api-reference/audio/createTranscription) -- Whisper API 官方文档
