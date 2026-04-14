# 商业翻译 API 调研

日期：2026-04-14

## 摘要

本文调研了主流商业翻译 API 服务，涵盖国际和国内共 10+ 个平台，从语言覆盖、翻译质量、定价、特色功能、API 限制等维度进行全面对比。同时分析了 LLM 翻译 vs 传统 NMT 翻译的趋势变化，并结合 WhisperUtil 项目当前架构（gpt-4o-transcribe + gpt-4o-mini 两步法）给出优化建议。

核心结论：对于 WhisperUtil 的中英/日英翻译场景，当前 gpt-4o-mini 两步法已是接近最优的方案。LLM 翻译在亚洲语言上的质量已超越传统 NMT 引擎（DeepL、Google Translate），且无需引入额外服务商依赖。若需进一步优化，可考虑升级到 gpt-4o 获得更高质量，或引入 DeepL 作为欧洲语言翻译的补充选项。

---

## Part 1：主要商业翻译 API 全面对比

### 1.1 国际服务

#### DeepL API

| 项目 | 详情 |
|------|------|
| **语言数** | ~33 种基础语言（含变体约 143 种目标语言） |
| **定价** | Free: 50 万字符/月免费；Pro: $5.49/月底费 + $25/百万字符 |
| **免费额度** | 50 万字符/月（Free 计划） |
| **特色功能** | 术语表(Glossary)、正式/非正式语气控制、文档翻译(docx/pptx/pdf)、语言检测 |
| **API 限制** | Free 计划有并发限制；Pro 无硬性字符上限但有速率限制(HTTP 429) |
| **延迟** | 中等，比 NMT 引擎稍慢但远快于 LLM |
| **优势** | 欧洲语言翻译质量公认第一；编辑距离最短（盲测中比 Google 少 2x 编辑，比 ChatGPT 少 3x） |
| **劣势** | 语言覆盖有限（~33 种）；亚洲语言（中日韩）质量不如 LLM；无批量折扣 |

#### Google Cloud Translation (v3 / Advanced)

| 项目 | 详情 |
|------|------|
| **语言数** | 249+ 种语言和方言（NMT 覆盖 135+） |
| **定价** | Basic/Advanced NMT: $20/百万字符；LLM Translation: $10 输入 + $10 输出/百万字符；文档翻译: $0.08/页 |
| **免费额度** | 50 万字符/月（无期限） |
| **特色功能** | AutoML 自定义模型、术语表(Glossary)、批量翻译、文档翻译(PDF/DOCX/PPT)、自适应翻译、LLM 翻译模式 |
| **API 限制** | 默认配额较宽松，可申请提升 |
| **延迟** | NMT 最快（毫秒级，比 LLM 快约 20x）；LLM 模式较慢 |
| **优势** | 语言覆盖最广；NMT 速度极快；AutoML 可训练领域模型；新增 LLM 翻译模式 |
| **劣势** | NMT 翻译质量在盲测中排名偏低（4.49/5）；波动性最高 |

#### Microsoft Azure Translator

| 项目 | 详情 |
|------|------|
| **语言数** | 100+ 种语言 |
| **定价** | 标准: $10/百万字符；自定义翻译: $40/百万字符；模型训练: $10/百万字符（上限 $300/次） |
| **免费额度** | 200 万字符/月（F0 层级） |
| **特色功能** | Custom Translator（自定义模型，无需 ML 专业知识）、文档翻译、语言检测、与 Azure 生态深度集成 |
| **API 限制** | 单次请求 50,000 字符上限；免费层有更严格的限制 |
| **延迟** | 快（与 Google NMT 同级） |
| **优势** | 标准翻译定价最低（$10/M）；免费额度最大（200 万/月）；Azure 生态集成好；量大可谈折扣至 $8.22/M |
| **劣势** | 翻译质量中等；自定义模型价格较高 |

#### Amazon Translate

| 项目 | 详情 |
|------|------|
| **语言数** | 75 种语言 |
| **定价** | $15/百万字符（实时和批量相同） |
| **免费额度** | 200 万字符/月（前 12 个月） |
| **特色功能** | 自定义术语表（免费，每文件 10,000 术语）、批量文档翻译(docx/pptx/xlsx/txt/html/xliff)、Active Custom Translation |
| **API 限制** | 标准 AWS 配额管理 |
| **延迟** | 最快（平均约 50ms） |
| **优势** | 速度最快；术语表免费；AWS 生态集成；批量翻译格式支持丰富 |
| **劣势** | 语言覆盖较少（75 种）；复杂句子质量下降；免费期仅 12 个月 |

#### Naver Papago

| 项目 | 详情 |
|------|------|
| **语言数** | 29 种语言对（以韩语为中心） |
| **定价** | 按百万字符计费（具体价格需在 NAVER Cloud Platform 控制台查看） |
| **免费额度** | 需咨询 |
| **特色功能** | 术语表、敬语翻译、术语替换、图片翻译、网站翻译、语言检测 |
| **API 限制** | 单次请求 5,000 字符上限 |
| **延迟** | 快 |
| **优势** | 韩语相关翻译质量顶尖；敬语处理独特优势；不存储用户数据 |
| **劣势** | 语言对数量极少（29 对）；以韩语为中心，非韩语场景价值有限 |

### 1.2 国内服务

#### 百度翻译 API

| 项目 | 详情 |
|------|------|
| **语言数** | 200+ 种语言 |
| **定价** | 标准版: 49 元/百万字符；VIP: 69 元/年（含 20 万机器翻译字数 + 通用领域不限量） |
| **免费额度** | 标准版 5 万字符/月；高级版（个人认证）100 万/月；尊享版（身份认证）200 万/月 |
| **特色功能** | 10 大专业领域模型、自定义术语、图片翻译、语音翻译、文档翻译 |
| **API 限制** | 标准版 QPS 1；高级版 QPS 10 |
| **延迟** | 快 |
| **优势** | 语言覆盖极广（200+）；认证后免费额度大（200 万/月）；专业领域模型；VIP 性价比高 |
| **劣势** | 中英翻译质量不如 LLM；QPS 限制较严 |

#### 有道翻译 API

| 项目 | 详情 |
|------|------|
| **语言数** | 110+ 种语言 |
| **定价** | 48 元/百万字符 |
| **免费额度** | 新用户赠 50 元体验金（约 100 万字符）；实名认证可获 100 元体验金 |
| **特色功能** | 子曰翻译大模型 2.0、图片翻译、语音翻译、文档翻译 |
| **API 限制** | 需咨询 |
| **延迟** | 中等 |
| **优势** | 子曰大模型 2.0 质量提升明显；体验金额度不错 |
| **劣势** | 持续使用成本偏高；生态不如百度/阿里 |

#### 阿里翻译 API

| 项目 | 详情 |
|------|------|
| **语言数** | 200+ 种语言 |
| **定价** | 通用版: 50 元/百万字符；专业版: 60 元/百万字符；定制版: 150 元/百万字符（训练 500 元/次） |
| **免费额度** | 通用版/专业版各 100 万字符/月；文档翻译 1,000 页/月 |
| **特色功能** | 通用/专业/定制三级模型体系、文档翻译、图片翻译 |
| **API 限制** | 标准阿里云配额管理 |
| **延迟** | 快 |
| **优势** | 免费额度大（100 万/月）；多级模型适配不同需求；阿里云生态集成 |
| **劣势** | 海外访问速度一般；定制模型价格高 |

#### 腾讯翻译 API (TMT)

| 项目 | 详情 |
|------|------|
| **语言数** | 70+ 种语言 |
| **定价** | 58 元/百万字符（阶梯定价） |
| **免费额度** | 500 万字符/月 |
| **特色功能** | 图片翻译（1 万次/月免费）、语音翻译（1 万次/月免费）、文档翻译 |
| **API 限制** | 默认 QPS 5 |
| **延迟** | 快 |
| **优势** | 免费额度最大（500 万/月）；微信/QQ 生态集成 |
| **劣势** | 语言覆盖较少；翻译质量中等 |

### 1.3 其他值得关注的服务

| 服务 | 亮点 | 价格 |
|------|------|------|
| **Lara Translate** | 2026 年 WMT 评测表现优异，准确率 65%（vs 竞品 54-58%）；专注翻译的 LLM | 需咨询 |
| **Lingvanex** | 自托管选项，数据不出服务器；支持 110+ 语言 | $2.50/百万字符起 |
| **ModernMT** | 自适应翻译引擎，边翻边学；企业级定制 | 需咨询 |
| **NLLB-200 (Meta)** | 开源模型，200+ 语言；可自托管，零 API 费用 | 仅基础设施成本 |

---

## Part 2：翻译质量评测与对比

### 2.1 2026 年 BLEU 分数基准测试

来源：intlpull.com 2026 年机器翻译准确度基准测试（500 句 x 10 语言对，专业译者审核）

#### 亚洲语言（英语为源语言）

| 语言对 | Google NMT | DeepL | ChatGPT (GPT-4) | Claude |
|--------|------------|-------|------------------|--------|
| EN -> ZH | 47.2 | 51.3 | **54.1** | 53.7 |
| EN -> JA | 43.8 | 48.2 | **51.6** | 51.1 |
| EN -> KO | 41.5 | 46.9 | **50.2** | 49.8 |

#### 欧洲语言（英语为源语言）

| 语言对 | Google NMT | DeepL | ChatGPT (GPT-4) | Claude |
|--------|------------|-------|------------------|--------|
| EN -> ES | 54.2 | **62.8** | 61.4 | 60.9 |
| EN -> FR | 51.7 | **63.1** | 60.8 | 60.2 |
| EN -> DE | 48.3 | **64.5** | 62.1 | 61.8 |

**关键发现：**
- 亚洲语言（中、日、韩）：LLM（ChatGPT/Claude）全面领先，ChatGPT 在三个语言对均排名第一
- 欧洲语言（西、法、德）：DeepL 稳居第一，领先 LLM 约 2-3 个 BLEU 点
- Google NMT 在所有语言对上均排名末位

### 2.2 WMT25 评测（2026 年 2 月综述）

WMT25（机器翻译大会通用任务）使用 ESA 和 MQM 人工评估：

- **Gemini 2.5 Pro** 总体排名第一，在 16 个评估语言对中有 14 个进入顶级集群
- LLM 类系统整体表现优于 DeepL 和 Google Translate
- 评估强调文档级翻译质量（而非单句）

### 2.3 日英翻译专项评测（2026 年）

来源：Ulatus 日英 AI 翻译对比测试

| 维度 | GPT-4o | DeepL | Claude |
|------|--------|-------|--------|
| 敬语保留(Keigo) | 弱（准确率 0.29） | 中（需后编辑） | **强**（对礼貌语境敏感） |
| 潜台词/隐含义 | 中（偶有过度具体化） | 弱（倾向直译） | **强**（处理语气词和隐含关系好） |
| 品牌语气控制 | **强**（通过 prompt 灵活控制） | 中（术语表一致但语气偏中性） | **强**（系统 prompt 下保持一致语气） |
| 综合 | 技术文档佳 | 简洁直白 | **细腻语境佳** |

结论：日英翻译中 Claude 在语境理解上表现最好，GPT-4o 在技术内容上更强，DeepL 适合简单直接的文本。

### 2.4 中英翻译评测

来源：Frontiers in AI (2025) 中文旅游文本翻译多维度对比

在忠实度、流畅度、文化敏感性和说服力四个维度上：
- **ChatGPT** 在使用文化定制 prompt 时全面领先
- Google Translate 和 DeepL 在文化敏感性维度明显不足
- LLM 在处理中文特有的修辞手法和文化意象时优势显著

### 2.5 第三方独立评测总结

| 评测来源 | 时间 | 关键结论 |
|----------|------|----------|
| WMT25 人工评估 | 2025-2026 | Gemini 2.5 Pro 总体第一；LLM > NMT |
| Lokalise 盲测 | 2025 | 专业译者评价 Claude 3.5 "good" 比率最高 |
| DeepL 盲测 | 2024-2025 | DeepL 编辑次数比 Google 少 2x，比 ChatGPT 少 3x（欧洲语言） |
| intlpull 基准测试 | 2026 | 亚洲语言 ChatGPT 第一，欧洲语言 DeepL 第一 |
| Lara Translate 评估 | 2026 | Lara 准确率 65% vs 竞品 54-58% |

---

## Part 3：LLM 翻译 vs 传统 NMT 翻译

### 3.1 质量对比

| 维度 | LLM (GPT-4o/Claude) | 传统 NMT (DeepL/Google) |
|------|---------------------|------------------------|
| 亚洲语言质量 | **优** - BLEU 高 3-7 分 | 中 |
| 欧洲语言质量 | 良 | **优** - DeepL 领先 2-3 BLEU |
| 上下文理解 | **优** - 理解长文脉络 | 弱 - 逐句翻译 |
| 术语一致性 | 良（需 prompt 工程） | **优**（术语表功能） |
| 文化适应性 | **优** - 可通过 prompt 定制 | 弱 |
| 幻觉风险 | 存在（GPT-4 约 2%） | 极低 |
| 格式保留 | 需要额外指令 | **优** - 原生支持 |

### 3.2 成本对比

| 服务 | 定价（每百万字符） | 等效 USD | 备注 |
|------|-------------------|----------|------|
| Azure Translator | $10 | $10 | 标准 NMT 最便宜 |
| Amazon Translate | $15 | $15 | |
| Google Cloud NMT | $20 | $20 | |
| DeepL API Pro | $25 | $25 | + $5.49/月底费 |
| 百度翻译（通用） | 49 元 | ~$6.8 | 认证后 200 万/月免费 |
| 有道翻译 | 48 元 | ~$6.7 | |
| 阿里翻译（通用） | 50 元 | ~$6.9 | 100 万/月免费 |
| 腾讯翻译 | 58 元 | ~$8.0 | 500 万/月免费 |
| GPT-4o-mini | ~$0.60/M tokens | ~$2.4* | *按平均 4 字符/token 估算 |
| GPT-4o | ~$10/M tokens | ~$40* | 质量更高但贵 |
| Claude 3.5 Sonnet | ~$15/M tokens | ~$60* | 语境理解最佳 |

> *注：LLM 定价按 token 而非字符计费，中文约 1-2 字符/token，英文约 4 字符/token，实际成本因语言而异。中文翻译时 LLM 的字符单价会更高。

**成本分析：**

对于 WhisperUtil 的语音翻译场景（短句，通常 50-500 字符），单次翻译成本极低：
- GPT-4o-mini 翻译 500 字符 ≈ $0.0001（约 0.07 分人民币）
- DeepL 翻译 500 字符 ≈ $0.0000125（约 0.009 分人民币）

在这个量级下，成本差异可以忽略不计，翻译质量和延迟才是关键考量。

### 3.3 延迟对比

| 服务类型 | 典型延迟 | 备注 |
|----------|----------|------|
| Amazon Translate | ~50ms | NMT 最快 |
| Google NMT | ~50-100ms | 毫秒级 |
| Azure Translator | ~50-100ms | 毫秒级 |
| DeepL | ~200-500ms | 中等 |
| GPT-4o-mini | ~500-1500ms | 取决于输入长度 |
| GPT-4o | ~1000-3000ms | 较慢 |
| Claude | ~1000-3000ms | 较慢 |

对于 WhisperUtil 场景，用户已经完成录音后等待结果，1-2 秒的翻译延迟在体验上是可接受的。

### 3.4 2025-2026 年趋势：LLM 是否在取代传统翻译引擎？

**是的，趋势明确——LLM 正在取代传统 NMT，但尚未完全替代。**

关键趋势：

1. **质量逆转**：2024 年前，专用 NMT 在大多数语言上优于 LLM。2025-2026 年，LLM 在亚洲语言和上下文敏感内容上已全面超越 NMT，仅欧洲语言 DeepL 仍保持优势。

2. **混合方案成为主流**：Gartner 预测 2026 年 80% 的企业将部署混合/自适应翻译系统，按场景动态选择最优引擎。

3. **传统引擎 LLM 化**：DeepL 已推出专用翻译 LLM；Google Cloud Translation 新增 LLM 翻译模式；有道推出子曰翻译大模型 2.0。传统厂商正在向 LLM 转型。

4. **LLM 翻译成本持续下降**：GPT-4o-mini 的价格已低于大部分传统 NMT API，且质量不逊色。

5. **LLM 的独特优势不可替代**：上下文理解、风格控制、多轮对话式翻译、文化适应性——这些能力是传统 NMT 无法提供的。

---

## Part 4：对 WhisperUtil 的建议

### 4.1 当前方案评估

WhisperUtil 当前使用 **gpt-4o-transcribe + gpt-4o-mini 两步法**：

| 评估维度 | 评分 | 说明 |
|----------|------|------|
| 中英翻译质量 | 优 | GPT-4o-mini 在中英 BLEU 基准中表现仅略低于 GPT-4，显著优于 Google/DeepL |
| 日英翻译质量 | 良 | 技术内容好，但细腻语境不如 Claude |
| 成本 | 优 | GPT-4o-mini 是 LLM 中成本最低的选项之一 |
| 延迟 | 良 | 两步法增加了一次 API 调用，但 gpt-4o-mini 响应快 |
| 架构简洁性 | 优 | 只依赖 OpenAI 一个服务商，与转录共用 API Key |
| 语言灵活性 | 优 | 支持任意目标语言，无需硬编码语言对 |

**结论：当前 gpt-4o-mini 两步法已经是一个非常好的方案，不建议大幅改变。**

### 4.2 可选优化方向

#### 方案 A：维持现状 + 微调（推荐）

- 保持 gpt-4o-mini 两步法作为默认翻译方案
- 优化翻译 prompt，加入语境提示（如 "这是口语转录文本"）以提升翻译质量
- 当前 `chatTranslate()` 中硬编码了 "Translate to English"，应改为使用 `translationTargetLanguage` 设置

#### 方案 B：引入 DeepL 作为欧洲语言选项（可选）

- 仅当用户翻译目标为欧洲语言（EN/DE/FR/ES/IT 等）时，提供 DeepL 选项
- DeepL API Free 50 万字符/月免费，对个人用户足够
- 实现复杂度：需增加 DeepL API 调用模块 + 用户设置项

#### 方案 C：引入 Apple Translation Framework（离线回退）

- 06 号调研文档已提及此方案
- 优势：免费、离线、隐私友好
- 劣势：翻译质量不如 LLM，语言对有限
- 适用场景：无网络时的降级方案

#### 方案 D：升级翻译模型

- 对翻译质量要求极高时，可将翻译步骤从 gpt-4o-mini 升级到 gpt-4o
- 成本增加约 15-20 倍，但对于短句翻译绝对成本仍然极低
- 可作为 EngineeringOptions 中的配置项

### 4.3 不建议的方向

| 方案 | 不推荐原因 |
|------|-----------|
| 切换到 Google Cloud Translation | NMT 质量不如 GPT-4o-mini，且需额外维护 GCP 账号 |
| 切换到 Azure Translator | 虽然价格最低，但质量不如 LLM |
| 使用国内翻译 API（百度/有道/阿里） | 增加服务商依赖；海外用户访问可能受限；质量不如 LLM |
| 使用 Papago | 仅适合韩语场景，覆盖面太窄 |
| 使用 Claude 翻译 | 语境理解虽好但需引入新 API Key，成本更高，收益不明显 |

### 4.4 最终建议

**短期（立即可做）：**
1. 优化翻译 prompt —— 加入口语转录语境提示，预期可提升翻译自然度
2. 修复 `chatTranslate()` 中目标语言硬编码问题，使用 `translationTargetLanguage` 设置

**中期（视需求）：**
3. 在 EngineeringOptions 中增加翻译模型选项（gpt-4o-mini / gpt-4o），允许用户在质量和成本间选择
4. 考虑引入 Apple Translation Framework 作为离线回退

**长期（持续关注）：**
5. 关注 DeepL 在亚洲语言上的进展（如果 DeepL 亚洲语言质量赶上 LLM，可作为低延迟替代）
6. 关注 OpenAI 是否推出专用翻译 API（更低成本、更低延迟）
7. 关注 Gemini 2.5 Pro 的翻译 API（WMT25 总体排名第一）

---

## Part 5：定价速查表

### 国际服务（USD/百万字符）

| 服务 | 价格 | 免费额度 | 最适合 |
|------|------|----------|--------|
| Azure Translator | $10 | 200 万/月 | 预算敏感 + Azure 生态 |
| Amazon Translate | $15 | 200 万/月(12个月) | AWS 生态 + 速度优先 |
| Google Cloud NMT | $20 | 50 万/月 | 语言覆盖最广 |
| DeepL API Pro | $25 + $5.49/月 | 50 万/月(Free) | 欧洲语言质量最佳 |
| GPT-4o-mini | ~$2.4* | 无 | 亚洲语言 + 低成本 |
| GPT-4o | ~$40* | 无 | 最高质量 |

### 国内服务（RMB/百万字符）

| 服务 | 价格 | 免费额度 | 最适合 |
|------|------|----------|--------|
| 百度翻译 | 49 元 | 200 万/月(认证) | 国内用户 + 语言覆盖广 |
| 有道翻译 | 48 元 | 50-100 元体验金 | 子曰大模型 2.0 |
| 阿里翻译 | 50 元 | 100 万/月 | 阿里云生态 |
| 腾讯翻译 | 58 元 | 500 万/月 | 免费额度最大 |

---

## 参考来源

- [DeepL API Plans](https://support.deepl.com/hc/en-us/articles/360021200939-DeepL-API-plans)
- [Google Cloud Translation Pricing](https://cloud.google.com/translate/pricing)
- [Azure Translator Pricing](https://azure.microsoft.com/en-us/pricing/details/translator/)
- [Amazon Translate Pricing](https://aws.amazon.com/translate/pricing/)
- [Papago Translation Overview](https://api.ncloud-docs.com/docs/en/ai-naver-papagonmt)
- [百度翻译开放平台](https://fanyi-api.baidu.com/product/11)
- [有道智云价格中心](https://ai.youdao.com/price-center.s)
- [阿里机器翻译定价](https://help.aliyun.com/zh/machine-translation/product-overview/pricing-of-machine-translation)
- [腾讯机器翻译计费概述](https://cloud.tencent.com/document/product/551/35017)
- [intlpull: Machine Translation Accuracy 2026 Benchmark](https://intlpull.com/blog/machine-translation-accuracy-2026-benchmark)
- [intlpull: Best Translation API 2026](https://intlpull.com/blog/best-translation-api-2026)
- [Lara Translate: Translation Model Benchmark Feb 2026](https://blog.laratranslate.com/translation-model-benchmark/)
- [Ulatus: 2026 Japanese-to-English AI Translator Shootout](https://www.ulatus.com/translation-blog/2026-japanese-to-english-ai-translator-shootout-gpt-4o-vs-deepl-vs-claude-on-keigo-subtext-and-brand-voice/)
- [Frontiers: ChatGPT vs Google Translate vs DeepL in Chinese Translation](https://www.frontiersin.org/journals/artificial-intelligence/articles/10.3389/frai.2025.1619489/full)
- [Localize: Blind AI Translation Study](https://localizejs.com/articles/what-a-blind-ai-translation-study-reveals-about-modern-localization)
- [DeepL: Next-gen LLM Performance](https://www.deepl.com/en/blog/next-gen-language-model)
- [NLLB: Best Translation AI 2026](https://nllb.com/best-translation-ai-2026/)
- [2025 国内翻译 API 评测](https://www.explinks.com/blog/pr-in-depth-evaluation-of-domestic-translation-apis/)
