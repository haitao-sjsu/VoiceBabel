# 官网 + 分发流水线调研

本文回答 WhisperUtil 走向对外发布时的 4 个基础设施问题,并给出一个可落地的组合方案:

1. 官网代码放在哪里
2. 是否/以何种身份注册 Apple Developer Program
3. 下载量与流量如何监控
4. 如何做版本化的自动构建 / 签名 / 公证 / 发布

## 概要结论(先看答案)

| 问题 | 推荐方案 | 一句话理由 |
|------|---------|----------|
| 官网仓位置 | **同仓 `/website` 子目录 + Cloudflare Pages** | AltTab、Maccy 等同规模明星项目的共识做法;CF Pages 对 monorepo 原生友好 |
| Apple Developer | **今天就以个人(Individual)身份注册,99 USD/年** | 即买即用,权益与组织账号完全等同;将来转公司无缝(Team ID/Bundle ID/老用户/Sparkle 全保留) |
| 下载监控 | **CF Web Analytics(落地页) + CF Worker `/latest` 重定向埋点 + GH Releases API 每日 cron 兜底** | 0 美元/月,3 小时配好,全数据汇在 Cloudflare |
| CI/CD | **GitHub Actions + macos-latest + 原生 shell 脚本 + Sparkle 2** | 开源仓免费、原生 `notarytool` + `create-dmg`,不用 Fastlane |

最终发布流只剩一条命令:`git tag v1.2.3 && git push --tags`。

---

## 1. 官网代码仓库策略

### 1.1 头部 macOS 独立应用的实际做法

| 应用 | 官网 | 代码位置 |
|------|------|---------|
| **AltTab** | alt-tab.app | 同仓 `/docs` + GitHub Pages |
| **Maccy** | maccy.app | 同仓(源文件 `/docs`,发布到 `gh-pages` 分支) |
| **Rectangle** | rectangleapp.com | 独立仓/外部托管 |
| **Stats (exelban)** | mac-stats.com | 独立托管 |
| **Ice** | icemenubar.app | 外部托管 |
| **MonitorControl** | monitorcontrol.app | 外部托管 |
| **Raycast** | raycast.com | 独立 Next.js(App 闭源) |

**没有官方最佳实践**。约一半同仓、一半独立仓都合理。关键看规模与迭代节奏。

### 1.2 四大部署平台对 monorepo 子目录的支持

- **GitHub Pages**: 原生支持 `/docs` 子目录;但一个仓只能一个 Pages 站点,私有仓需付费
- **Cloudflare Pages**: Root Directory + Build Watch Paths 双配置,monorepo 一等公民,私有仓免费
- **Vercel / Netlify**: 也都把 monorepo 当一等公民

### 1.3 同仓 vs 独立仓的关键维度

| 维度 | 同仓 `/website` | 独立仓 |
|------|---------------|--------|
| CI 干扰 | App tag 可能触发官网构建,需 `paths-filter` | 天然隔离 |
| 发版联动(下载按钮改 URL) | 一次 PR 改 app + 网站,原子化 | 需同步两仓 |
| 秘钥/Token | 一套搞定 | 两套 |
| 贡献门槛 | 统一 PR 流程 | 分离 |
| 初始复杂度 | 开个文件夹 | 新建仓 + 配域名 + 配 CI |
| 日后剥离 | `git filter-repo` 可拆 | 已分离 |

### 1.4 推荐

**同仓 `/website` 子目录,Cloudflare Pages 部署。**

1. 符合 WhisperUtil 当前规模(solo、静态页 + 下载链接),与 AltTab/Maccy 同一路线
2. 发版联动最省心:同 commit 同时改 README、改下载链接、打 tag
3. 选 CF Pages 而非 GH Pages 的理由:全球 CDN、支持私有仓(保留未来灵活性)、免费 Web Analytics、Build Watch Paths 避免 app 改动触发站点重建
4. 目录命名用 `/website`(不用 `/docs`——后者在 Swift 项目里易被误会成 API 文档)
5. 将来要拆分时 `git filter-repo --path website` 一条命令搞定

下载按钮可直接指向 `https://github.com/USER/WhisperUtil/releases/latest/download/WhisperUtil.dmg`,随 release 自动指向最新版本。

---

## 2. Apple Developer Program:个人 vs 组织

### 2.1 两种类型对比

| 项目 | 个人(Individual) | 组织(Organization) |
|------|------------------|-------------------|
| 费用 | 99 USD/年 | 99 USD/年 |
| 要求 | Apple ID + 本人法定姓名 | 已注册法人实体(LLC/Inc,**不接受个体工商户**) + DUNS 编号 + 公开公司域名 + 企业邮箱 |
| 审核 | 购买即刻生效 | DUNS 本身 5–7 工作日;整体 1–4 周 |
| Developer ID / 公证 / TestFlight | 完全支持 | 完全支持(同权) |

### 2.2 开发者名称展示

Developer ID 证书格式固定为 `Developer ID Application: <Seller Name> (<TeamID>)`。

- 个人账号显示**法定姓名**(例如 `Haitao Long`)
- 组织账号显示**法人实体名**(例如 `Acme Tech Ltd.`)

Gatekeeper 首次打开对话框、公证提示、App Store 卖家栏位均使用此名。对独立开发者市场(Sindre Sorhus、Panic 早期)这不构成信任壁垒。

### 2.3 代码签名与公证:两种账号完全同权

签名证书数量、5 年有效期、公证流程、错误码、TestFlight 均无差异。Apple 官方 compare-memberships 页面证实。

**无法绕开 ADP**:自 macOS 10.15 起未公证应用被 Gatekeeper 拦截;**macOS 15 Sequoia 起取消了 Ctrl+Click "打开"的绕过**,用户必须进"系统设置 → 隐私与安全性"手动点"仍要打开"——对付费软件是致命首次体验摩擦。

### 2.4 迁移路径:个人 → 组织

Apple 官方支持,通过 `developer.apple.com/contact/submit/?entityType=individual&requestType=migrateAccount` 提交。

**关键事实**:
- Apple ID、**Team ID、Bundle ID、已上架应用、现有证书全部保留**,仅 Seller Name 变更
- 典型周期 1–3 周
- **对 Sparkle 自动更新无破坏**(Team ID 不变)
- 现有用户 Gatekeeper 缓存、授权信任链继续有效

这意味着"先个人,后公司"的代价极低。

### 2.5 中国开发者特殊考量

- **付款**:Apple Developer App 原生支持支付宝/微信支付/银联;Web 端支持双币卡
- **DUNS 难点**:中国境内公司申请 DUNS 免费但 ≥7 工作日,D&B 常默认归入 "sole proprietorship" 导致 Apple 拒绝——需主动提供营业执照纠正为 "Limited Liability Company"
- **税务**:App Store 变现时填 W-8BEN(个人)或 W-8BEN-E(企业);自有网站销售税务在国内自行处理,与 ADP 无关

### 2.6 完全跳过 ADP 的代价

macOS 14/15/16 上首次打开未签名应用必弹"无法验证开发者"警告;15 Sequoia 起右键"打开"不再生效,必须进系统设置手动放行。付费用户看到此提示的退款/差评率显著高。

### 2.7 推荐

**以个人(Individual)身份当天注册。**

1. 注册即用,无 DUNS 等待
2. 权益与组织账号完全一致
3. 未来转公司无损,Sparkle 自动更新不断链
4. 唯一"损失"是首次弹窗显示本人姓名——对 WhisperUtil 这类工具不构成信任壁垒
5. 等产品验证 PMF、有稳定收入、需要税务/责任隔离时,再花 1–3 周迁移——这是合理时机

**不要**为了"看起来更专业"先开空壳公司跑 DUNS,违反 YAGNI。

---

## 3. 下载监控与流量统计

### 3.1 GitHub Releases 内置下载计数

- API 端点 `GET /repos/{owner}/{repo}/releases`,每个 asset 返回 `download_count`
- **只是累计值,无时间序列、无地理、无 UA**
- 只对上传的 binary asset 生效(自动生成的 zip/tarball 源码包不计数)
- 成本 0,~10 分钟:GitHub Actions 每日 cron 拉 API,append 到 `stats.csv` git commit,兜底用

### 3.2 服务端访问日志

- **CF R2 公开桶**: dashboard 只有桶级 operations,**没有每对象下载、没有 country**;要 IP/UA/geo 必须开 Logpush($5/月 Workers Paid),对 solo dev 偏重
- **S3 + CloudFront**: Athena 查询,功能最强但最重(1–2 小时配置,~$1–3/月)
- **自建 nginx/VPS**: GoAccess 离线报表免费,需 MaxMind GeoLite2

### 3.3 Redirect-through-tracker(推荐核心)

自有域名挂 **Cloudflare Worker**,路径 `/latest` 处理:

1. 写一条日志到 **Analytics Engine** (含 `request.cf.country`、`cf.asn`、UA、时间戳)
2. 302 重定向到 `https://github.com/USER/WhisperUtil/releases/latest/download/WhisperUtil.dmg`

**优势**:
- 免费套餐每天 100k 请求
- Analytics Engine 自动按时间聚合,SQL 查 by country/by day,保留 90 天
- 额外获得分渠道统计(`/latest?src=hn` vs `/latest?src=v2ex`)
- 40 行以内的代码

### 3.4 落地页分析工具(2026 价格对比)

| 工具 | 成本 | GDPR/无 Cookie | 支持字段 | 部署 |
|------|------|--------------|--------|------|
| **CF Web Analytics** | **完全免费,不限流量** | 是 | 国家/referrer/设备 全有 | 贴 JS,5 分钟,无需 CF 代理域名 |
| Plausible Cloud | $9/月起(10k pv) | 是 | 全有 | 5 分钟 |
| Plausible 自建 | VPS 几美元 | 是 | 全有 | Docker compose,30–60 分钟 |
| Umami 自建 | VPS 几美元 | 是 | 全有 | Docker + Postgres,30 分钟 |
| Fathom | $15/月起 | 是(存 IP 哈希) | 全有 | 5 分钟 |
| Simple Analytics | $19/月起 | 是(零 PII) | 全有 | 5 分钟 |

**Google Analytics 4 不推荐**:奥、法、意、丹四国判定 GA4 不合规;对 Whisper 这类隐私敏感用户群体尤为不合适。

### 3.5 应用内 telemetry(Phone Home)

**原则**:
- 首次启动**显式 opt-in 对话框**,默认关闭
- 只上报:`installID`(本地生成 UUID,非 Mac 序列号)、app 版本、macOS 版本、语言、国家(从 locale 推断,不传 IP)
- **不上报**:音频、转录内容、API key、文件路径

**推荐库**: `TelemetryDeck`(Swift SPM,专为 Apple 平台,匿名 installID,默认不触发 GDPR,免费 tier)

**但对 WhisperUtil 当前阶段:建议暂不加。** 等确需了解活跃度(不只是下载数)再加,且必须 opt-in。

### 3.6 推荐栈

总成本 **0 美元/月**,配置 **~3 小时**:

1. **落地页访客数** → Cloudflare Web Analytics(5 分钟贴 JS)
2. **下载按钮点击 + 国家分布** → CF Worker `/latest` 重定向 + Analytics Engine
3. **下载总量兜底** → GH Actions 每日 cron 拉 Releases API,append `stats.csv`
4. **应用内 telemetry** → 暂不加

### 3.7 具体配置步骤

- **CF Web Analytics**: dash.cloudflare.com → Analytics & Logs → Web Analytics → Add a site → 复制 `<script defer ...>` 到落地页 `<head>`
- **Worker 重定向**:
  ```
  npx wrangler init whisperutil-dl
  # fetch handler:
  #   env.ANALYTICS.writeDataPoint({ blobs: [country, ua, referrer], indexes: [asset_name] })
  #   return Response.redirect(GITHUB_URL, 302)
  # wrangler.toml 绑定 Analytics Engine dataset
  wrangler deploy
  ```
- **GH 下载数 cron**: `.github/workflows/stats.yml`,每日跑 `gh api repos/$OWNER/$REPO/releases --jq '.[].assets[] | {name, download_count, date: now}' >> stats.csv && git commit`

---

## 4. CI/CD 发版流水线

### 4.1 版本号管理

Xcode 11 起 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 在 `project.pbxproj` 的 build settings,不在 Info.plist。三种方案:

- `agvtool`:Apple 原生,但要求 `VERSIONING_SYSTEM = apple-generic`,不支持并发
- `xcrun sed`:直接替换 `project.pbxproj`,简单可靠
- **xcconfig 文件**:抽到 `Config/Version.xcconfig`,CI 中 sed 改单行(**最干净,推荐**)

**git tag 驱动**:`git tag v1.2.3 && git push --tags` → workflow 从 `${GITHUB_REF_NAME#v}` 解析版本号写入 xcconfig,build number 用 `$GITHUB_RUN_NUMBER`。

### 4.2 CLI 构建

Developer ID 分发**必须**走 archive + exportArchive:

```bash
xcodebuild -project WhisperUtil.xcodeproj -scheme WhisperUtil \
  -configuration Release -archivePath build/WhisperUtil.xcarchive archive

xcodebuild -exportArchive -archivePath build/WhisperUtil.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

`ExportOptions.plist` 关键字段:`method = developer-id`、`signingStyle = manual`、`teamID = XXXXXXXXXX`。菜单栏应用走同样的 archive 流程。

### 4.3 CI 代码签名

**推荐 `Apple-Actions/import-codesign-certs@v3`**(node24,支持 productsign)。`.p12` base64 编码存 secret,action 创建临时 keychain 并在 job 结束自动清理。

**2026 独立 macOS 开发者没必要引入 Fastlane**——`match` 长期在 Developer ID 支持上有坑(fastlane issue #15241、#16875);原生 shell + GH Action 更清爽。

Developer ID 分发**通常不需要 provisioning profile**(除非用了 CloudKit、Push、App Groups)。WhisperUtil 目前没用,跳过。

### 4.4 公证(Notarization)

**`altool` 已于 2023-11-01 停用,必须用 `xcrun notarytool`**(随 Xcode 14+)。认证方式:

- **App Store Connect API Key(`.p8` + Key ID + Issuer ID)** — 当前推荐
- Apple ID + app-specific password — 可用但双因素账号更麻烦

标准流程:

```bash
xcrun notarytool submit WhisperUtil.dmg \
  --key AuthKey.p8 --key-id $KEY_ID --issuer $ISSUER_ID \
  --wait --timeout 30m

xcrun stapler staple WhisperUtil.dmg
```

**时延(2026)**:正常 2–5 分钟,偶尔积压数小时。**常见失败**:
1. 未启用 Hardened Runtime(`--options runtime`)
2. 内嵌 framework/XPC 未逐个签名
3. 缺 JIT / `allow-unsigned-executable-memory` 等 entitlement
4. 时间戳缺失(忘记 `--timestamp`)

失败后 `xcrun notarytool log <submission-id> --keychain-profile ...` 查 JSON 详情。

### 4.5 打包

Rectangle、Ice、Stats、Raycast 多用 **DMG**(可自定义背景 + 快捷方式指向 Applications)。**推荐 sindresorhus 的 `create-dmg`**。

**严格顺序**:签 `.app` → 打 DMG → notarize DMG → staple DMG。**不能只 notarize `.app` 就 staple DMG**——两者都需 ticket 才能离线启动。

### 4.6 发布

```bash
gh release create "v${VERSION}" \
  "build/WhisperUtil-${VERSION}.dmg" \
  --title "WhisperUtil ${VERSION}" \
  --notes-file RELEASE_NOTES.md
```

官网下载链接指向 **GitHub Release 稳定 URL**:`https://github.com/USER/WhisperUtil/releases/latest/download/WhisperUtil.dmg`(或被 CF Worker 代理以加埋点)。

### 4.7 Sparkle 2 自动更新

- `./bin/generate_keys` 本地生成 EdDSA 私钥,打印 base64 公钥 → 写入 Info.plist `SUPublicEDKey`,并设 `SUFeedURL = https://USER.github.io/whisperutil-appcast/appcast.xml`
- **私钥必须备份**(至少两处:1Password + 离线加密 U 盘)——**丢失 = 所有现存用户收不到更新,只能重装新版**
- CI 中 `SPARKLE_ED_PRIVATE_KEY` secret 注入,调 `sign_update <dmg>` 得 signature + length,生成/更新 `appcast.xml`
- **appcast 托管**:独立仓 `whisperutil-appcast` + GitHub Pages(免费、HTTPS、稳定 URL)。CI 用 deploy key 推更新
- **`SUFeedURL` 一旦发布就不可改**,否则旧用户再也收不到更新——一开始就用自有域名 CNAME 到 GH Pages

### 4.8 CI 平台对比

| 平台 | 评价 |
|------|------|
| **GitHub Actions `macos-latest`** | **首选**。公开仓免费;私有仓 macOS 按 10× Linux 计(Free 账户 2000 min/月 → 实际 200 macOS min/月)。WhisperUtil 一次发布约 10–15 min,**开源 = 零成本**。2026-01-01 起整体降价 39% |
| Xcode Cloud | 为 App Store / TestFlight 优化;Developer ID 场景 notarization 工作流不如 GHA 灵活,对非 App Store 菜单栏工具不划算 |
| Fastlane | 重心在 iOS;macOS Developer ID 增加 Ruby 依赖收益小,**跳过** |
| 自托管 Mac mini | 只有手头已有闲置 Mac mini 才值得 |

### 4.9 机密管理

全部放 GitHub Actions Secrets(二进制 `base64 -i file -o file.b64` 先编码):

- `DEV_ID_P12_BASE64` + `DEV_ID_P12_PASSWORD`
- `APPSTORE_API_KEY_P8_BASE64` + `APPSTORE_API_KEY_ID` + `APPSTORE_API_ISSUER_ID`
- `SPARKLE_ED_PRIVATE_KEY`
- `APPCAST_DEPLOY_KEY`(SSH 私钥,写权限 appcast 仓)
- `APPLE_TEAM_ID` / `APPLE_TEAM_NAME`
- `GITHUB_TOKEN` 自动注入

### 4.10 完整 workflow 示例

```yaml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: macos-15
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4

      - name: Parse version
        id: ver
        run: echo "version=${GITHUB_REF_NAME#v}" >> $GITHUB_OUTPUT

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app

      - name: Bump version in xcconfig
        run: |
          sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${{ steps.ver.outputs.version }}/" Config/Version.xcconfig
          sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${{ github.run_number }}/" Config/Version.xcconfig

      - name: Import Developer ID cert
        uses: Apple-Actions/import-codesign-certs@v3
        with:
          p12-file-base64: ${{ secrets.DEV_ID_P12_BASE64 }}
          p12-password: ${{ secrets.DEV_ID_P12_PASSWORD }}

      - name: Archive & export
        run: |
          xcodebuild -project WhisperUtil.xcodeproj -scheme WhisperUtil \
            -configuration Release -archivePath build/WhisperUtil.xcarchive \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY="Developer ID Application" \
            DEVELOPMENT_TEAM=${{ secrets.APPLE_TEAM_ID }} archive
          xcodebuild -exportArchive -archivePath build/WhisperUtil.xcarchive \
            -exportOptionsPlist ci/ExportOptions.plist -exportPath build/export

      - name: Create DMG
        run: |
          npm install -g create-dmg
          cd build/export
          create-dmg WhisperUtil.app --identity="Developer ID Application: ${{ secrets.APPLE_TEAM_NAME }}"
          mv *.dmg ../WhisperUtil-${{ steps.ver.outputs.version }}.dmg

      - name: Notarize & staple
        env:
          API_KEY_B64: ${{ secrets.APPSTORE_API_KEY_P8_BASE64 }}
        run: |
          echo "$API_KEY_B64" | base64 -d > AuthKey.p8
          xcrun notarytool submit build/WhisperUtil-${{ steps.ver.outputs.version }}.dmg \
            --key AuthKey.p8 \
            --key-id ${{ secrets.APPSTORE_API_KEY_ID }} \
            --issuer ${{ secrets.APPSTORE_API_ISSUER_ID }} \
            --wait --timeout 30m
          xcrun stapler staple build/WhisperUtil-${{ steps.ver.outputs.version }}.dmg
          rm AuthKey.p8

      - name: Sparkle sign
        id: sparkle
        run: |
          echo "${{ secrets.SPARKLE_ED_PRIVATE_KEY }}" > sparkle_key
          SIG=$(./Sparkle/bin/sign_update -f sparkle_key build/WhisperUtil-${{ steps.ver.outputs.version }}.dmg)
          echo "sig=$SIG" >> $GITHUB_OUTPUT
          rm sparkle_key

      - name: GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "v${{ steps.ver.outputs.version }}" \
            "build/WhisperUtil-${{ steps.ver.outputs.version }}.dmg" \
            --title "WhisperUtil ${{ steps.ver.outputs.version }}" \
            --generate-notes

      - name: Update appcast
        uses: actions/checkout@v4
        with:
          repository: ${{ github.repository_owner }}/whisperutil-appcast
          ssh-key: ${{ secrets.APPCAST_DEPLOY_KEY }}
          path: appcast
      - run: |
          cd appcast
          python3 ../ci/update_appcast.py \
            --version ${{ steps.ver.outputs.version }} \
            --signature "${{ steps.sparkle.outputs.sig }}" \
            --url "https://github.com/${{ github.repository }}/releases/download/v${{ steps.ver.outputs.version }}/WhisperUtil-${{ steps.ver.outputs.version }}.dmg"
          git config user.email "bot@users.noreply.github.com"
          git config user.name "Release Bot"
          git add appcast.xml && git commit -m "Release ${{ steps.ver.outputs.version }}" && git push
```

### 4.11 常见坑

- `notarytool --wait` 偶尔挂死 → 加 `--timeout 30m`,或去掉 `--wait` 改轮询
- `stapler` 必须联网(CI 里不是问题,脚本不能在离线环境跑)
- **证书过期**:Developer ID 五年有效,到期前 3 个月在 portal 签新证书,更新 `.p12` secret。**已安装的老 app ticket 是永久的,继续可启动**
- **`SUFeedURL` 不可迁移**:一旦发布永远不能改,否则旧用户失联。**一开始就用自有域名 CNAME 到 GH Pages**
- **Sparkle 私钥丢失 = 永久失效**:备份 ≥ 2 处

---

## 5. 综合方案:分阶段落地

### Phase 1(Day 1–3):Apple Developer + 域名

- [ ] 申请 Apple Developer Program Individual(99 USD/年)
- [ ] 生成 Developer ID Application 证书,导出 `.p12`(备份!)
- [ ] 生成 App Store Connect API Key `.p8`(记录 Key ID + Issuer ID)
- [ ] 购买域名(例如 `whisperutil.app` 或新命名的 `.app`/`.com`),DNS 托管到 Cloudflare
- [ ] **手动**跑一遍完整流程:archive → export → sign → notarize → staple → DMG,确保本机能产出可分发版本

### Phase 2(Day 4–7):官网 + 落地页

- [ ] 在本仓新增 `/website` 子目录,写一个纯静态 landing page(index.html + 一张截图 + Download 按钮指向 `.../releases/latest/download/WhisperUtil.dmg`)
- [ ] Cloudflare Pages 项目接入本仓,Root Directory = `website`,Build Watch Paths = `website/**`
- [ ] 域名 CNAME 到 CF Pages
- [ ] 贴 CF Web Analytics script

### Phase 3(Day 8–14):CI/CD 自动化

- [ ] 将 MARKETING_VERSION 抽到 `Config/Version.xcconfig`
- [ ] 提交 `ci/ExportOptions.plist`
- [ ] 配置 GitHub Actions secrets(见 4.9)
- [ ] 提交 `.github/workflows/release.yml`(见 4.10)
- [ ] 打一个 `v0.1.0-alpha` tag 验证全流程
- [ ] 官网下载按钮确认指向 `/releases/latest/download/...`

### Phase 4(Day 15–21):Sparkle + 下载埋点

- [ ] `./bin/generate_keys` 生成 EdDSA 私钥,**立刻备份 ≥ 2 处**
- [ ] 新建 `whisperutil-appcast` 独立仓,开 GitHub Pages;自有域名子域 CNAME
- [ ] 把 Sparkle 2 SPM 加入 WhisperUtil,配置 `SUPublicEDKey` / `SUFeedURL`
- [ ] workflow 增加 Sparkle sign + appcast 更新步骤
- [ ] 创建 `whisperutil-dl` Cloudflare Worker,`/latest` 重定向 + Analytics Engine 埋点
- [ ] 落地页 Download 按钮改指向 `https://dl.whisperutil.app/latest`
- [ ] `.github/workflows/stats.yml` 每日 cron 拉 GH Releases API download_count

### Phase 5(Day 22+):运营优化

- [ ] 发正式版本 `v0.1.0`
- [ ] 观察 CF Web Analytics + Analytics Engine 数据,判断哪些 referrer 有效
- [ ] 视情况考虑加 opt-in 应用内 telemetry(TelemetryDeck)

---

## 6. 决策耦合关系(为什么这些决策要一起考虑)

- **Apple Developer 账号类型** 决定 Developer ID 证书的 Seller Name,影响 Gatekeeper 对话框文案、App Store 卖家名——**一旦面向真实用户发版后,再想改会很麻烦**(虽然可迁移,但有 1–3 周空窗)。所以 **Day 1** 就要定。
- **Sparkle `SUFeedURL`** 一旦发版到用户机器就**永久不可改**——所以 Phase 4 之前必须把自有域名和 appcast 托管策略定死。
- **官网域名**同时被 CF Pages(www)、CF Worker(dl.)、GH Pages(appcast.)三处 CNAME 使用——统一在 Cloudflare DNS 托管能减少协调成本。
- **GH Actions 免费额度**要求仓库保持公开;如果将来想闭源,macOS runner 成本会从 0 跳到可观数字(macos-15 按 10× Linux 计算),届时需重新评估是否自托管 Mac mini。
- **改名** 如果打算把 WhisperUtil 改名,应在 Phase 1 之前决定:Bundle ID、Team ID、Developer ID 证书、域名、GH 仓名、所有 secrets 引用名都会牵动。已经发版后再改名 = Sparkle 自动更新链断裂的高风险动作。

---

## 7. 参考资料

### 官网仓库策略
- [AltTab docs/ 目录](https://github.com/lwouis/alt-tab-macos/tree/master/docs)
- [GitHub Pages 发布源配置](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
- [Cloudflare Pages Monorepos](https://developers.cloudflare.com/pages/configuration/monorepos/)
- [Cloudflare Pages Build Watch Paths](https://developers.cloudflare.com/pages/configuration/build-watch-paths/)
- [Vercel Monorepos](https://vercel.com/docs/monorepos)

### Apple Developer Program
- [Become a member](https://developer.apple.com/programs/enroll/)
- [Choosing a Membership](https://developer.apple.com/support/compare-memberships/)
- [D-U-N-S® Number](https://developer.apple.com/help/account/membership/D-U-N-S/)
- [Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Safely open apps on your Mac](https://support.apple.com/en-us/102445)
- [Individual → Organization 迁移论坛](https://developer.apple.com/forums/thread/132156)

### 下载监控
- [GitHub REST API - release assets](https://docs.github.com/en/rest/releases/assets)
- [Cloudflare Web Analytics docs](https://developers.cloudflare.com/web-analytics/about/)
- [Cloudflare Workers Analytics Engine](https://developers.cloudflare.com/analytics/analytics-engine/)
- [Plausible self-hosted](https://plausible.io/docs/self-hosting)
- [Umami](https://umami.is/)
- [TelemetryDeck for Swift](https://telemetrydeck.com/platforms/swift/)

### CI/CD 与 Sparkle
- [Apple Notarytool man page](https://keith.github.io/xcode-man-pages/notarytool.1.html)
- [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Apple-Actions/import-codesign-certs](https://github.com/Apple-Actions/import-codesign-certs)
- [Sparkle Publishing Documentation](https://sparkle-project.org/documentation/publishing/)
- [Sparkle EdDSA Migration](https://sparkle-project.org/documentation/eddsa-migration/)
- [sindresorhus/create-dmg](https://github.com/sindresorhus/create-dmg)
- [Automating Sparkle Updates (Cindori)](https://cindori.com/developer/automating-sparkle-updates)
- [federicoterzi: Signing/Notarization on GitHub Actions](https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/)
- [GitHub Actions 2026 Pricing Changes](https://github.com/resources/insights/2026-pricing-changes-for-github-actions)
