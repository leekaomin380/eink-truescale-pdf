# iPhone → Quaderno 投递 · 配置指南

> 链路：iPhone（原生 App / 快捷指令）→ 同一 Wi-Fi → Mac 中继服务（`iphone_relay.py`）→ 官方 QUADERNO PC App → 设备
>
> 两条 iPhone 侧通道，二选一或并存：
> - **方案 A（推荐）**：iOS 原生 App `SendToQuaderno` —— 出现在系统分享面板（含微信「···→更多」），有历史记录与状态回传
> - **方案 B（免装 App）**：快捷指令 —— 配置简单，但依赖快捷指令搭建，微信分享入口不稳定

---

## 一、Mac 侧：安装并启动中继服务（一次，两方案共用）

1. 安装 launchd 服务（开机自启、崩溃自动拉起）：

   ```bash
   mkdir -p ~/Library/LaunchAgents
   cp "/Users/km/projects/归档/print-to-quaderno/relay/com.km.p2q-iphone-relay.plist" \
      ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.km.p2q-iphone-relay.plist
   ```

2. 确认服务已启动：

   ```bash
   curl http://127.0.0.1:8790/health
   # 期望输出 {"ok": true, "client_installed": true}
   ```

3. 查看鉴权 token（快捷指令里要填）：

   ```bash
   cat ~/.config/p2q-relay/token
   ```

4. 确认 Mac 的局域网地址：本机名为 `gaomingdeMacBook-Air`，
   即 iPhone 侧填写的服务器地址为 **`gaomingdemacbook-air.local:8790`**。
   （若快捷指令连不上，可在「系统设置 → 通用 → 共享 → 本地主机名」核对。）

5. 日常检查/重启：

   ```bash
   tail -20 /tmp/p2q-relay.log                                # 看日志
   launchctl kickstart -k gui/$(id -u)/com.km.p2q-iphone-relay  # 重启服务
   launchctl unload ~/Library/LaunchAgents/com.km.p2q-iphone-relay.plist  # 停用
   ```

## 二、方案 A：iOS 原生 App（SendToQuaderno）

工程位于 `ios/SendToQuaderno`（XcodeGen 工程，SwiftUI 主 App + Share Extension，零第三方依赖）。

### 构建（一次）

1. 生成并打开工程：

   ```bash
   cd "/Users/km/projects/归档/print-to-quaderno/ios/SendToQuaderno"
   xcodegen generate
   open SendToQuaderno.xcodeproj
   ```

2. 在 Xcode 中：选中 SendToQuaderno target → Signing & Capabilities →
   **Team 选择你的开发者账号**（ShareExtension target 同样要选）。
   App Group `group.com.figedu.sendtoquaderno` 会随签名自动注册。
3. iPhone 用数据线连接，设备选择你的 iPhone → **⌘R** 运行。
   首次需在 iPhone「设置 → 通用 → VPN 与设备管理」信任开发者证书。
4. 编译验证基线：2026-10-22 于 iOS 27.0 SDK 模拟器构建通过（CODE_SIGNING_ALLOWED=NO）。

### App 内配置（一次）

打开 App → 「服务器设置」→ 填 Mac 地址（`gaomingdemacbook-air.local`）与 token →
「测试连接」显示 ✅。

### 日常使用

| 场景 | 操作 |
|------|------|
| 微信公众号文章 | 文章 ··· → 更多 → 分享面板 → **投递到Quaderno** |
| Safari 网页 | 分享 → 投递到Quaderno |
| 任意 App 中的文字 | 拷贝 → 打开 App → 「投递剪贴板内容」 |

主 App 显示每条投递的标题、页数、真实送达状态。

## 三、方案 B：快捷指令（免装 App）

打开「快捷指令」App → 右上角 **+** 新建，按顺序添加以下动作：

| # | 动作 | 配置 |
|---|------|------|
| 1 | **文本** | 内容填 JSON 模板（见下） |
| 2 | **获取 URL 内容** | 方法 POST；URL 填 `http://gaomingdemacbook-air.local:8790/deliver`；请求头添加 `X-Relay-Token` = 第一步查到的 token；请求体选「JSON」，键 `body` 的值引用动作 1 的「文本」 |

动作 1 的文本内容（原样填入，两处占位符替换）：

```json
{"type": "快捷指令自动判断", "content": "输入", "url": "输入", "title": ""}
```

无法在单个「文本」动作里做条件判断，因此推荐做成**两个快捷指令**，或用「如果」动作：

- 动作 0：**如果**「快捷指令输入」**有值** → 设变量 `内容` 为快捷指令输入；
  **否则** → 设变量 `内容` 为「获取剪贴板」。
- 判断 `内容` 是否以 `http` 开头 → 决定 JSON 里 `type` 填 `url` 还是 `text`，
  `url`/`content` 字段都填变量 `内容`。

最后加反馈动作：

| # | 动作 | 配置 |
|---|------|------|
| 3 | **获取词典值** | 取「获取 URL 内容」结果里的 `detail`（和 `status`） |
| 4 | **显示提醒 / 显示通知** | 内容为 `投递结果：detail` |

`status` 含义：
- `delivered` —— 客户端已接收，设备上将出现该文档
- `offline` —— 设备离线或未连接
- `cancelled` —— 投递被取消
- `unconfirmed` —— 已交客户端但 45 秒内未确认，检查设备连接
- `client-missing` —— Mac 上没有官方客户端

在快捷指令详情里打开 **「在分享表中显示」**，接受类型勾选「文本」和「URL」。

## 四、日常使用方式（方案 B 快捷指令）

| 场景 | 操作 |
|------|------|
| Safari / 备忘录 / 任何 App 中的文字 | 选中 → 拷贝 → 运行快捷指令（可绑定「轻点背面」或桌面图标） |
| Safari 网页 | 分享 → 快捷指令「投递到 Quaderno」 |
| 微信公众号文章 | 文章右上角 ··· → **更多** → 系统分享表 → **快捷指令**（若列表中没有，先复制链接，再运行快捷指令，剪贴板兜底逻辑会自动取链接） |

## 五、硬约束与已知边界

1. **最终一跳必须经 Mac**：设备须与 Mac 上的官方客户端连接（USB 或客户端无线模式；无线模式耗电，按需开启）。
2. **Mac 须开机且与 iPhone 同一 Wi-Fi**（`.local` 域名只在局域网内解析）。
3. 公众号文章抽取为正文结构化重排，非网页截图；webp 格式图片会被跳过（Typst 不支持）。
4. 非微信的普通网页走兜底抽取（`<article>` 优先，否则纯文本），排版质量尽力而为。
5. 付费墙/登录内容不抓取，遵守网站访问边界。
6. token 是唯一鉴权凭据，存于 `~/.config/p2q-relay/token`（权限 600），不要写进 git 或聊天记录。

## 六、真机验收清单（设备连接后执行一次）

- [ ] Mac 上 `curl -X POST http://127.0.0.1:8790/deliver ...` 文本投递，返回 `status: delivered`
- [ ] iPhone 快捷指令投递一段文字，设备上打开排版正常（字号物理 1:1）
- [ ] 微信文章「···→ 更多 → 快捷指令」路径可用
- [ ] 设备离线时快捷指令能显示 `offline/unconfirmed` 提示
