# 合并 Constants 至 EngineeringOptions

## Context

当前项目有两个独立的静态配置枚举：`Constants`（技术常量）和 `EngineeringOptions`（工程选项）。两者都是 `caseless enum` + `static let`，职责有重叠感，增加了认知负担。合并后统一为一个配置入口，简化架构。

## 当前状态

- **Constants.swift** — 25 个字段（采样率、超时、URL、音频参数等），被 9 个文件引用
- **EngineeringOptions.swift** — 15 个字段（API key、模型选择、功能开关等），被 6 个文件引用
- 两者无命名冲突，可直接合并

## 合并后的字段分类

按管线数据流顺序重新编排所有 40 个字段（`[E]` = 原 EngineeringOptions，`[C]` = 原 Constants）：

### MARK: - API & Auth
| 字段 | 来源 |
|------|------|
| apiKey | [E] |
| whisperTranscribeURL | [C] |
| whisperTranslateURL | [C] |
| chatCompletionsURL | [C] |
| realtimeWebSocketURL | [C] |

### MARK: - Audio capture
| 字段 | 来源 |
|------|------|
| sampleRate | [C] |
| realtimeSampleRate | [C] |
| enableSilenceDetection | [E] |
| minVoiceThreshold | [C] |
| minAudioDuration | [C] |
| minAudioDataSize | [C] |
| maxRecordingDuration | [E] |

### MARK: - Audio encoding
| 字段 | 来源 |
|------|------|
| enableAudioCompression | [E] |
| aacBitRate | [C] |
| aacFramesPerPacket | [C] |

### MARK: - Transcription models
| 字段 | 来源 |
|------|------|
| whisperModel | [E] |
| localWhisperModel | [E] |
| realtimeDeltaMode | [E] |

### MARK: - Network
| 字段 | 来源 |
|------|------|
| apiProcessingTimeoutMin | [C] |
| apiProcessingTimeoutMax | [C] |
| realtimeResultTimeout | [C] |
| enableCloudFallback | [E] |
| cloudProbeInterval | [C] |

### MARK: - Post-processing
| 字段 | 来源 |
|------|------|
| enableTraditionalToSimplified | [E] |
| enableTagFiltering | [E] |

### MARK: - Translation
| 字段 | 来源 |
|------|------|
| translationMethod | [E] |
| translationSourceLanguageFallback | [E] |

### MARK: - Text output
| 字段 | 来源 |
|------|------|
| inputMethod | [E] |
| typingDelay | [E] |
| clipboardPasteDelay | [C] |
| clipboardRestoreDelay | [C] |
| autoSendDelay | [C] |

### MARK: - Hotkey
| 字段 | 来源 |
|------|------|
| optionHoldThreshold | [C] |
| doubleTapWindow | [C] |

### MARK: - Internal timing
| 字段 | 来源 |
|------|------|
| checkTimerInterval | [C] |
| errorRecoveryDelay | [C] |

## 执行步骤

### Step 1: 重写 EngineeringOptions.swift
按上述分类重新组织所有 40 个字段，保留原有注释。

### Step 2: 全局替换引用
将 9 个文件中的 `Constants.xxx` 替换为 `EngineeringOptions.xxx`：
- Services/ServiceCloudOpenAI.swift
- Services/ServiceRealtimeOpenAI.swift
- Services/ServiceTextCleanup.swift
- RecordingController.swift
- Audio/AudioRecorder.swift
- Audio/AudioEncoder.swift
- Utilities/TextInputter.swift
- Utilities/NetworkHealthMonitor.swift
- HotkeyManager.swift

### Step 3: 删除 Constants.swift
- 删除 `Config/Constants.swift` 文件
- 从 `project.pbxproj` 中移除引用

### Step 4: 更新模板文件
更新 `Config/EngineeringOptions.swift.template`，同步新的分类结构。

### Step 5: 更新文档
- `CODEBASE_INDEX.md` — 删除 Constants.swift 条目，更新 EngineeringOptions 描述

## 验证

```bash
make build   # 编译通过
make dev     # 编译 + 启动，功能正常
grep -r "Constants\." *.swift **/*.swift  # 确认无残留引用
```
