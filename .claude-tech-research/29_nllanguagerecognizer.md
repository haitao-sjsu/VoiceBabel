# NLLanguageRecognizer 技术研究

## 概述

| 项目 | 内容 |
|------|------|
| **框架** | NaturalLanguage (`import NaturalLanguage`) |
| **引入版本** | iOS 12.0 / macOS 10.14 (WWDC 2018 Session 713) |
| **功能** | 识别文本的主要语言，返回概率分布 |
| **运行方式** | 完全设备端推理，无网络调用 |
| **替代** | 取代已废弃的 `NSLinguisticTagger.dominantLanguage`（iOS 14.0 废弃） |

## API 全貌

### 核心类：NLLanguageRecognizer

```swift
class NLLanguageRecognizer: NSObject {
    // 初始化
    init()

    // 输入文本进行分析（必须在读取结果前调用）
    func processString(_ string: String)

    // 最可能的语言，无法判断时返回 nil
    var dominantLanguage: NLLanguage? { get }

    // 返回最多 maximum 个候选语言及概率（0.0...1.0）
    func languageHypotheses(withMaximum maximum: Int) -> [NLLanguage: Double]

    // 贝叶斯先验概率，在 processString 前设置，偏向指定语言
    var languageHints: [NLLanguage: Double] { get set }

    // 限制候选语言范围
    var languageConstraints: [NLLanguage] { get set }

    // 清除状态（复用实例前必须调用）
    func reset()

    // 便利类方法：一次性识别
    class func dominantLanguage(for string: String) -> NLLanguage?
}
```

### NLLanguage 类型

`NLLanguage` 是 struct（非 enum），rawValue 为 BCP-47 语言标签。预定义 58 种语言常量，关键几个：

| 常量 | rawValue |
|------|----------|
| `.simplifiedChinese` | "zh-Hans" |
| `.traditionalChinese` | "zh-Hant" |
| `.english` | "en" |
| `.japanese` | "ja" |
| `.korean` | "ko" |
| `.undetermined` | "und" |

中文按**字形**（简/繁）区分，非方言。

## 内部工作原理

Apple 未公开模型架构，根据 WWDC 和社区分析推断：

- 基于**字符 n-gram 统计模型**（经典语言识别方法）
- 处理的是字符级特征，非词级——能处理未知词，但对共享字符集的语言（如 CJK）区分困难
- 概率输出表明是真正的统计模型（非启发式规则）
- `languageHints` 作为贝叶斯先验与模型似然合并

## 实测结果（本机 macOS 15）

### 测试 1：dominantLanguage + hypotheses

| 文本 | dominant | Top hypotheses |
|------|----------|----------------|
| 为什么在初始化的时候只需要初始化那个cloud open ai service，不需要初始化那个local apple translation service? | **en** | en: 0.5773, da: 0.0589, nl: 0.0501, pt: 0.0462, nb: 0.0342 |
| 想给你介绍一下这个translation result三个字段它的用途。 | **zh-Hans** | zh-Hans: 1.0000 |
| 这是一段纯中文文本，没有任何英文内容。 | **zh-Hans** | zh-Hans: 0.9994, ja: 0.0006 |
| This is pure English text with no Chinese at all. | **en** | en: 0.9929, nb: 0.0018 |
| 我今天用了ChatGPT和Claude来写代码，效果不错。 | **zh-Hans** | zh-Hans: 0.9992 |

**关键发现**：案例 1 中文字符占 35%，但 hypotheses 中完全没有中文候选——被 100% 误判为英文。

### 测试 2：languageHints 效果

对案例 1 设置 `languageHints = [.simplifiedChinese: 0.5, .english: 0.3]`：

| 配置 | dominant | en 概率 |
|------|----------|---------|
| 无 hints | en | 0.5773 |
| zh:0.5, en:0.3 | **en** | **1.0000** |
| zh:0.8, en:0.2 | **en** | **1.0000** |

**结论：hints 无效，甚至使结果更差**——概率坍缩到 en: 1.0，其他全部归零。

### 测试 3：languageConstraints 效果

对案例 1 设置 `languageConstraints = [.simplifiedChinese, .english]`：

| 配置 | dominant | hypotheses |
|------|----------|------------|
| 无约束 | en | en: 0.5773 |
| 约束 [zh-Hans, en] | **en** | en: 1.0000（且仍返回 cs, da, de 等不在约束中的语言，概率为 0） |
| 约束 + 强 zh hint(0.9) | **en** | en: 1.0000 |

**结论：constraints 对中英混杂无效**，且行为可能有 bug（返回约束外的语言）。

## 已知局限性

### 1. 中英混杂文本（本项目核心问题）

NLLanguageRecognizer 对包含长英文短语的中文文本**系统性误判**：

- 短英文词嵌入中文（"ChatGPT"、"Claude"）→ 识别正确（zh-Hans）
- 长英文短语嵌入中文（"cloud open ai service"、"local apple translation service"）→ **误判为英文**
- 推测原因：字符 n-gram 模型中，连续 ASCII 字符序列产生的英文特征权重过大，压倒了中文字符特征
- hints 和 constraints 均无法修正

### 2. 短文本

- 单字/极短文本不可靠。"OK好的" → 识别为波兰语 (pl: 0.18)
- 单个汉字 "好" → zh-Hant (0.565) 而非 zh-Hans (0.411)
- Apple 文档建议：文本越长，识别越准确

### 3. 近似语言混淆

- 挪威语 Bokmal vs 丹麦语（56% vs 43%）——字符分布太相似
- 波斯语被误判为阿拉伯语或乌尔都语

### 4. 性能

社区基准测试（RTLLanguageDetection）发现 `CFStringTokenizerCopyBestStringLanguage`（iOS 3.0+）在 RTL 语言检测上比 NLLanguageRecognizer 更快更准。

## 替代方案：NLTagger 逐词语言识别

NLTagger 的 `.language` tag scheme 可以做**逐 token 语言标注**：

```swift
let tagger = NLTagger(tagSchemes: [.language])
tagger.string = "今天的meeting很重要discuss进度"
tagger.enumerateTags(
    in: text.startIndex..<text.endIndex,
    unit: .word, scheme: .language,
    options: [.omitWhitespace, .omitPunctuation]
) { tag, range in
    print("\(String(text[range])): \(tag?.rawValue ?? "?")")
    return true
}
```

之前的 agent 研究显示逐词检测结果是准确的：

```
"今天"   -> zh-Hans
"的"     -> zh-Hans
"meeting" -> en
"很"     -> zh-Hans
"重要"   -> zh-Hans
"discuss" -> en
"进度"   -> zh-Hans
```

**注意**：社区有报告称 NLTagger 可能将文档主语言赋给所有 token 而非真正逐词区分，可靠性因场景而异。句子级（`.sentence`）比词级（`.word`）更可靠。

## 对 WhisperUtil 的影响

### 当前问题

`LocalAppleTranslationService.detectSourceLanguage()` 使用 `NLLanguageRecognizer.dominantLanguage`，对中英混杂文本返回 `en`，导致：
1. 预检查判定 en→en 不支持
2. Apple Translation 被跳过，fallback 到 Cloud GPT

### 可选修复方向

| 方案 | 描述 | 优点 | 缺点 |
|------|------|------|------|
| **A. 去掉预检测** | 传 `source: nil` 给 TranslationSession，让 Apple 自己检测 | 最简单；Apple 内部检测可能更好 | 语言包缺失时可能挂起（已有 60s 超时兜底） |
| **B. 字符级 CJK 检测** | 检测到 CJK Unicode 字符 → 返回 zh-Hans | 简单可靠；O(n) 扫描 | 不区分中/日/韩；仅适用于已知用户是中文的场景 |
| **C. NLTagger 逐词统计** | 用 NLTagger 逐词标注，按字符数统计各语言占比 | 更精确；能区分中/日 | 实现复杂；NLTagger 自身可靠性有争议 |
| **D. 混合策略** | 先用 NLLanguageRecognizer，confidence 低于阈值时用字符级检测兜底 | 兼顾准确性和简单性 | hypotheses 中可能完全没有中文候选（如案例 1），阈值难选 |

## 参考资料

- [NLLanguageRecognizer - Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer)
- [NLLanguage - Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nllanguage)
- [NLTagger - Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nltagger)
- [NLLanguageRecognizer - NSHipster](https://nshipster.com/nllanguagerecognizer/)
- [WWDC 2018 Session 713 - Introducing Natural Language Framework](https://developer.apple.com/videos/play/wwdc2018/713/)
- [Language Identification on iOS - Stefan Blos](https://stefanblos.com/posts/language-identification-on-ios/)
- [RTLLanguageDetection Benchmark - GitHub](https://github.com/Akhrameev/RTLLanguageDetection)
