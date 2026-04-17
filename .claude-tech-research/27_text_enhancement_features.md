# 文本优化功能竞品分析与改进方向

> 调研日期：2026-04-14
> 背景：WhisperUtil 当前文本优化功能仅有 gpt-4o-mini 三种润色模式（自然/正式/口语），功能单薄。本文通过竞品分析，梳理行业最佳实践，提出改进路线。

---

## Part 1: 竞品文本优化功能全景

### 1.1 Wispr Flow — 行业标杆

Wispr Flow 是当前"说话变写作"做得最好的产品，文本后处理是其核心竞争力。

**技术架构：**
- 使用**微调的 Llama 模型**（Meta 开源 LLM）做实时文本清理
- 由 Baseten 提供低延迟推理，使用 TensorRT-LLM 引擎
- 性能目标：E2E ASR < 200ms，E2E LLM < 200ms，网络 < 200ms
- 100+ tokens 在 250ms 内处理完毕
- 同时使用 OpenAI 等商业模型作为补充

**文本处理能力：**

| 功能 | 描述 |
|------|------|
| 填充词移除 | 自动移除 um/uh/like/you know 等 |
| 自我修正处理 | "5pm, no actually 6pm" → "6pm" |
| 口误清理 | 结巴、重复、假启动自动清理 |
| 语法纠正 | 自动修正语法错误 |
| 标点智能添加 | 根据语义自动添加标点 |
| 格式化 | 在 Notion 等应用中智能格式化 |
| 语气匹配 | 根据当前应用自动调整语气（邮件正式、Slack 口语） |
| 代码感知 | 在 VS Code/Cursor 中识别代码语法和变量名 |
| 语音命令 | "make this formal"、"turn into bullets" 等语音编辑指令 |
| 个人词典 | 学习用户词汇（人名、产品名、行业术语） |
| Snippets | 语音快捷短语（"my address" → 自动填入地址） |

**Flow Styles 风格系统：**
- 四个类别：Personal messages / Work messages / Email / Other apps
- 每个类别可独立选择风格：Formal / Casual / Very Casual / Excited
- 控制大小写、标点、间距的格式化方式
- 不改变用户的词汇选择和语法，仅调整格式
- 限制：仅支持英文（US/British）

**上下文感知（Context Awareness）：**
- 自动检测当前应用类型
- 检测邮件中的人名提高识别准确率
- 根据应用类别应用不同的 Style 设置
- 在 Notion 等应用中自动处理格式
- 无需手动切换，全自动适配

**核心启示：** Wispr Flow 的优势不在于提供复杂的配置选项，而在于"零配置的智能适配"。用户不需要选择模式，系统自动根据上下文做最合适的处理。这是与 WhisperUtil 当前"三选一模式"最大的理念差异。

---

### 1.2 VoiceInk — 开源可学习的完整管线

VoiceInk 的文本后处理采用 Pipeline 架构，是开源产品中最完整的实现。

**AI Enhancement Pipeline（完整管线）：**

```
转录完成
  ↓
1. TranscriptionOutputFilter    — 输出过滤（去除无效片段）
  ↓
2. trim whitespace              — 去除首尾空白
  ↓
3. WhisperTextFormatter         — 文本格式化（标点、大小写等）
  ↓
4. WordReplacementService       — 词语替换（用户自定义规则）
  ↓
5. PromptDetectionService       — 检测语音中的 Prompt 触发词
  ↓
6. AIEnhancementService         — AI 增强（可选，需 API Key）
   ├── 收集上下文：屏幕截图 OCR + 剪贴板内容 + 自定义词汇
   ├── 选择 Prompt（Power Mode 自动 或 用户手选）
   ├── 调用 LLM（OpenAI / Anthropic / Gemini / Ollama / 本地 CLI）
   └── AIEnhancementOutputFilter — AI 输出后过滤
  ↓
7. 输出到光标位置
```

**关键功能详解：**

| 功能 | 实现方式 | 说明 |
|------|---------|------|
| 填充词移除 | FillerWordManager，可配置词表 | 规则引擎，零延迟 |
| 词语替换 | WordReplacementService，用户定义规则 | "vs code" → "VS Code" |
| 自定义 Prompt | 支持创建多个 AI 增强 Prompt | 不同场景不同指令 |
| 多 LLM 支持 | OpenAI / Anthropic / Gemini / Ollama | BYOK 模式 |
| 本地 CLI 模式 | v1.73 新增，调用 Claude CLI / Codex | 零 API 费用 |
| 上下文感知 | 屏幕截图 OCR + 剪贴板读取 | 精度不如 Accessibility API |
| Prompt 触发词 | PromptDetectionService | 语音中说特定词触发特定 Prompt |
| 推理配置 | ReasoningConfig | 支持 reasoning model 配置 |

**Power Mode（应用感知核心功能）：**
- **ActiveWindowService**：检测当前活跃窗口应用（NSWorkspace.shared.frontmostApplication）
- **BrowserURLService**：检测浏览器当前 URL
- **Per-App 配置**：每个应用可独立配置转录模式、AI 增强 Prompt、语言
- 支持快捷键直接切换 Power Mode
- 支持配置自动按下 Return/Shift+Return（自动发送消息）

**核心启示：** VoiceInk 的 Pipeline 架构值得学习——把处理拆成独立步骤，每步可配置开关。规则引擎（填充词、词语替换）和 LLM 增强分层处理：简单问题用规则零延迟解决，复杂问题才调 LLM。

---

### 1.3 Superwhisper — 自定义模式最灵活

Superwhisper 的 Custom Modes 是其核心功能，给高级用户最大的自由度。

**Modes 系统：**
- **Dictation Mode**：纯转录，不做 AI 处理
- **Super Mode**：内置 AI 增强（去填充词、修语法、格式化）
- **Custom Mode**：完全自定义 AI 处理指令

**Custom Mode 详解：**
- 用户编写自定义 Prompt 指令
- 支持 XML 标签结构化复杂 Prompt
- 支持添加 Input/Output 示例（Few-shot learning）
- 支持选择不同 AI 模型（GPT / Claude / Llama / 本地模型）
- 上下文信息自动注入到 Prompt 中

**发送给 AI 的完整 Prompt 结构：**
```
1. INSTRUCTIONS（用户自定义指令）
2. EXAMPLES OF CORRECT BEHAVIOR（用户提供的示例）
3. SYSTEM CONTEXT（系统信息）
4. USER INFORMATION（用户信息）
5. APPLICATION CONTEXT（当前应用上下文）
6. USER MESSAGE（语音转录文本）
```

**BYOK（Bring Your Own Key）：**
- 支持 OpenAI / Anthropic / Deepgram / Groq 的 API Key
- v2.0 起支持连接云端模型
- 也支持本地 Ollama

**Model Library（v2026.01）：**
- 可浏览、搜索、对比可用模型
- 收藏常用模型
- 创建自定义模型配置

**核心启示：** Superwhisper 给高级用户最大自由度，但代价是学习曲线陡峭。Few-shot 示例功能是亮点——通过 2-3 个示例显著提升 AI 输出质量。

---

### 1.4 Aqua Voice — 极致速度 + 结构化输出

**核心特点：**
- 自研 Avalon 转录模型，启动延迟 < 50ms，文本插入 < 450ms
- Instant Mode（200ms 启动，450ms 粘贴）和 Streaming Mode
- 使用系统 Accessibility API 做上下文感知（比 VoiceInk 的截屏 OCR 更精确）

**文本增强功能：**

| 功能 | 描述 |
|------|------|
| 自动格式化 | 列表自动格式化、段落结构化 |
| 模板替换 | 减少重复输入（类似 Wispr Snippets） |
| 智能大小写 | 聊天场景自动适配 |
| 标点优化 | 根据上下文智能标点 |
| 自定义词典 | 最多 800 个词/短语 |
| 自然语言风格指令 | 用自然语言描述期望的输出风格 |

**核心启示：** Aqua Voice 证明了"结构化输出"（自动列表、段落）的价值，以及 Accessibility API 做上下文感知的技术路线比截屏 OCR 更优。

---

### 1.5 Willow Voice — 自适应学习

**核心特点：**
- YC 孵化，40%+ 优于系统自带听写
- 自动学习用户说话风格和词汇
- 支持 100+ 语言

**文本增强功能：**
- 自动格式化文本
- 自动修正错误
- 移除填充词
- 忽略口误
- Willow Assistant：AI 文本变换（类似 Wispr 的语音命令）

**核心启示：** "自动学习用户词汇和说话风格"是差异化功能，长期使用后体验越来越好。

---

### 1.6 MacWhisper — 文件转写为主

MacWhisper 主要面向文件转写场景，文本后处理能力有限：
- 有基础的 AI 文本清理功能
- 可以去填充词、修标点
- 但不是实时语音输入工具，后处理不是核心

---

### 1.7 Otter.ai — 企业级会议处理

Otter.ai 面向会议转录场景，文本处理方向不同：

| 功能 | 描述 |
|------|------|
| 自动摘要 | AI 生成会议摘要 |
| Action Items 提取 | 自动识别行动项、分配负责人、设定截止时间 |
| 决策记录 | 提取会议决策 |
| 跨会议智能 | 可查询整个会议历史 |
| MCP Server | 2026 年推出，允许 Claude/ChatGPT 访问会议数据 |

**核心启示：** Otter 的文本处理方向（摘要、Action Items）与 WhisperUtil 的实时输入场景不同，但"结构化提取"的思路可以参考——比如从长段录音中提取要点。

---

## Part 2: 功能矩阵对比

### 2.1 文本优化功能全景矩阵

| 功能 | WhisperUtil | Wispr Flow | VoiceInk | Superwhisper | Aqua Voice | Willow Voice |
|------|:-----------:|:----------:|:--------:|:------------:|:----------:|:------------:|
| **填充词移除** | Prompt 隐含 | 自动 | 规则引擎 | Super Mode | 自动 | 自动 |
| **语法纠正** | 三种模式 | 自动 | AI 增强 | AI 模式 | 自动 | 自动 |
| **标点优化** | Prompt 隐含 | 智能标点 | 格式化器 | AI 模式 | 智能标点 | 自动 |
| **自我修正处理** | 无 | 自动 | 无 | AI 模式 | 无 | 自动 |
| **格式化（列表/段落）** | 无 | 智能格式 | AI 增强 | Custom Mode | 自动列表 | 无 |
| **语气/风格转换** | 三选一 | 按应用自动 | 自定义 Prompt | Custom Mode | 风格指令 | AI 变换 |
| **上下文感知** | 无 | 应用+内容 | 截屏 OCR | 应用信息 | Accessibility | 无 |
| **自定义 Prompt** | 无 | 无（自动） | 多 Prompt | 完全自定义 | 风格指令 | 无 |
| **自定义词汇表** | 无 | 个人词典 | 词语替换 | 无 | 800 词词典 | 自动学习 |
| **多 LLM 支持** | 仅 GPT-4o-mini | 微调 Llama | 多家 LLM | 多家 LLM | 自研模型 | 自研 |
| **本地 AI 处理** | 无 | 无 | Ollama+CLI | 本地模型 | 无 | 无 |
| **语音命令编辑** | 无 | 支持 | 无 | 无 | 无 | Assistant |
| **Few-shot 示例** | 无 | 无 | 无 | 支持 | 无 | 无 |
| **Snippets/模板** | 无 | 支持 | 无 | 无 | 模板替换 | 无 |
| **自动学习词汇** | 无 | 支持 | 实验性 | 无 | 无 | 支持 |

### 2.2 WhisperUtil 的差距分析

**完全缺失的关键功能（红色警报）：**
1. 上下文感知 — 所有主流竞品都有，WhisperUtil 完全没有
2. 自定义词汇表/词语替换 — 简单但高价值
3. 填充词专项移除 — 当前仅靠 Prompt 隐含处理，不够精准
4. 自我修正处理 — "不对，应该是..." 这类口语纠正

**有但不够的功能（黄色警告）：**
1. 风格转换 — 仅三选一，竞品已做到按应用自动切换
2. LLM 选择 — 硬编码 gpt-4o-mini，竞品支持多模型切换
3. Prompt 定制 — 无自定义能力，竞品支持用户自写 Prompt

---

## Part 3: "说话变写作"的技术实现

### 3.1 核心挑战

口语和书面语有本质差异：

| 维度 | 口语特征 | 书面语要求 |
|------|---------|-----------|
| 结构 | 意识流、无规划 | 逻辑清晰、有条理 |
| 填充词 | 大量：嗯、那个、就是说 | 零填充词 |
| 自我修正 | 常见："不是A，是B" | 只保留最终版本 |
| 重复 | 常有重复表达加强语气 | 精简不重复 |
| 句子结构 | 碎片化、不完整 | 完整句子 |
| 标点 | 无（语音无标点） | 精确标点 |
| 语气词 | 大量：吧、啊、呢、吗 | 适度使用 |

### 3.2 Wispr Flow 的方法：微调专用模型

Wispr Flow 的核心技术路线是**在 Llama 基础上微调专用的文本清理模型**：

1. **收集训练数据**：大量"口语转录 → 对应书面语"的配对数据
2. **微调 Llama**：让模型专门学习口语→书面语的转换规则
3. **低延迟推理**：TensorRT-LLM 优化，250ms 内处理 100+ tokens
4. **上下文注入**：将当前应用信息、用户风格偏好作为额外输入

这种方法的优势是**速度极快且风格一致**，劣势是需要大量训练数据和算力。

### 3.3 通用 LLM + Prompt Engineering 方法

对于独立开发者（如 WhisperUtil），更实际的方法是使用通用 LLM + 精心设计的 Prompt。

**基础 Prompt 结构（推荐）：**

```
系统角色定义
  ↓
不变性约束（不翻译、不添加信息、不改变含义）
  ↓
处理规则（按优先级排列）
  ↓
场景特定指令（根据应用/用途动态注入）
  ↓
输出格式要求
  ↓
[可选] Few-shot 示例
```

**改进的 Prompt 模板示例：**

```
你是一个语音转文字后处理助手。将口语化的语音转录转换为自然的书面文本。

严格规则：
1. 保持原语言不翻译。中文输入输出中文，混合语言保持混合。
2. 不添加原文没有的信息。
3. 只输出处理后的文本，不要解释。

处理步骤（按顺序执行）：
1. 移除所有填充词（嗯、那个、就是、然后呢、um、uh、like、you know）
2. 处理自我修正——只保留修正后的版本（"去北京，不对，去上海" → "去上海"）
3. 合并重复表达
4. 修正语法和标点
5. {场景特定指令}

{场景特定指令} 示例：
- 邮件场景："使用正式商务语气，完整句式，适当分段"
- 聊天场景："保持口语化，简洁友好，可用常见缩写"
- 代码注释场景："技术风格，简洁精确，保留所有技术术语原文"
- 笔记场景："要点式，简明扼要，可用短语代替完整句子"
```

### 3.4 不同场景的处理策略

| 场景 | 关键处理 | Prompt 重点 |
|------|---------|------------|
| 邮件 | 正式语气、完整句式、分段 | "Write as a professional email" |
| Slack/微信 | 口语化、简短、轻松 | "Keep casual, use common abbreviations" |
| 代码注释 | 技术术语不动、简洁 | "Technical and concise, preserve all technical terms" |
| 笔记 | 要点式、结构化 | "Format as bullet points, keep concise" |
| 社交媒体 | 有个性、简短 | "Engaging and concise, suitable for social media" |
| 文档写作 | 书面语、逻辑清晰 | "Formal written style, clear logical structure" |

---

## Part 4: 上下文感知技术实现

### 4.1 技术路线对比

| 方法 | 使用者 | 精确度 | 隐私 | 实现难度 |
|------|--------|--------|------|---------|
| NSWorkspace 检测前台应用 | VoiceInk / Wispr | 高（应用级） | 好 | 低 |
| 截屏 + OCR | VoiceInk | 中（依赖OCR质量） | 差（截屏） | 中 |
| Accessibility API 读取文本 | Aqua Voice | 最高（字符级） | 中 | 高 |
| 浏览器 URL 检测 | VoiceInk | 高 | 好 | 中 |
| 剪贴板读取 | VoiceInk | 取决于内容 | 中 | 低 |

### 4.2 VoiceInk Power Mode 实现

VoiceInk 的 Power Mode 技术实现：

1. **ActiveWindowService**：通过 `NSWorkspace.shared.frontmostApplication` 获取当前活跃应用的 Bundle ID 和应用名
2. **BrowserURLService**：通过 AppleScript/JXA 查询 Safari/Chrome 等浏览器的当前 URL
3. **PowerModeSessionManager**：维护"应用 → 配置"的映射表
4. **自动切换逻辑**：录音启动时查询当前应用 → 匹配 Power Mode 配置 → 应用对应的 Prompt/语言/模型设置
5. **上下文注入**：截屏后 OCR 提取屏幕内容，或读取剪贴板，作为 AI 增强的额外上下文

### 4.3 Wispr Flow 上下文感知实现

Wispr Flow 的上下文感知更加"隐式"：

1. **应用检测**：检测当前应用类别（邮件/聊天/编辑器/浏览器）
2. **名字检测**：在邮件应用中，检测收件人名字提高识别准确率
3. **风格自动应用**：根据应用类别自动应用预设的 Flow Style
4. **格式适配**：在 Notion 等应用中自动处理 Markdown 格式
5. **代码感知**：在 IDE 中识别代码语法

**关键区别：** Wispr Flow 不需要用户手动配置每个应用的规则（VoiceInk 需要），而是内置了应用类别的智能判断。对用户来说更简单，但灵活度不如 VoiceInk。

### 4.4 对用户体验的影响

上下文感知对用户体验提升巨大：
- **减少手动切换**：不需要每次切换应用都手动选择模式
- **风格自然匹配**：在邮件中说话自动出正式文本，在聊天中自动出口语
- **错误减少**：在代码编辑器中不会把变量名"修正"成普通单词
- **操作减少**：在消息应用中可配置自动按回车发送

多位用户评测指出，上下文感知是 Wispr Flow 和 VoiceInk 最核心的差异化功能，也是用户选择付费产品的主要原因之一。

---

## Part 5: WhisperUtil 改进建议

### 5.1 优先级矩阵

| 优先级 | 功能 | 实现难度 | 预期收益 | 依赖 |
|:------:|------|:-------:|:-------:|------|
| P0 | 升级 LLM 模型（gpt-4o-mini → nano） | 极低 | 中 | 无 |
| P0 | 填充词规则引擎（预处理层） | 低 | 高 | 无 |
| P0 | 词语替换功能 | 低 | 高 | 设置 UI |
| P1 | 自定义 Prompt 模板 | 中 | 高 | 设置 UI |
| P1 | 自我修正处理（Prompt 优化） | 极低 | 中 | 无 |
| P1 | 多 LLM 支持（模型可配置） | 中 | 中 | 配置系统 |
| P2 | 上下文感知（应用检测） | 中 | 极高 | P1 |
| P2 | Per-App Prompt 配置 | 中 | 高 | P2 上下文感知 |
| P2 | 本地 AI 处理（MLX Swift） | 高 | 中 | 模型管理 |
| P3 | Few-shot 示例支持 | 中 | 中 | P1 |
| P3 | 语音命令编辑 | 高 | 中 | 指令检测 |
| P3 | 自动学习用户词汇 | 高 | 中 | 数据存储 |

### 5.2 P0：立即可做的改进（零成本/极低成本）

#### 5.2.1 升级 LLM 模型

当前 `gpt-4o-mini` 已在退役路径上。建议替换为 `gpt-4.1-nano` 或 `gpt-5-nano`：
- 延迟降低 30-50%
- 成本降低 50-70%
- API 完全兼容，改动仅一行
- 建议将模型名称提取到 `EngineeringOptions` 中，方便后续切换

#### 5.2.2 填充词规则引擎

在调用 LLM 之前，用规则引擎预处理：
- 零延迟、零成本
- 处理明确的填充词：嗯、那个、就是、然后呢、um、uh、like、you know
- 可配置词表，用户可添加/删除
- 参考 VoiceInk 的 `FillerWordManager` 实现

```
转录文本 → [填充词移除] → [LLM 增强] → 输出
```

好处：减少 LLM 需要处理的"噪音"，提高 LLM 输出质量，同时降低 token 消耗。

#### 5.2.3 词语替换功能

用户自定义替换规则表：
- "vs code" → "VS Code"
- "gpt" → "GPT"
- "iphone" → "iPhone"
- 支持正则表达式匹配
- 在 LLM 处理之前执行，提升 LLM 输入质量

#### 5.2.4 改进 Prompt（零代码成本）

当前 Prompt 缺少"自我修正处理"的指令。改进建议：

```
当前 neutral 模式 Prompt：
  "Remove filler words... Fix grammar... Resolve self-corrections..."

建议增强为更明确的指令：
  "处理自我修正——只保留最终修正版本。
   例：'去北京，不对，去上海' → '去上海'
   例：'5pm, no actually 6pm' → '6pm'
   合并重复表达——如果同一意思说了两遍，只保留一次。"
```

在 Prompt 中加入 Few-shot 示例可以显著提升处理质量。

### 5.3 P1：短期改进（1-2 周）

#### 5.3.1 自定义 Prompt 模板

允许用户创建自己的 Prompt 模板，除了内置的 neutral/formal/casual 外，用户可以添加：
- "技术文档"模式
- "社交媒体"模式
- "会议纪要"模式
- 等等

设计要点：
- 提供一个"自定义 Prompt"文本框
- 内置几个模板作为参考
- Prompt 中可使用 `{text}` 占位符
- 存储在 UserDefaults 或 JSON 文件中

#### 5.3.2 多 LLM 模型支持

将模型从硬编码改为可配置：
- 支持选择 OpenAI 的不同模型（nano/mini/standard）
- 长期支持其他 Provider（Claude / Gemini）
- 用户 BYOK 模式——自带其他平台 API Key

参考 VoiceInk 的 LLMkit 抽象层设计。

### 5.4 P2：中期改进（1-2 月）

#### 5.4.1 上下文感知（应用检测）

实现基础的应用感知：

```swift
// 获取当前前台应用
let frontApp = NSWorkspace.shared.frontmostApplication
let bundleId = frontApp?.bundleIdentifier  // e.g. "com.apple.mail"
let appName = frontApp?.localizedName       // e.g. "Mail"
```

建议分两步实现：

**第一步：内置应用类别映射**
```
邮件类：com.apple.mail, com.google.Gmail → formal prompt
聊天类：com.tinyspeck.slackmacgap, com.tencent.xinWeChat → casual prompt
IDE 类：com.microsoft.VSCode, com.cursor.Cursor → technical prompt
默认：neutral prompt
```

**第二步：用户自定义映射**（类似 VoiceInk Power Mode）

#### 5.4.2 本地 AI 处理

通过 mlx-swift-lm 集成本地模型：
- 离线可用，无 API 费用
- 延迟 2-4 秒（比云端慢但可接受）
- 建议作为网络不可用时的 fallback
- 推荐模型：Qwen3-4B-4bit（中英文质量好，约 2.5GB 内存）

### 5.5 整体架构建议：Pipeline 模式

参考 VoiceInk 的 Pipeline 架构，建议将 WhisperUtil 的文本处理重构为管线：

```
转录完成
  ↓
1. [规则层] 填充词移除（零延迟，可配置词表）
  ↓
2. [规则层] 词语替换（零延迟，用户自定义规则）
  ↓
3. [AI 层] LLM 增强（可选，根据模式和上下文选择 Prompt）
   ├── 检测当前应用 → 选择对应 Prompt
   ├── 调用 LLM（云端或本地）
   └── 输出过滤
  ↓
4. 输出到目标位置
```

好处：
- 规则层处理简单问题，零延迟零成本
- AI 层只处理需要"理解"的问题
- 每层可独立开关，用户可选择只要规则处理不要 AI
- 即使 AI 关闭（mode=off），规则层仍然工作

---

## Part 6: 总结

### 6.1 行业趋势

1. **"说话变写作"成为核心卖点**：不再是简单的语音转文字，而是语音直接变成可发送的书面文本
2. **上下文感知成为标配**：根据当前应用自动调整输出风格
3. **规则 + AI 分层处理**：简单问题用规则引擎，复杂问题用 LLM
4. **多 LLM 支持 + BYOK**：不绑定单一 AI 提供商
5. **自定义能力分化**：Wispr Flow 走"零配置智能"路线，Superwhisper 走"完全自定义"路线，两种策略都有市场
6. **自动学习**：产品越用越懂用户的词汇和风格偏好

### 6.2 WhisperUtil 的定位建议

WhisperUtil 作为轻量级菜单栏工具，建议走"**简单默认 + 可深度定制**"路线：

- **默认体验**：开箱即用，内置合理的规则 + Prompt，不需要配置就能有好效果
- **进阶定制**：自定义词汇表、自定义 Prompt、Per-App 配置等给高级用户
- **避免过度复杂**：不需要做到 Superwhisper 那样的完全自定义，保持轻量级的产品特色

### 6.3 实施路线图

```
Phase 1（本周）：
  ✓ 升级模型到 gpt-4.1-nano / gpt-5-nano
  ✓ 改进 Prompt（加入自我修正、Few-shot 示例）

Phase 2（下周）：
  ✓ 添加填充词规则引擎（预处理层）
  ✓ 添加词语替换功能

Phase 3（2-3 周后）：
  ✓ 支持自定义 Prompt 模板
  ✓ 模型可配置（不再硬编码）

Phase 4（1-2 月后）：
  ✓ 应用检测 + 上下文感知
  ✓ Per-App Prompt 自动切换
  ✓ 本地 AI fallback（MLX Swift）
```

---

## 来源

- [Wispr Flow 官网](https://wisprflow.ai/)
- [Wispr Flow 技术架构](https://wisprflow.ai/post/technical-challenges)
- [Wispr Flow × Baseten 案例](https://www.baseten.co/resources/customers/wispr-flow/)
- [Wispr Flow Style 个性化](https://wisprflow.ai/post/personalized-style)
- [Wispr Flow 上下文感知文档](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)
- [Wispr Flow Styles 设置](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)
- [VoiceInk GitHub](https://github.com/Beingpax/VoiceInk)
- [VoiceInk Power Mode 文档](https://tryvoiceink.com/docs/power-mode)
- [VoiceInk Power Mode 切换](https://tryvoiceink.com/docs/switching-power-modes)
- [Superwhisper Custom Mode 文档](https://superwhisper.com/docs/modes/custom)
- [Superwhisper Modes 介绍](https://superwhisper.com/docs/modes/modes)
- [Superwhisper 自定义模式 Prompt 集合](https://github.com/mackid1993/superwhisper-dictation-prompts/)
- [Aqua Voice 官网](https://aquavoice.com/)
- [Willow Voice 官网](https://willowvoice.com/)
- [Willow Voice vs Aqua Voice 对比](https://willowvoice.com/comparison/aquavoice)
- [Otter.ai 官网](https://otter.ai/)
- [Otter.ai 完整指南 2026](https://aitoolsdevpro.com/ai-tools/otter-ai-guide/)
- [AI 听写工具差异化分析](https://afadingthought.substack.com/p/best-ai-dictation-tools-for-mac)
- [MacWhisper vs Superwhisper 对比](https://www.getvoibe.com/resources/macwhisper-vs-superwhisper/)
- [Wispr Flow vs Superwhisper 对比](https://www.getvoibe.com/resources/wispr-flow-vs-superwhisper/)
- [VoiceInk 评测 2026](https://www.getvoibe.com/resources/voiceink-review/)
- [Superwhisper 评测 2026](https://www.getvoibe.com/resources/superwhisper-review/)
- [最佳 Mac 听写应用 2026](https://www.onresonant.com/resources/best-dictation-apps-mac)
- [TechCrunch 最佳 AI 听写应用 2025](https://techcrunch.com/2025/12/30/the-best-ai-powered-dictation-apps-of-2025/)
- [语音转文字自定义词汇指南](https://weesperneonflow.ai/en/blog/2026-03-14-voice-dictation-custom-vocabulary-technical-terminology-guide/)
- [Wispr Flow 评测 - Zack Proser](https://zackproser.com/blog/wisprflow-review)
- [Wispr Flow 评测 - Willow Voice](https://willowvoice.com/blog/wispr-flow-review-voice-dictation)
