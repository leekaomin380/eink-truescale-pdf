# print-to-quaderno · 剪贴板 → Quaderno 墨水屏 · 零 GUI 投递管道

一个全局热键,把系统剪贴板里的 Markdown 源码瞬间渲染成排版精良的 PDF,静默打入
Quaderno 同步队列。无头、后台、不抢焦点。彻底消灭「复制 → 开 Bear → 粘贴 → Cmd+P →
在下拉菜单里找 Print to QUADERNO」这条 GUI 摩擦链。

```
复制 Markdown  ──►  按热键 (⌃⌥⌘P)  ──►  墨水屏出现
```

---

## 快速使用

1. 复制一段 Markdown(通常来自 Claude / Gemini 等对话产出)
2. 按全局热键
3. 右上角通知 `Quaderno ✅ 已投递 · N 字`,几秒后墨水屏显示

热键由 macOS「快捷指令」托管:一个「运行 Shell 脚本」动作,内容仅一行
`/Users/km/projects/print-to-quaderno/deliver.sh`,在详细信息里绑键盘快捷键。

---

## 依赖

| 组件 | 角色 | 安装 |
|---|---|---|
| `pandoc` | Markdown 语法树解析 | `brew install pandoc` |
| `typst` | PDF 光栅化引擎(极速 Rust,替代 pdflatex) | `brew install typst` |
| QUADERNO PC App | 投递客户端(直连设备上传) | 官方 |
| macOS 快捷指令 | 全局热键托管外壳 | 系统自带 |

字体:`Charter`(拉丁,Matthew Carter 为低分辨率屏设计)+ `PingFang SC`(中文,苹方)
——均为系统自带,墨水屏边缘干净。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `deliver.sh` | 主管道:抓剪贴板 → 渲染 → 后台投递 → 监听送达 → 通知反馈 |
| `deliver.typ` | 定制 pandoc typst 模板;字体行改成 `for` 循环,由脚本注入 fallback 列表 |
| `README.md` | 本文档 + 开发日志 |

---

## 数据流架构

```
pbpaste ──► [空检测] ──► pandoc -f markdown --template=deliver.typ
                                   │  -V mainfont=Charter -V mainfont="PingFang SC"
                                   ▼
                          typst 引擎渲染 PDF  ──► /tmp/quaderno_delivery_$$.pdf
                                   │  [渲染失败拦截]
                                   ▼
              open -gj -na "QUADERNO PC App" --args --print <pdf>   (后台/不抢焦点)
                                   │
                                   ▼  客户端 device.printDocument() 上传设备,并 unlink 源文件
                          [监听日志 + 源文件消费] ──► ✅ / ❌ / ⚠️ 系统通知
```

底层协议来自逆向 `/Library/PDF Services/Print to QUADERNO.workflow` 里的
`document.wflow`,挖出 `open -na "…QUADERNO PC App.app" --args --print "$1"`,
从而绕过 macOS 打印总线直呼客户端。

---

## 开发日志

### 2026-07-18 · 从裸命令到生产级管道(建立 + 定型)

**起点**:已有跑通的原子命令
`cd /tmp && pbpaste | pandoc -f markdown -o x.pdf --pdf-engine=typst && open -na "…" --args --print x.pdf`。
本次目标:固化成健壮、可被全局热键托管的外壳,并实测所有未知量。

**真相测试(实测,非推断)**
- **是否弹窗** —— 触发投递后截屏观察:客户端**完全不弹窗**(无对话框/预览/确认)。零 GUI 成立。
- **中文 CJK** —— typst 0.15 在 macOS 上自动 fallback 到系统中文字体,**开箱即用零豆腐块**,无需手动配字体。
- **是否真送达** —— 受控投递(唯一文件名 + 日志行数基线):源文件被客户端 `unlink` 消费、
  日志零新增 error → 静默上传成功。物理墨水屏肉眼确认无误。

**从客户端日志(`~/Library/Application Support/Fujitsu/QUADERNO PC App/…/logfile.log`)挖出的底层真相**
1. 投递是 **`device.printDocument()` 直连设备上传**,不是"扔进云队列不管"。
   → 成败取决于按键当刻设备是否已连接;离线则 `E_MW_DEVICE_NOT_FOUND` **静默失败**(只写日志)。
2. 客户端上传后会 **`unlink` 源 PDF**。→ 临时文件自清理,无需处理文件名冲突;但投递后源即消失。
3. 客户端**只在失败时**往日志写 error。→ 这成了脚本判定送达结果的依据。

**踩过的坑(全部已修,勿重蹈)**
| 坑 | 现象 | 根因 | 修复 |
|---|---|---|---|
| **只读根目录** | pandoc 崩 `Read-only file system` | 带图 MD 在 `/` 建临时目录 | 强制 `cd /tmp` 沙盒 |
| **中文乱码** | 设备中文全乱、ASCII 正常 | 最小化环境 `LANG=` 空,pandoc 回退 latin1 | 脚本内 `export LANG/LC_ALL=en_US.UTF-8` |
| **找不到 pandoc** | 热键触发即 ❌ | 快捷指令的 PATH 仅 `/usr/bin:/bin`,无 Homebrew | 脚本内 `export PATH` 补 `/opt/homebrew/bin` |
| **抢焦点/端口冲突** | 弹前台 + 日志 `EADDRINUSE:808x` | `open -na` 的 `-n` 硬启新实例 | 改 `open -gj -na`(后台+隐藏,靠单实例句柄转交) |
| **静默失败** | "以为发了其实没到" | 设备离线时客户端只记日志不提示 | 脚本监听日志 error + 源文件消费,给 ✅/❌/⚠️ 通知 |
| **冯·诺依曼死锁** | 手动复制脚本会覆盖待渲染文本 | 指令与数据共用剪贴板 | 独立外壳 + 全局热键托管,指令/数据物理隔离 |

**字体决策**:对比 `Charter+苹方` 与 `Charter+宋体` 两版投到设备 A/B —— 两者皆可,
默认取**苹方**(无衬线、边缘最干净),字体做成可扩展 fallback 列表保留后续切换。
放弃 typst 默认的 New Computer Modern:发丝笔画在 16 级灰阶墨水屏上糊成毛边。

**验证方式备忘**:本机 Bash 沙盒**跨调用不保留系统剪贴板**;测试时用
`osascript -e 'set the clipboard to (read POSIX file "…" as «class utf8»)'` 直写系统剪贴板,
再 `pbpaste` 读回;用 `env -i HOME=… PATH=/usr/bin:/bin …` 模拟快捷指令最小环境验证自愈。

---

## 排错手册

| 通知 | 含义 | 处理 |
|---|---|---|
| `✅ 已投递 · N 字` | 客户端已接收上传 | 正常,等墨水屏同步 |
| `❌ 剪贴板为空` | 没复制内容 | 先复制 |
| `❌ 渲染失败: …` | pandoc/typst 报错(含原因摘要) | 看 Markdown 语法 |
| `❌ 设备离线或投递被取消` | 日志出现 device-not-found/cancelled | 确认 Quaderno 已连接客户端 |
| `⚠️ 已交客户端但未确认送达` | 超时未见消费也未见 error | 检查设备连接/客户端状态 |

---

## 未来扩展

- **加/换字体**:只改 `deliver.sh` 顶部 `FONTS=("Charter" "PingFang SC")`,往数组追加 fallback。
- **富文本源**:当前吃纯文本 Markdown。若要吃网页 HTML,pandoc 加 `-f html` 分支即可。
- **保留副本**:客户端会删源 PDF;如需留底,在投递前 `cp` 一份到别处。
