# 项目进度文档：eink-truescale-pdf

> 快照日期：2026-08-07  
> 主仓库：`/Users/km/projects/print-to-quaderno`  
> GitHub：<https://github.com/leekaomin380/eink-truescale-pdf>  
> 本文只记录当前可核对状态；历史设想请查 `docs/PRD.md` 与 `TODO.md`

## 1. 总体结论

项目已经越过原型阶段，形成了可构建、可测试、可签名和可公开下载的 Quaderno 版，同时完成了去除厂商投递能力的 Mac App Store 通用版。

当前不是功能缺失阻碍发布，主要阻塞是：

1. App Store 1.1.0 Build 2 由 beta 版 macOS 构建，Apple 以 `ITMS-90301` 拒绝该二进制；需要在正式版 macOS 环境重新归档和上传。
2. App Store 携带 Pandoc 的 GPL/App Store 条款兼容性仍需专业法律判断；现有工程已履行许可文本和对应源码准备，但这不是最终法律结论。
3. 最新的 Quaderno 底部按钮可见性修复已经在本地分支提交，但尚未合并进 `master`、尚未推送，也尚未进入 GitHub Release。

## 2. 当前版本与分支

### 2.1 Quaderno 直装版

| 项目 | 当前状态 |
|---|---|
| 工作目录 | `/Users/km/projects/print-to-quaderno` |
| 当前分支 | `codex/fix-quaderno-footer-actions` |
| 当前提交 | `136d5f6` — 保持底部 Quaderno 操作按钮可见 |
| `master` / `origin/master` | `b165e05` |
| 发布标签 | `quaderno-v1.1.0` |
| GitHub Release | Quaderno Converter 1.1.0，已公开发布 |
| 发布资产 | `Quaderno-Converter-1.1.0-macOS-arm64.zip` 及 SHA-256 文件 |
| 本机安装 | 1.1.0（Build 2），Apple Development 本地签名 |
| 自动测试 | 2026-08-07 实跑：50 项断言全部通过 |

GitHub 上的 1.1.0 Release 位于：

<https://github.com/leekaomin380/eink-truescale-pdf/releases/tag/quaderno-v1.1.0>

注意：GitHub Release 基于 `b165e05`，不包含本地 `136d5f6` 的底部操作区修复。若要让其他用户得到该修复，需要合并、重新用 Developer ID 构建并公证，然后发布 1.1.1 或替换资产；推荐使用新版本号，不覆盖已发布资产。

### 2.2 Mac App Store 通用版

| 项目 | 当前状态 |
|---|---|
| 工作目录 | `/Users/km/projects/wt-document-to-pdf-appstore` |
| 分支 | `codex/appstore-v1.1.0` |
| 当前提交 | `3369fe6` |
| 远端 | `truescale/main` 与 `truescale/codex/appstore-v1.1.0` 均为 `3369fe6` |
| 标签 | `v1.1.0` |
| App 名称 | Epub 转 PDF · 本地转换 |
| App Apple ID | 6797372953 |
| 已提交版本 | 1.1.0（Build 2） |
| 自动测试 | 2026-08-07 实跑：74 项断言全部通过 |
| ASC 状态 | Apple 邮件报告二进制无效，错误 `ITMS-90301` |

已知拒绝原文要点：Apple 当前不接受使用该 OS 版本构建的应用。此前排查确认当前开发机运行 beta 版 macOS，因此代码、功能测试通过并不能解决该平台来源问题。

下一次 App Store 构建必须在可运行受 Apple 接受的正式版 Xcode、且宿主为正式版 macOS 的 Mac 上完成。家人的 Mac 不必预先安装 Xcode，但在承担归档和上传任务前需要安装匹配的正式版 Xcode，并导入开发者账号所需的签名能力。

## 3. 功能完成度

### 3.1 转换内核

| 能力 | 状态 | 说明 |
|---|---|---|
| EPUB → PDF | 已完成 | 目录、大纲、章节分页、元数据继承 |
| FB2 → PDF | 已完成 | 走 Pandoc/Typst 公共流程 |
| Markdown → PDF | 已完成 | 已防护 `@`、邮箱和 `$变量` 等歧义输入 |
| HTML/HTM → PDF | 已完成 | 支持本地相对图片、中文和空格路径 |
| HTML 容器内 H1 分章 | 已修复 | 解决 Typst container pagebreak 错误 |
| HTML 数学公式 | 已修复 | 不再把公式源码直接排入 PDF |
| MOBI/AZW | 条件支持 | 需用户另装 Calibre；DRM 文件不支持 |
| PDF 页面尺寸统一检查 | 已完成 | 使用 PDFKit 检查全书页面 |
| 无 Homebrew 最终用户运行 | 已完成 | 应用内置 arm64 Pandoc、Typst、GNU MP |

### 3.2 Quaderno 版 GUI

| 能力 | 状态 | 说明 |
|---|---|---|
| 文件转换 | 已完成 | EPUB、HTML、FB2、Markdown |
| 粘贴文本 | 已完成 | 含标题、Markdown、清空与撤销 |
| 网页链接 | 已完成但边界受限 | 任意网页尽力抽取；不处理重 JS、付费墙和强反爬 |
| 排版设置 | 已完成 | 字体、字号、边距、行距、设备、页脚时间 |
| 偏好持久化 | 已完成 | 保存值会校验，失效时回退 |
| PDF 多页预览 | 已完成 | 页码跳转和比例预览 |
| 发送到 Quaderno | 已完成 | 检测官方 App；投递副本保护原产物 |
| 另存 PDF | 已完成 | 自动保证内容与参数是最新版本 |
| 底部按钮可见性 | 本地已修复 | `136d5f6`；待合并并进入下一发布包 |
| 长文档进度反馈 | 未完成 | 转换期间目前主要显示状态文字，没有细粒度进度 |

### 3.3 App Store 版 GUI

| 能力 | 状态 | 说明 |
|---|---|---|
| 文件选择与拖放 | 已完成 | EPUB、HTML、FB2、Markdown |
| A4/A5/B5 | 已完成 | 有直观中文说明，默认 A4 |
| 排版设置与预览 | 已完成 | 与公共转换内核一致 |
| App Sandbox | 已完成 | 测试覆盖 entitlements 与安全域资源管理 |
| 隐私政策与支持页 | 已完成 | 无账号、无遥测、无网络访问 |
| Quaderno 代码路径移除 | 已完成 | 不含发送、客户端检测或厂商依赖 |
| 网页链接解析 | 明确不包含 | 等版权、访问授权与平台规则进一步明确后再评估 |
| ASC 元数据 | 已填写 | 免费；首发范围仅中国大陆；推广文本可留空 |
| 可接受的新二进制 | 阻塞 | 需要正式版 macOS 构建机 |

## 4. 工程与质量状态

### 4.1 当前验证

- Quaderno 分支 `./test.sh`：50 项断言全部通过。
- App Store 分支 `./test.sh`：74 项断言全部通过。
- Quaderno 修复版已在本机签名、安装并通过可访问性树与截图确认，“预览 / 发送到 Quaderno / 另存 PDF”均位于可视底部。
- GitHub 最新 Release 与两个资产当前可访问；发布包架构为 arm64。
- 两个工作区在检查时均无未提交修改。

### 4.2 已固化的历史故障

- 页面尺寸混杂或不是目标尺寸。
- `@词`、邮箱、`$变量` 被 Pandoc 扩展误判。
- EPUB 内部锚点使整本书渲染中止。
- `book.sh -o` 相对路径产物被临时目录清理。
- 修改排版参数后预览仍显示旧 PDF。
- 换输入后直接另存或发送，输出上一份文档。
- 应用只签二进制、不签 Bundle，导致下载后显示“已损坏”。
- 本地 HTML 数学公式显示为源码。
- HTML 容器内分页触发 Typst 错误。
- SwiftUI 纵向压缩使“发送到 Quaderno”落到窗口外。

## 5. 分发与合规状态

### 5.1 已完成

- 项目源代码已公开到 GitHub。
- Quaderno 1.0.0 与 1.1.0 GitHub Release 已发布。
- 发布版构建脚本支持把运行时依赖、许可文本和第三方说明打入 App。
- App Store 版准备了隐私政策、支持页、隐私清单、沙盒权限和对应源码包。
- App Store 版已经移除 Quaderno 与网页抓取，定位为本地文件转换。

### 5.2 尚未闭环

- Quaderno `136d5f6` 修复未进入公开版本。
- 当前钥匙串在本次检查时没有 Developer ID Application 私钥，只有 Apple Development 与 Apple Distribution；因此本机修复版可测试，但不能据此制作新的站外公证分发包。
- App Store 新二进制尚未在正式版 macOS 构建机生成。
- Pandoc/GPL 与 App Store 条款的最终法律兼容性没有专业法律意见。
- 网页解析涉及网站条款、著作权及访问边界，现阶段不进入 App Store 版，也不作为内容分发能力宣传。

## 6. 已知限制与风险

| 风险 | 当前处理 |
|---|---|
| Intel Mac 不支持当前发布包 | README 和许可文档明确仅 Apple Silicon |
| A4 Quaderno 物理参数未真机实测 | 保留未验证标记，不宣传为确定值 |
| 大体积文件或极长文档的上限未知 | 已有数百页样本成功，但仍需压力测试 |
| 动态 HTML 无法静态转换 | 明确提示改用“粘贴文本” |
| 复杂 CSS 无法像素级复刻 | 定位为结构化重新排版，不是网页截图 |
| 第三方内容版权与网站授权 | 用户只转换有权访问的内容；App Store 版不含网页功能 |
| 旧文档与当前代码不一致 | 本文与 `docs/PRODUCT.md` 作为当前入口，旧文档保留为历史证据 |

## 7. 下一步建议

### P0：恢复可发布状态

1. 将 `136d5f6` 合并到 Quaderno `master`，推送并运行完整测试。
2. 恢复或重新签发 Developer ID Application 证书及私钥。
3. 构建、签名、公证 Quaderno 1.1.1，在一台无开发环境的 Apple Silicon Mac 上做下载—安装—转换—发送验收，再发布 GitHub Release。
4. 在正式版 macOS 的 Mac 上安装正式版 Xcode，检出 App Store `3369fe6`，生成新的递增 Build，上传后确认状态为 `VALID`。
5. 只有在新构建有效并再次获得明确授权后，才重新提交 App Store 审核。

### P1：提高转换可靠性

1. 为大 HTML、超大 EPUB 增加阶段进度与超时/资源错误提示。
2. 建立一组可公开的真实复杂样本：长书、本地图片、表格、脚注、公式、中文路径。
3. 验证脚注/尾注视觉表现、极大文件上限以及 Calibre 的 MOBI/AZW 实际路径。
4. 增加导出前摘要：输入格式、页数、目标规格、预计文件大小和保存位置。

### P2：产品化与国际化

1. 完成中英文界面与错误信息统一，再扩大 App Store 地区范围。
2. 根据真实需求决定是否在“更多尺寸”中加入 Letter 等海外规格，默认仍保持 A4/A5/B5。
3. 建立支持问题模板和版本化故障记录，避免用户发送敏感原文档。
4. 等法律边界明确后再单独评估网页解析；不要把该模块与本地文件转换默认捆绑。

## 8. 接手说明

建议新接手者按以下顺序阅读，避免被历史文档带偏：

1. `docs/PRODUCT.md`（当前产品边界）。
2. `docs/PROGRESS.md`（当前完成度与阻塞）。
3. `README.md`（Quaderno 直装版使用与分发）。
4. `book.sh`、`deliver.sh`、`deliver.typ`、`book-filter.lua`（转换核心）。
5. `gui/mac/ContentView.swift` 与 `gui/mac/ConversionViewModel.swift`（GUI 主路径）。
6. `test.sh`（真实事故形成的不变量）。
7. `THIRD-PARTY-LICENSES.md`（二进制分发义务）。
8. `docs/PRD.md`、`TODO.md`、`docs/development-log-zh.md`（历史背景，不作为当前状态源）。

App Store 版本需切换至 `/Users/km/projects/wt-document-to-pdf-appstore` 单独阅读和构建，不要在 Quaderno 主工作区直接删除厂商功能。

