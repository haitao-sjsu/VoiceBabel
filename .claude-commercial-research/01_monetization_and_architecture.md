# WhisperUtil 商业化研究报告

> 调研日期：2026-03-26

---

## 目录

- [Part 1: 变现模式分析](#part-1-变现模式分析)
- [Part 2: 商业化云端架构设计](#part-2-商业化云端架构设计)
- [Part 3: OpenAI API 商用集成](#part-3-openai-api-商用集成)
- [Part 4: 法律与合规](#part-4-法律与合规)

---

## Part 1: 变现模式分析

### 1.1 竞品定价调研

| 产品 | 定价模式 | 价格 | 特点 |
|------|---------|------|------|
| **SuperWhisper** | 订阅/买断 | $84.99/年 或 $249.99 买断 | 本地+云端，BYOK 需 Pro（$8.49/月） |
| **MacWhisper** | 一次性买断 | Free / Pro $29 / Pro+ $79.99 | 文件转录为主，非实时听写 |
| **Wispr Flow** | 订阅制 | $15/月（$144/年），免费版 2000词/周 | 纯云端，无离线模式 |
| **Voibe** | 订阅/买断 | $4.90/月 / $44.10/年 / $99 买断 | 本地 Whisper，Apple Silicon 优化 |
| **Spokenly** | 免费 + 订阅 | 本地免费，Pro $9.99/月 | BYOK 免费，托管云端收费 |
| **VoiceInk** | 一次性买断 | $25~$49（1~3 台 Mac） | 开源，本地 whisper.cpp，可自行编译 |

**定价区间总结：**
- 一次性买断：$25 ~ $250
- 月订阅：$5 ~ $15/月
- 年订阅：$44 ~ $144/年

### 1.2 订阅模式（月付/年付）

**推荐分层方案：**

| 层级 | 价格 | 包含内容 |
|------|------|---------|
| **Free** | $0 | 本地转录无限制（WhisperKit），云端 10 分钟/天 |
| **Pro** | $8/月 或 $68/年 | 云端无限转录，Realtime 流式，文本优化，翻译 |
| **Pro+** | $15/月 或 $128/年 | 一切 Pro 功能 + 优先队列 + 高级模型 + API 访问 |

**优点：** 可预测的经常性收入 (MRR)，易于规划成本
**缺点：** 用户对订阅疲劳，solo 开发者需持续维护

### 1.3 按量计费（按分钟）

**定价逻辑（基于 OpenAI API 成本 + 加价）：**

| 模型 | OpenAI 成本 | 建议售价 | 毛利率 |
|------|------------|---------|--------|
| gpt-4o-transcribe | $0.006/分钟 | $0.02/分钟 | 70% |
| gpt-4o-mini-transcribe | $0.003/分钟 | $0.01/分钟 | 70% |
| Realtime API (仅音频输入) | $0.06/分钟 | $0.15/分钟 | 60% |
| 文本优化 (gpt-4o-mini) | ~$0.001/次 | 包含在转录价格中 | — |

**按量计费套餐示例：**
- 充值 $5 → 250 分钟标准转录
- 充值 $20 → 1100 分钟标准转录（10% 加量）
- 充值 $50 → 3000 分钟标准转录（20% 加量）

**优点：** 用户按需付费，低门槛
**缺点：** 收入波动大，计费系统复杂

### 1.4 一次性买断 + 可选云端

**方案设计：**

| 组件 | 价格 | 说明 |
|------|------|------|
| 基础版（本地转录） | $29 一次性 | WhisperKit 离线转录，永久使用 |
| 云端附加包 | $6/月 或 $49/年 | gpt-4o-transcribe、Realtime、翻译、文本优化 |

**优点：** 本地版零运营成本，降低用户进入门槛
**缺点：** 买断制一次性收入，需要足够新用户来维持

### 1.5 Freemium + 自建后端

当开源 STT 模型（如 Whisper large-v3、Parakeet）质量接近 OpenAI 时：

| 层级 | 价格 | 说明 |
|------|------|------|
| 免费版 | $0 | 本地转录无限制 + 基础自建云端转录 |
| Premium | $8/月 | 文本优化、多语言翻译、优先处理、高级模型 |

自建后端成本估算（后续 Part 2 详述），仅在用户量达 1000+ 时才有成本优势。

### 1.6 推荐方案：Solo 开发者起步策略

**推荐：「一次性买断 + 可选云端订阅」混合模式**

理由：
1. **最低运营风险** — 本地版无服务器成本，即使零云端用户也不亏钱
2. **竞品定位清晰** — $29 买断对标 MacWhisper，云端订阅 $6/月 低于 Wispr Flow 的 $15/月
3. **渐进式验证** — 先卖本地版验证 PMF（Product-Market Fit），再根据用户需求推出云端
4. **BYOK 作为中间选项** — 允许用户自带 OpenAI API Key 免费使用云端功能，降低付费阻力

**具体起步价格建议：**
- 本地版：$29 一次性（7 天试用）
- 云端 Pro：$6/月 或 $49/年
- BYOK 模式：免费（用户自带 Key）

**预估收入模型（前 6 个月）：**
- 假设月均 50 次本地版购买 → $1,450/月
- 假设 20% 转化云端订阅 → 10 人 x $6 = $60/月
- 累计 6 个月后：~$300 本地版 + ~$360 云端 = ~$660/月 MRR

---

## Part 2: 商业化云端架构设计

### 2.1 API 网关 / 代理架构

**为什么需要代理层：**
- 保护 API Key（不暴露给客户端）
- 用量追踪与配额管理
- 速率限制，防止滥用
- 统一计费入口

**架构图：**

```
WhisperUtil App
    |
    |-- HTTP 转写请求 --> [Cloudflare Worker / API Gateway]
    |                          |
    |                          |-- 鉴权（JWT 验证）
    |                          |-- 配额检查（剩余分钟数）
    |                          |-- 速率限制
    |                          +-- 转发 -> OpenAI /v1/audio/transcriptions
    |
    +-- WebSocket 流式 --> [Cloudflare Durable Object]
                               |
                               |-- 鉴权 + 配额检查
                               +-- WebSocket 代理 -> wss://api.openai.com/v1/realtime
```

**技术方案对比：**

| 方案 | 月费 | 优点 | 缺点 |
|------|------|------|------|
| **Cloudflare Workers**（推荐） | $5/月起 | 全球边缘节点、免费 10M 请求、WebSocket 原生支持 | CPU 时间限制 30s（付费版） |
| AWS API Gateway + Lambda | ~$15/月起 | 成熟生态、WebSocket API 支持 | 冷启动延迟、WebSocket 按消息计费贵 |
| 自建 VPS (Nginx + Node.js) | ~$5~20/月 | 完全控制 | 需自行运维、单点故障 |
| Cloudflare AI Gateway | $0（代理免费） | 零配置代理 OpenAI、自带缓存和日志 | 仅代理不含业务逻辑 |

**WebSocket 代理关键点：**
- Cloudflare Workers 原生支持 WebSocket，每个连接算 1 个请求
- WebSocket 消息不额外计费
- Durable Objects 可管理连接状态，$0.15/百万请求 + $0.20/GB-月存储
- 连接保活：OpenAI Realtime API 使用 server_vad，录音期间持续连接

**推荐：起步使用 Cloudflare Workers + Durable Objects。** 月费 $5 起，覆盖 10M 请求，足够支撑初期用户量。

### 2.2 用户认证与管理

**方案对比：**

| 方案 | 免费额度 | 月费 | 特点 |
|------|---------|------|------|
| **Supabase Auth**（推荐） | 50,000 MAU | $25/月 Pro | 开源、PostgreSQL、内置 Row Level Security |
| Firebase Auth | 50,000 MAU | $0 起 | Google 生态、SDK 成熟 |
| Auth0 | 7,500 MAU | $23/月 | 企业级、丰富的 SSO |
| 自建 JWT | 无限 | $0 | 完全控制，但需自行实现 |

**推荐方案（MVP 阶段）：**

```
方案 A（最小化）：自建 JWT + Supabase 数据库
- Supabase 免费版存储用户数据和用量记录
- 自建 JWT 签发/验证（嵌入 Cloudflare Worker）
- 登录方式：Sign in with Apple（macOS 原生支持）
- 月费：$0

方案 B（推荐）：Supabase Auth + Database
- 统一认证和数据管理
- 自带 email/password、Apple、Google 登录
- 月费：$0（免费版足够 50K MAU）
```

**用量追踪数据模型：**

```sql
-- 用户用量表
CREATE TABLE usage_records (
    id          uuid PRIMARY KEY,
    user_id     uuid REFERENCES auth.users,
    audio_seconds  integer,     -- 本次音频时长（秒）
    api_mode    text,           -- cloud / realtime
    model       text,           -- gpt-4o-transcribe / whisper-1
    cost_usd    decimal(10,6),  -- 实际 OpenAI 成本
    created_at  timestamptz DEFAULT now()
);

-- 用户配额表
CREATE TABLE user_quotas (
    user_id         uuid PRIMARY KEY REFERENCES auth.users,
    plan            text DEFAULT 'free',
    monthly_seconds integer DEFAULT 600,  -- 免费版 10 分钟/天 ~ 300 分钟/月
    used_seconds    integer DEFAULT 0,
    reset_at        timestamptz
);
```

### 2.3 支付集成

**macOS 应用支付路径选择：**

| 分发渠道 | 支付方式 | 佣金 | 适用场景 |
|---------|---------|------|---------|
| **Mac App Store** | StoreKit IAP | 15%（小企业）/ 30% | 获取曝光，信任度高 |
| **官网直销**（推荐起步） | Stripe / Paddle | 2.9% + $0.30 | 保留最大利润，灵活定价 |
| **Gumroad / LemonSqueezy** | 内置支付 | 5~10% | 最简单，适合 indie |

**App Store 佣金应对策略：**
- Apple 小企业计划：年收入 < $1M 时佣金降至 15%
- 策略：App Store 分发免费版（本地转录），订阅通过官网 Stripe 购买
- 注意：如果通过 App Store 分发，App Store 规则要求应用内购买的数字内容/订阅必须使用 IAP
- **最优解：不上 App Store，通过官网 + Notarization 分发**，佣金仅 Stripe 的 2.9%

**Stripe 集成要点：**
- Stripe Checkout：托管支付页面，零前端开发
- Stripe Customer Portal：用户自助管理订阅
- Webhook 通知：支付成功 -> 更新 Supabase 用户配额
- 月费：$0 固定费用，仅按交易收 2.9% + $0.30

**RevenueCat（如果上 App Store）：**
- 统一管理 App Store + Stripe 订阅
- 费用：$2,500+ MTR 后收 1%
- 优点：跨平台 entitlement 同步

### 2.4 用量计量与计费

**成本核算（每用户每月）：**

假设 Pro 用户平均每月使用 300 分钟转录：

| 项目 | 计算 | 成本 |
|------|------|------|
| gpt-4o-transcribe (80%) | 240 分钟 x $0.006 | $1.44 |
| Realtime API 输入 (15%) | 45 分钟 x $0.06 | $2.70 |
| gpt-4o-mini-transcribe (5%) | 15 分钟 x $0.003 | $0.045 |
| 文本优化 (gpt-4o-mini) | ~300 次 x ~$0.001 | $0.30 |
| **总 API 成本** | | **$4.49** |
| **用户付费** | $6/月 或 $8/月 | **$6~8** |
| **毛利** | | **$1.51~3.51 (25%~44%)** |

**关键洞察：**
- Realtime API 的成本是标准转录的 10 倍（$0.06 vs $0.006 /分钟）
- 如果用户大量使用 Realtime 模式，毛利会大幅下降
- 应考虑：Realtime 模式设为 Pro+ 专属，或单独计量

**利润优化建议：**
1. 默认使用 gpt-4o-mini-transcribe（$0.003/分钟），Pro+ 才用 gpt-4o-transcribe
2. 免费版限制云端为 10 分钟/天 -> 月最大成本 $0.90/用户
3. 缓存短时重复请求（同一音频不重复调用）
4. 翻译使用 gpt-4o-mini 而非 gpt-4o，成本降低 10 倍

### 2.5 自建 STT 后端

**GPU 服务器选项对比：**

| 提供商 | GPU 型号 | 价格/小时 | 月费(24/7) | 适用场景 |
|-------|---------|----------|-----------|---------|
| **RunPod Community** | A100 80GB | $0.79 | ~$569 | 高性能推理 |
| **Vast.ai** | A100 80GB | $0.67 | ~$482 | 最便宜，但不稳定 |
| **RunPod Community** | A10G 24GB | ~$0.30 | ~$216 | Whisper large-v3 足够 |
| **AWS g5.xlarge** | A10G 24GB | $1.006 | ~$724 | 稳定可靠，但贵 |
| **AWS g5 Spot** | A10G 24GB | ~$0.35 | ~$252 | 便宜但可能中断 |
| **Hetzner** | 无 GPU | -- | -- | 仅 CPU，Whisper 太慢不实际 |

**自建 vs OpenAI API 成本对比：**

以 A10G（RunPod $0.30/hr）运行 Whisper large-v3 为例：
- Whisper large-v3 在 A10G 上的处理速度：约 10x 实时（1 分钟音频处理 ~6 秒）
- 1 小时可处理 ~600 分钟音频
- **自建成本：$0.30 / 600 = $0.0005/分钟**
- **OpenAI 成本：$0.006/分钟**
- **自建成本仅为 OpenAI 的 1/12**

**但需要考虑的隐性成本：**
- 运维时间（部署、监控、故障处理）
- 需要至少 1 台备用机器（可用性）
- 模型更新和优化
- 冷启动时间（Spot 实例被回收后重启）

**结论：日均处理 > 1000 分钟音频时，自建才有意义。** 1000 分钟/天 ~ 约 30,000 分钟/月 -> OpenAI 成本 $180/月 vs 自建 ~$216/月（24/7 运行）。但自建可按需开关机，实际成本更低。

**延迟考量（中国 + 美国用户）：**
- OpenAI API 服务器在美国，中国用户延迟 200~400ms
- 自建方案可在亚太区部署（如 RunPod Tokyo、AWS ap-northeast-1）
- Cloudflare Workers 作为代理层本身是全球边缘，但后端仍需低延迟

### 2.6 推荐最小化架构（MVP）

**第一阶段（启动）— 月费 ~$0：**

```
WhisperUtil App（本地版 + BYOK）
    |
    +-- 用户自带 OpenAI API Key -> 直连 OpenAI API
```

- 无需后端
- 收入：一次性买断 $29
- 运营成本：$0

**第二阶段（验证需求后）— 月费 ~$6：**

```
WhisperUtil App
    |
    |-- 本地模式 -> WhisperKit（免费）
    |
    +-- 云端模式 -> Cloudflare Worker ($5/月)
                     |-- JWT 鉴权
                     |-- 配额检查 (Supabase Free)
                     +-- 代理 -> OpenAI API

    支付：Stripe Checkout（官网购买）
    数据库：Supabase Free（用户 + 用量）
```

固定成本明细：
| 项目 | 月费 |
|------|------|
| Cloudflare Workers（付费版） | $5 |
| Supabase（免费版） | $0 |
| 域名 + DNS | ~$1 |
| Stripe | $0 固定（按交易收费） |
| **合计固定成本** | **~$6** |

变动成本：OpenAI API 按用户实际使用量转嫁

**第三阶段（规模化）— 月费 ~$250+：**

```
新增：
    |-- Supabase Pro ($25/月) — 更大数据库和更多功能
    |-- 自建 GPU 后端 (RunPod ~$216/月) — 降低单位成本
    +-- 监控告警（Grafana Cloud Free / Sentry Free）
```

**各用户规模预估月度成本：**

| 规模 | 固定成本 | 变动成本（API） | 总成本 | 收入（$6/月订阅） | 毛利 |
|------|---------|---------------|--------|-----------------|------|
| 100 用户 | $6 | ~$449 | ~$455 | $600 | $145 (24%) |
| 1,000 用户 | $30 | ~$4,490 | ~$4,520 | $6,000 | $1,480 (25%) |
| 10,000 用户 | $250 | ~$35,000* | ~$35,250 | $60,000 | $24,750 (41%) |

*10,000 用户时应已切换自建后端，API 成本可降至 ~$3,000/月，毛利率提升至 94%

---

## Part 3: OpenAI API 商用集成

### 3.1 商用政策

根据 OpenAI 2026 年 1 月生效的服务条款：

- **API 输出归用户所有** — OpenAI 将 Output 的所有权利转让给用户
- **商用允许** — API 用户可以将输出用于商业目的
- **数据隐私** — API 数据默认不用于模型训练
- **禁止事项** — 不得用 API 输出训练与 OpenAI 竞争的模型
- **转售限制** — 可以构建基于 API 的商业产品，但不得单纯转售 API 访问权

**WhisperUtil 的合规要点：**
- 作为语音转文字工具使用 API 完全合规
- 需在用户条款中说明音频数据会发送到 OpenAI 处理
- 不存储用户音频数据可降低合规风险

### 3.2 速率限制

| 模型 | 默认 RPM | 说明 |
|------|---------|------|
| whisper-1 | ~50 RPM | Tier 1 账号 |
| gpt-4o-transcribe | ~50 RPM | 随使用量增长自动提升 |
| Realtime API | 按并发连接限制 | 通常 100 并发 |

**应对策略：**
1. **代理层排队** — Cloudflare Worker 中实现请求队列，超出速率时排队等待
2. **多 API Key 轮换** — 准备 3~5 个 OpenAI 账号的 Key，代理层轮换使用
3. **用户级限流** — 每用户限制 5 RPM，防止单个用户耗尽配额
4. **申请提升** — 消费达到一定量后联系 OpenAI 申请更高限制
5. **Organization 账号** — 使用 OpenAI Organization 可获得更高限制

### 3.3 成本优化策略

1. **模型选择优化**
   - 默认 gpt-4o-mini-transcribe（$0.003/分钟），质量已足够日常使用
   - 仅高级用户使用 gpt-4o-transcribe（$0.006/分钟）
   - 节省 50% API 成本

2. **音频压缩**
   - 当前已实现 AAC 16kHz 24kbps 编码（AudioEncoder.swift）
   - 压缩比约 20:1，减少上传时间
   - 注意：Whisper API 按音频时长计费而非文件大小，压缩不影响 API 费用，但减少带宽和上传延迟

3. **智能路由**
   - 短音频 (< 30秒) -> 标准 HTTP API（低延迟）
   - 长音频 (> 2分钟) -> Realtime API 流式（用户体验好但成本高）
   - 本地 WhisperKit 作为 fallback -> 零成本

4. **缓存策略**
   - 对文本优化 (TextCleanup) 结果缓存相同输入
   - 翻译结果缓存（相同源文本 + 目标语言）
   - 预计可减少 10~20% 的 API 调用

5. **批量处理**
   - OpenAI Batch API（如可用）可降价 50%
   - 不适用于实时转录，但适合文件批量转录功能

---

## Part 4: 法律与合规

### 4.1 隐私保护

**音频数据处理原则：**

| 原则 | 实现方式 |
|------|---------|
| 最小化收集 | 仅在用户主动录音时采集，不后台监听 |
| 传输加密 | HTTPS / WSS 加密传输 |
| 不存储音频 | 转录完成后立即丢弃音频数据，不落盘 |
| 透明告知 | 明确告知用户音频发送到 OpenAI 处理 |
| 用户控制 | 本地模式完全离线，用户可选择不上传 |

**隐私政策必须包含：**
1. 收集什么数据（音频、转录文本、使用量）
2. 发送到哪里（OpenAI API、你的服务器）
3. 如何存储（不存储音频，仅存储用量统计）
4. 第三方数据处理者（OpenAI）
5. 用户删除数据的权利

### 4.2 GDPR 合规（欧洲用户）

| 要求 | 应对 |
|------|------|
| 合法基础 | 用户同意（首次使用云端时弹窗确认） |
| 数据处理协议 | 与 OpenAI 签订 DPA（OpenAI 已提供标准 DPA） |
| 数据最小化 | 不存储音频，仅保留必要用量数据 |
| 删除权 | 提供账号删除功能，删除所有关联数据 |
| 数据出境 | 告知数据传输到美国（OpenAI 服务器），依据 SCCs |

### 4.3 中国 PIPL 合规

| 要求 | 应对 |
|------|------|
| 告知同意 | 单独同意条款：明确告知音频数据跨境传输至美国 |
| 敏感信息 | 声纹可能被认定为生物识别数据，需单独同意 |
| 数据出境评估 | 如大量中国用户，可能需要数据出境安全评估 |
| 本地存储 | 提供纯本地模式（WhisperKit）作为不出境选项 |
| 个人信息保护影响评估 | 处理敏感个人信息前需完成 PIPIA |

**实际建议：**
- 中国用户推荐使用本地模式，规避跨境传输问题
- 如必须使用云端，明确弹窗获取单独同意
- 考虑未来接入国内 STT API（如讯飞、阿里云）替代 OpenAI

### 4.4 App Store 审核要点

**如果计划上架 Mac App Store：**

1. **麦克风权限**
   - 必须在 Info.plist 声明 `NSMicrophoneUsageDescription`
   - 说明清晰："用于语音转文字录音"
   - 当前已实现（AudioRecorder.swift 检测麦克风权限）

2. **隐私标签**
   - 需在 App Store Connect 声明 "Audio Data" 数据类型
   - 声明用途：App Functionality
   - 声明是否与身份关联

3. **AI 数据共享披露（2026 新要求）**
   - Apple 要求明确披露向 AI 提供商（OpenAI）共享用户数据
   - 需在应用内获取用户明确同意

4. **辅助功能权限**
   - TextInputter 使用 CGEvent 模拟按键，需要 Accessibility 权限
   - App Store 审核对此较严格，需要充分说明用途
   - 注意：沙盒限制可能影响某些功能

5. **支付规则**
   - 数字内容/服务订阅必须使用 App Store IAP
   - 物理商品或在 App 外消费的服务可用外部支付
   - 「Reader Rule」允许链接到外部网站购买，但不能在 App 内引导

### 4.5 用户服务条款

**必须包含的条款：**

1. **服务说明** — 转录准确性不保证 100%，用户应自行验证关键内容
2. **使用限制** — 禁止转录违法内容、未经同意录他人对话
3. **数据处理** — 音频发送到第三方 (OpenAI) 处理
4. **免责声明** — 不对转录错误导致的损失负责
5. **退款政策** — 数字产品一般不退款，但可提供 7 天试用
6. **服务变更** — 保留调整价格和功能的权利
7. **终止条款** — 违反使用条款可终止服务

---

## 附录：行动计划

### 优先级排序

| 阶段 | 目标 | 时间 | 成本 |
|------|------|------|------|
| **P0 -- 立即** | 官网 + Gumroad/LemonSqueezy 卖本地版 $29 | 1~2 周 | $0 |
| **P1 -- 验证** | 加入 BYOK 模式，允许用户自带 API Key | 1 周 | $0 |
| **P2 -- 订阅** | Cloudflare Worker 代理 + Stripe 订阅 + Supabase | 2~4 周 | ~$6/月 |
| **P3 -- 规模** | 自建 GPU 后端 + 更多支付渠道 | 需求驱动 | ~$250+/月 |

### 关键指标（KPI）

- **获客成本 (CAC)** — 目标 < $10（通过 SEO / Product Hunt / 社区推广）
- **月活跃用户 (MAU)** — 第 3 个月目标 100+
- **付费转化率** — 目标 5~10%
- **月经常性收入 (MRR)** — 第 6 个月目标 $500+
- **用户流失率** — 目标 < 5%/月

---

## 参考来源

- [OpenAI API Pricing](https://openai.com/api/pricing/)
- [OpenAI Realtime API Cost Management](https://developers.openai.com/api/docs/guides/realtime-costs)
- [OpenAI Usage Policies](https://openai.com/policies/usage-policies/)
- [OpenAI Terms of Use](https://openai.com/policies/row-terms-of-use/)
- [SuperWhisper](https://superwhisper.com/)
- [MacWhisper vs Voicy vs SuperWhisper 2026](https://usevoicy.com/blog/macwhisper-vs-voicy-vs-superwhisper)
- [Spokenly vs Wispr Flow](https://spokenly.app/comparison/wispr-flow)
- [Spokenly vs Voibe](https://spokenly.app/comparison/voibe)
- [VoiceInk Pricing](https://tryvoiceink.com/pricing)
- [Cloudflare Workers Pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [Cloudflare Durable Objects Pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- [Supabase Pricing](https://supabase.com/pricing)
- [Firebase Auth Pricing 2026](https://www.metacto.com/blogs/the-complete-guide-to-firebase-auth-costs-setup-integration-and-maintenance)
- [RunPod GPU Pricing](https://www.runpod.io/pricing)
- [Vast.ai vs RunPod 2026](https://medium.com/@velinxs/vast-ai-vs-runpod-pricing-in-2026-which-gpu-cloud-is-cheaper-bd4104aa591b)
- [AWS EC2 G5 Instances](https://aws.amazon.com/ec2/instance-types/g5/)
- [RevenueCat + Stripe](https://www.revenuecat.com/docs/web/integrations/stripe)
- [Apple App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [China PIPL Compliance](https://www.hawksford.com/insights-and-guides/china-pipl-compliance-guide)
- [Speakmac vs Superwhisper Pricing](https://www.speakmac.app/blog/speakmac-vs-superwhisper-comparison)
- [Best Speech-to-Text Apps for Mac 2026](https://whisperclip.com/blog/posts/best-speech-to-text-apps-for-mac-2026-complete-buyers-guide)
