# CFR：TrueScale for QUADERNO 鲁棒性审计 · 2026-11-04

## 1. 范围与访问

- **代码**：本地仓库 `fix/usb-link-stuck-reenumerate` 分支（HEAD `e6a7d75`）。审计只读，没有改动任何代码。
- **审计对象**：
  - `direct/quaderno_direct.py`：直连运行时
  - `deliver.sh`
  - `gui/mac/*.swift` 中的子进程调用、USB 监视和历史读取
  - `gui/build-app.sh`、`gui/release-github.sh`、`direct/build-helper.sh`
- **两遍都跑了**：
  - Pass A：静态白盒
  - Pass B：失效注入推演，结合今天的内核日志、`pmset` 日志和 `history.jsonl`
- **未覆盖**：
  - `ContentView`、`DeviceFilesView` 的 UI 状态机
  - `wechat/*` 网页抽取
  - `book.sh` 的排版细节
  - `relay/`、`ios/`、`site/`

### 边界（X 轴，按信任级别 / 运行环境）

| 区 | 内容 |
|---|---|
| B1 用户入口 | ⌃1 / ⌃2 热键、Finder 右键、主窗口、菜单栏 |
| B2 编排层 | Swift `Process` → `deliver.sh`（zsh）→ 直连运行时（PyInstaller） |
| B3 本地状态 | 配对凭据、`endpoint-cache.json`、`history.jsonl`、`transfer.lock`、临时 PDF |
| B4 系统接口 | `ioreg` / `dns-sd` / `curl` / 串口 `/dev/cu.*` / IOKit |
| B5 外部黑盒 | QUADERNO 设备固件（HTTPS API、USB gadget）、QUADERNO PC App（兜底投递） |
| B6 构建与发布 | build-helper → build-app → release-github |

## 2. 边界 × 威胁矩阵（只列有内容的格子）

| 边界 × 向量 | 潜在崩塌点 | 现有防御（证据） | 风险 | 状态 |
|---|---|---|---|---|
| B4/B5 × 状态与时序 | 多步创建（POST 建条目 → PUT 内容）中途断开 | 没有回滚 `quaderno_direct.py:769-773` | **P1** | 确认 |
| B5 × 容错 | 大文件上传、回读超过固定 120 s | `--max-time 120` 不随文件大小调整 `:556` | P1 | 确认（阈值待验） |
| B2 × 可用 | 子进程管道写满导致死锁 | `runShell` 先 wait 后读 `ConversionViewModel.swift:1040` | **P1** | 确认（触发量待验） |
| B6 × 完整 | 打包时用了旧的直连运行时 | 只检查运行时是否存在 `build-app.sh:98` | **P1** | 确认（今天实际发生） |
| B6 × 完整 | 发布前不跑测试 | `release-github.sh` 没有测试或工作区检查 | P2 | 确认 |
| B2 × 容错 | 本地错误被错报成设备或配对问题 | `main()` 的兜底分类 `:1308/:1312` | P2 | 确认 |
| B1 × 完整 | 非 UTF-8 文本投递失败 | `read_text()` 不指定编码 `:1168` | P2 | 确认（11-02 有一次相关失败，来源待验） |
| B2 × 完整 | stderr 混进 stdout，导致 JSON 解析失败 | `DirectDelivery.swift:23` | P2 | 确认（触发待验） |
| B4 × 容错 | 串口切换只尝试一次，失败后不重试 | `QuickSendView.swift:108` | P2 | 确认（对应 18:05 现象） |
| B4 × 可用 | 在主线程上 `tcdrain` | `QuickSendView.swift:48/88/217` | P2 | 确认（阻塞是否会发生待验） |
| B3 × 并发 | 30 s 锁上限短于单次事务时长 | `connection_lock(timeout=30)` `:1079` | P2 | 确认 |
| B5 × 状态 | 兜底投递超时后副本仍留着，重试会产生重复 | `:961` | P2 | 确认 |
| B4 × 容错 | `ioreg` 输出按严格 UTF-8 解码 | `:287/:402` 使用 `text=True` | P3 | 假设·待验（本机输出是合法 UTF-8） |
| B5 × 鉴权 | 与官方 App 的 nonce/会话交错 | 我们的锁只覆盖自己的进程 | — | 假设·待验 |
| B3 × 并发 | `history.jsonl` 读改写竞态 | 所有写入都在 `connection_lock` 内；GUI 只读 | — | 已防御 |
| B3 × 完整 | 下载时写出半个文件 | 临时文件加 `os.replace` | — | 已防御 |
| B5 × 完整 | 上传内容被损坏 | SHA-256 回读校验，并确认目录里有这个条目 | — | 已防御 |

## 3. 确认发现（按风险排序）

### P1-1 上传中途失败会在设备上留下孤儿条目，重试时文件名会被污染

- **边界 × 向量**：B4/B5 × 状态与时序（非幂等的多步远程事务）
- **证据**：
  - `upload()` 先在 `quaderno_direct.py:769` 调 `POST /documents2` 创建条目，拿到 `document_id`；再在 `:773` 调 `PUT .../file` 上传内容。
  - 从 PUT、回读到目录确认（`:782-790`），任何一步抛出异常，都没有删除已创建的条目。
  - `:766-767` 看到同名文件已存在时，会改名为 `<名字>_<8位hex>.pdf`。
- **影响**：USB 中途掉线是本项目最常见的故障（见调查文档）。掉线后设备的 Received 文件夹里会留下一个空的或不完整的条目。用户点「重试」，因为同名条目已存在，文件会以 `_ab12cd34.pdf` 后缀上传，结果是一个坏文件加一个改了名的好文件。
  - 空条目在设备上具体怎么显示，**待验**。
- **修复**（应用层，只能在这一层做）：
  - 在 `created` 之后用 `try/except` 包住后续步骤。失败时尽力调 `DELETE /documents/{id}`，`delete()` 已经实现了（`:79-81` 区段）。删除本身也失败时，把 `document_id` 写进 `record_failure`，下次连接时清理。
  - 回读不一致时同样删除坏条目。
  - 重试前先检查同名条目：如果它是上一次的孤儿（大小为 0 或哈希不一致），就覆盖或删除，不要改名。

### P1-2 `runShell` 管道死锁

- **边界 × 向量**：B2 × 可用
- **证据**：
  - `ConversionViewModel.swift:1040` 先 `proc.waitUntilExit()`，到 `:1042-1043` 才 `readDataToEndOfFile()`。
  - stdout 和 stderr 是两个独立的 `Pipe`，任何一个写满缓冲（macOS 约 64 KB），子进程就会阻塞在写入上，父进程则在等它退出。
  - 调用方有 `book.sh`（整本 EPUB，`:511`）、pandoc 导出（`:875`）、`typst fonts`（`:446`）。
- **实测**：
  - `typst fonts` 是 6.9 KB，目前安全。
  - `typst fonts --variants` 是 131 KB，说明字体相关输出很容易超过阈值。
  - 大书的 pandoc / typst 警告量不受控（**待验**：需要一本资源缺失多的 EPUB 来实测）。
- **影响**：GUI 的「转换整本书」永远停在进行中，没有超时，也没有报错。
- **修复**：先异步读完两个管道再 wait。可以用 `readabilityHandler` 累积数据，或者一个读线程配合 `readDataToEndOfFile`。`DirectDelivery.swift:26-27` 已经是「先读后等」的正确写法，可以照抄。

### P1-3 构建时可能打包旧的直连运行时

- **边界 × 向量**：B6 × 完整
- **证据**：
  - `gui/build-app.sh:98` 只检查 `runtime-dist/.../quaderno-direct` 是否存在，不比较它和 `direct/quaderno_direct.py` 的新旧。
  - `direct/build-helper.sh` 在 git 里的权限是 `100644`，没有执行位，`./direct/build-helper.sh` 会直接报 permission denied。
- **今天实际发生过**：helper 构建失败，`build-app.sh` 照样成功，产出的 App 里是旧的运行时。是事后从 PyZ 里解出脚本核对才发现的。
- **影响**：修复显示「已构建」，实际没生效。用户和开发者都很难察觉。
- **修复**（最底层：构建脚本）：
  - `build-app.sh` 自己调用 `zsh direct/build-helper.sh`；或者比较 mtime 或内容哈希，运行时比源文件旧就失败退出。
  - 给 `build-helper.sh` 加上执行位：`git update-index --chmod=+x`。

### P1-4 上传和回读的固定 120 s 上限

- **边界 × 向量**：B5 × 容错
- **证据**：
  - 所有请求共用 `--max-time 120`（`:556`）。
  - 上传（`:773`）和完整回读（`:782`）各自受这个上限约束，和文件大小无关。
  - EPUB 走 `book.sh` 排版后再整本上传（`deliver.sh` 的 `book_upload`）。
- **影响**：超过「USB 吞吐 × 120 s」的文件一定失败，而且失败在 PUT 之后，正好叠加 P1-1 的孤儿条目问题。
  - 具体阈值**待验**：需要实测 ECM 链路的上传和下载吞吐。
- **修复**：按文件大小设置 `--max-time`，例如 `30 + size / 最低吞吐`；同时设置 `--speed-limit` / `--speed-time`，用「持续低于 X B/s 超过 Y 秒」判定卡死，替代固定的总时长。这是 curl 原语，一处改动同时覆盖上传和回读。

### P2-1 错误分类会误导排查

- **证据**：
  - `main()` 把所有 `OSError` 报成「无法连接设备」（`:1308`），把其他非 `DirectError` 异常报成「设备协议或配对信息异常」（`:1312`）。
  - 本地的磁盘满、权限错误、解码错误（`UnicodeDecodeError` 属于 `ValueError`）都会被归因到设备或配对上。
  - 11-02 11:04 那条历史记录原样暴露了 `'utf-8' codec can't decode byte 0xb7`，说明另有路径把原始异常文本写进了历史（来源**待验**）。
- **修复**：
  - 本地 I/O（读输入、写临时文件）单独捕获，给出「本地文件」类提示。
  - 兜底分支保留异常类型名，例如「(UnicodeDecodeError)」，方便定位。

### P2-2 非 UTF-8 文本输入

- **证据**：`render_and_upload` 在 `:1168` 用 `read_text()` 读输入，没有指定编码；`prepare` 在 `:1252` 也一样。`deliver.sh` 固定使用 `LC_ALL=en_US.UTF-8`。
- **影响**：Finder 右键投递 GBK 或 UTF-16 编码的 `.txt` 会失败，而且错误提示具体落到哪一类，取决于异常在哪一层被抛出。
- **修复**：按顺序尝试 BOM 检测 → `utf-8` → `gb18030`。

### P2-3 GUI 把 stderr 合并进 stdout 后整体按 JSON 解析

- **证据**：`DirectDelivery.swift:22-23` 让两路输出共用一个管道，`:29` 对全部输出做 `JSONSerialization`。
- **影响**：运行时只要往 stderr 打出任何一行（`DeprecationWarning`、PyInstaller 提示），已经成功的投递也会显示为失败，消息变成泛化的「直连失败」。
- **修复**：stderr 分开收集，只解析 stdout，并且只取最后一行 JSON。

### P2-4 串口切换锁存，失败后不重试

- **证据**：
  - `QuickSendView.swift:108` 对同一个 `/dev/cu.*` 只尝试一次，直到拔掉设备才清空。
  - 写入的返回值没有用于判断设备是否真的切换了。
- **现象**：今天 18:05:21 到 18:06:40，设备在串口模式下停留了约 80 s，期间两次投递失败（时间线见调查文档）。
- **修复**：写入 5 s 后如果设备仍是 0x1656，就重试，最多 3 次。Python 侧的 `switch_to_network_mode` 也一样：写入后在等待窗口内没看到服务广播，就再写一次。

### P2-5 USB 监视在主线程上执行阻塞 I/O

- **证据**：
  - `QuickSendMonitor` 标注了 `@MainActor`（`:48`），`refresh()` 由主线程上的定时器触发（`:88`）。
  - `switchToNetworkMode` 里的 `tcdrain`（`:217`）不受 `O_NONBLOCK` 影响。
- **影响**：如果设备不读取串口，`tcdrain` 会一直阻塞，整个界面卡死。是否会发生**待验**。
- **修复**：把切换放到后台队列执行；或者不调 `tcdrain`，改为写入后关闭。

### P2-6 并发投递在 30 s 后直接失败

- **证据**：`connection_lock(timeout=30)`（`:1079`），而单次事务可能远超 30 s：
  - curl 最长 120 s
  - 兜底投递 60 s
  - 本次新增的链路恢复最长 12 s
- **影响**：大文件上传期间按 ⌃1，30 s 后报「另一项设备投递正在进行」，剪贴板投递直接丢失，不进入重试列表。
- **修复**：热键和 Finder 入口改成排队等待（等待上限和单次事务上限对齐），或者把失败写进历史，让用户可以重试。

### P2-7 兜底投递超时后，副本仍在官方 App 队列里

- **证据**：`hand_off` 的状态为 `unknown` 时不删除副本（`:961`），但同时报告失败，`record_failure` 也保留了原 PDF 以供重试。
- **影响**：官方 App 稍后完成投递，用户又点了重试，设备上就会出现两份。
- **修复**：失败消息里写明「官方 App 可能稍后送达」；重试前检查副本是否已被消费，或者 Received 里是否已有同名文件。

### P2-8 发布流程没有测试和工作区闸门

- **证据**：`release-github.sh` 只校验版本号和签名身份，不跑 `tests/`，也不检查 `git status` 是否干净。
- **修复**：发布脚本开头运行 `python -m unittest tests/test_direct_delivery.py` 和 `git diff --quiet`，与 P1-3 的运行时新鲜度检查合并成一个预检步骤。

### 本次修复（e6a7d75）自身的风险

- **Hardened Runtime 下的 ctypes / IOKit**：本地构建使用 ad-hoc 签名（`签名身份：-`），重新枚举已经验证可用。经 Developer ID 签名、开启 Hardened Runtime 并公证后，`IOCreatePlugInInterfaceForService` 和 ctypes 的 foreign function 调用能否正常工作，**待验**。下次发布前要在签名版上手动跑一次 `reenumerate_quaderno()`。
- **刚插入时的瞬态**：插入后链路有约 1 s 是 inactive（20:29:55→56）。另一个进程恰好在这个窗口内连接，会误判为链路卡住，多做一次重新枚举。代价只是多一次重连，但可以要求连续两次读到 inactive、间隔 1.5 s 才动手，避免这种情况。

## 4. 盲区与未验证（诚实清单）

- ECM 链路的实际吞吐还没测，P1-4 的阈值因此未知。
- `runShell` 死锁需要一个输出超过 64 KB 的真实样本才能复现。
- 11-02 那条 `0xb7` 解码错误的来源，可能是响应头或响应 JSON，没有定位。
- 与官方 App 并发时的认证交错没有观测数据。
- 设备 A 类掉线（掉出总线）的根因属于固件或硬件，软件无法修复，本次不覆盖。
- UI 状态机、网页抽取和 `relay/` 没有审计。

## 5. 收敛说明

- **第 1 轮**（运行时投递路径、GUI 子进程、构建链路）：得到 12 条代码确认的发现。
- **第 2 轮**（瞬时失败重试、与官方 App 的认证竞态、`ioreg` 解码、历史文件竞态、下载原子性）：没有新的确认缺陷，只有「待验」项和 3 处已确认的防御。

按规则停止。

---

## 6. 修复落地与验证（2026-11-04 21:20 后，接手续做）

- **范围声明**：后续用户指令为「修四个 P1」。§1–§5 的审计原文保持不变，本节只记录四个 P1 的改动、验证证据与新增观察。8 个 P2 未纳入本轮。
- **环境**：`fix/usb-link-stuck-reenumerate` 分支，HEAD `e6a7d75`；macOS arm64；真机 FUJITSU QUADERNO A5（FMVDP51，USB ECM 链路）。

### 6.1 四个 P1 的状态

| 编号 | 落地改动 | 验证证据 | 状态 |
|---|---|---|---|
| P1-1 孤儿条目 / Orphan Entry | `upload()` 用 `try/except BaseException` 包住 PUT → 请求打开 → SHA-256 回读；失败时 `discard_incomplete()` 尽力 `DELETE`，删除失败写 `orphans.json`（按设备 pin 隔离、上限 20 条），下一次上传前 `remove_orphans()` 先清理再取名。正常路径的「目录确认失败」不触发删除。 | 新增 3 个单测：PUT 失败 / GET 失败 / 哈希不一致均产生 `DELETE /documents/new`；删除失败被记忆且下次上传先清理、文件名不被污染；已校验内容在目录确认失败时保留。全套 60 个单测通过。 | 已修（真机失效注入 / Fault Injection 未做，未拔线） |
| P1-2 管道死锁 / Pipe Deadlock | `runShell` 改为 stderr 后台队列并发读、主线程读 stdout、`DispatchSemaphore` 排序后再 `waitUntilExit()`；新增 `PipeCollector` 容器。 | 合成样本 Swift 程序：stdout / stderr 各 200 KB。旧写法 4 s 内未退出被 kill（HUNG）；新写法完整读到 `(200000, 200000)`。真实 `book.sh` 大输出路径未跑。 | 已修（合成样本实证） |
| P1-3 运行时新鲜度 / Runtime Freshness | 新增 `direct/source-stamp.sh`：对 `quaderno_direct.py`、`requirements-build.txt`、`build-helper.sh` 计算复合 SHA-256 戳记（缺文件即失败，不产生恒定哈希，避免中文路径下 `%x` 展开损坏）；`build-helper.sh` 写戳记；`build-app.sh` 比对，不一致自行重建，重建后仍不符则拒绝打包。`build-helper.sh` 补执行位。 | 首次构建输出「运行时与源码不一致，重建直连工具」→ `✅ 直连工具与源码一致（ffa19fd4242e）`；第二次构建跳过重建。完整构建 `EXIT=0`。 | 已修 |
| P1-4 传输超时 / Transfer Timeout | `transfer_timeout(size) = 120 + ceil(size / 256 KiB)`；`--speed-limit 1 --speed-time 90` 做停滞检测 / Stall Detection；`subprocess.run` 的 `timeout = max_time + 10`。仅上传与回读带 `transfer_size`。 | 单测断言 0 B→120 s、100 MiB→520 s，并核对 curl 实参 `('120','90',130)` 与 `('520','90',530)`。真机 24 MiB 端到端投递成功、回读 SHA-256 一致（见 6.3）。 | 已修（停滞判定未做真机拔线注入） |

### 6.2 构建、签名与安装

- 完整构建 `./gui/build-app.sh`：`EXIT=0`，**零 warning / 零 error**，签名校验 `✅ 签名校验通过`，`codesign --verify --deep --strict` 通过。
- 顺带清零一处既有编译警告：`ConversionViewModel.swift:590` 的 `#ImplicitStrongCapture`（外层 `DispatchQueue.main.async` 显式 `[self]` 捕获，捕获语义不变）。该警告在 HEAD `e6a7d75` 中已存在，非本轮 P1 引入。
- 安装到 `~/Applications/TrueScale for QUADERNO.app`，旧版备份于 `/tmp/TrueScale-app-backup-20261104-211858.app`。首次 `open` 返回 LaunchServices `-600`，重试一次成功启动；`check` 返回「设备已直连，认证及目录读取通过」。

### 6.3 真机吞吐实测（收敛 §4 第 1 条盲区）

样本：24 MiB（25,165,776 B）单页合法 PDF，走完整 `upload → download → delete` 端到端 / End-to-End 路径，SHA-256 双向比对通过。

| 指标 | 实测 | 与假设的关系 |
|---|---|---|
| 下载（单次 GET，含连接开销） | 1.47 s / 16.27 MiB/s | `MIN_TRANSFER_BYTES_PER_SECOND = 256 KiB/s` 保守约 **65 倍** |
| 上传端到端（含认证 + PUT + 打开请求 + 完整回读 + 目录确认） | 4.70 s | 其中含两次 24 MiB 传输；按单次折算 5.11 MiB/s，按双次折算 10.21 MiB/s（均为上界估计，纯 PUT 吞吐未单独测得） |
| `transfer_timeout(24 MiB)` | 216 s | 实际耗时占上限约 **2.2%**，余量约 46 倍 |

结论：§3 中 P1-4 的「阈值待验」已收敛；在该设备的 USB ECM 链路上，256 KiB/s 下限与 120 s 基线都有充分余量，尺寸缩放上限不会发生误杀。限制：单设备、单文件大小、单链路（USB），未测 Wi-Fi、>100 MiB 文件、设备休眠态；`--speed-time 90` 的停滞判定只做了代码与单测验证，未做真机拔线注入。

### 6.4 新增观察：设备目录列表存在索引延迟

上传成功后连续 3 次 `browse --path Document/Received`（约 3–4 s 内）均未返回新条目（729 条），但同一时刻 `resolve(remote)`、`/documents/{id}/file` 回读与 `download --id` 全部可用；约数十秒后列表变为 730 条并出现该条目；`delete --id` 后回到 729 条。

- 判定：QUADERNO 固件的 `entries2` 目录索引存在异步延迟，非本仓库代码缺陷。
- 影响：App「设备文件」页在上传成功后短期内可能不显示新条目，而投递已成功。
- 状态：**新观察·待验**（原因未定位）。是否需要 UI 乐观插入 / 延迟刷新，未改代码。

### 6.5 仍未收敛

- 8 个 P2（错误分类、非 UTF-8 输入、stderr 混入 JSON、串口切换重试、主线程 `tcdrain`、30 s 锁、兜底重复、发布闸门）全部保持开放。
- Hardened Runtime + Developer ID 公证版下 `ctypes`/IOKit 重新枚举未验。
- `runShell` 未跑真实 `book.sh` 大输出样本（仅合成样本）。
- 11-02 的 `0xb7` 解码错误来源、与官方 App 的认证交错、设备 A 类掉线（固件/硬件）均未定位。
- §4 中「runShell 需要 64 KB 真实样本」已由合成样本替代，**不是**真实业务负载验证。

### 6.6 交付状态与残留清理

- 单元测试：`.build/direct/venv/bin/python -m unittest tests/test_direct_delivery.py -v` → `Ran 60 tests in 0.716s / OK`。
- 真机测试条目 `TRUESCALE-THROUGHPUT-PROBE-20261104.pdf` 已 `delete`，目录复核 `probe_matches []`；`orphans.json` 未产生。
- 该次测试写入 `history.jsonl` 的一条投递记录已移除（41/42 条保留，权限 `0600` 不变，备份 `/tmp/truescale-history-backup-20261104-212126.jsonl`）。
- 本地临时样本保留在 `/tmp/TRUESCALE-THROUGHPUT-PROBE-20261104.pdf` 与 `/tmp/TRUESCALE-PROBE-READBACK.pdf`。
- 未 push、未自合；`icon/` 与 `output/` 两个历史遗留未跟踪目录未纳入本轮提交。

---

## 7. 优先级动作落地：P0 三项（2026-11-04 21:50 后）

对应上一轮评估清单的 P0-1 / P0-2 / P0-3；P1、P2、P3 各动作仍保持开放。

### 7.1 P0-1 回归断言与质量闸门 / Quality Gate

- `test.sh` 的「底部操作区」断言原先找 `Text("发送到 Quaderno")`（旧 HTML 版 GUI 的字面量），原生重写后按钮已改为 `Text("投递到 QUADERNO")`，导致 73/74 的假失败。断言改为检查**结构性不变量**：`sidebarFooter` 调用点的 `.fixedSize(horizontal: false, vertical: true)` + `actionButtons` 中仍存在 `deliverToDevice()` / `savePDF()`，不再锁定文案。
- 闸门接入：`docs/CHECKLIST.md` §5 增列 `./test.sh`；`gui/release-github.sh` 在版本校验后增加预检（unittest → test.sh → `git diff --quiet` / `--cached --quiet`）；新增 `.github/workflows/python-tests.yml` 只跑可移植的 Python 不变量。
- **取舍**：`test.sh` 的断言依赖 SwiftUI 源码文本与 macOS 上的 pandoc / typst / pdfinfo，不进 Ubuntu CI；它在本地提交前与发布前跑。CI 只承载与平台无关的 63 项单测。这区分了「行为不变量」与「实现快照」。
- 结果：`./test.sh` → `全部通过 · 74 项断言`；`zsh -n` 对 `test.sh` 与 `release-github.sh` 通过；workflow YAML 解析通过。

### 7.2 P0-2 上传链路去整文件内存驻留 / Bounded Memory

- 新增 `file_sha256(path)`（1 MiB 分块）；`upload()` 改用 `source.stat().st_size` 与流式哈希，删除函数级的 `content` 变量。
- `Device.request(..., verify_sha256=...)`：curl 把回读写到临时文件后，直接对该文件分块哈希比对，返回 `Response(content=b'')`，响应体不进入 Python 堆。404 / 非 2xx 判断前移到哈希之前，避免把错误页当作内容校验。
- 新增 3 个单测：`file_sha256` 跨多分块一致；`upload()` 全程不调用 `Path.read_bytes()` 读取源 PDF（spy 断言），且 `transfer_size` / `verify_sha256` 正确下传；`request()` 校验通过时 `content == b''`、校验失败抛「回读校验不一致」。同步修正 3 处测试桩以模拟新的校验位置。
- 结果：63 项单测 OK；真机 24 MiB 端到端 `upload` 4.47 s、SHA-256 一致，条目已删除、history 记录已清理。
- **边界**：`download()` 仍用 `Response.content` 整份载入，不在本次动作范围；磁盘 I/O 由 1 次全量读变为 3 次顺序读（源哈希、curl PUT、curl 回读），以内存有界为交换。

### 7.3 P0-3 子进程超时与终止 / Hard Deadline

- 新增 `gui/mac/ProcessRunner.swift` 作为**单一收敛点**：并发排空 stdout / stderr（保留 64 KB 缓冲死锁的防线）、`DispatchGroup` 等待带硬超时、超时后 SIGTERM → 3 s 宽限 → SIGKILL → 2 s 收尾；区分 `.none` / `.separate` / `.merged` 三种捕获模式，启动失败返回 `launchError` 而不是崩溃。已加入 `build-app.sh` 的 swiftc 文件列表。
- 6 个等待点全部接入，超时分级：

| 调用点 | 模式 | 上限 | 依据 |
|---|---|---|---|
| `runShell` 常规（typst fonts、pandoc 导出） | `.separate` | 600 s | 输出量可控 |
| `runShell` 的 book.sh 整本排版（2 处） | `.separate` | 1800 s | 长书耗时最高 |
| `zipDirectory` | `.none` | 120 s | 本地 zip，无网络 |
| `QuickSendView` `--check` | `.merged` | 180 s | `prepare_usb()` ≤12 s + curl 120 s + 余量 |
| `DirectDelivery.run` | `.merged` | 3600 s | 覆盖 upload / download / screenshot |
| `GlobalHotkeys` / `QuadernoApp` 的 deliver.sh | `.none` | 3600 s | 整本书投递 |

- 独立 Swift 探针实证（`/tmp/pr_probe_src/main.swift`，编译 `ProcessRunner.swift`）：双路各 200 KB 输出 → `(200000, 200000)`、`rc=0`；`sleep 30` 子进程在 **2.06 s** 返回 `timedOut=true`、`rc=15`、`stillRunning=false`；不存在的可执行文件 → `launchError` 被捕获、`rc=-1`。
- **转换进度反馈核实**：`isConverting` + `ProgressView` 已在 `ContentView.swift:662/738` 实现，`TODO.md` 的「界面静默」条目已过时，本轮更新为已完成；未重复实现 UI。
- **层界说明**：Swift 侧 3600 s 与 Python 侧 `transfer_timeout(1.2 GiB)=4920 s` 不是配置冲突。前者是用户可感知的外层硬上限，刻意先于后者触发，为「尺寸缩放上限无 cap」提供兜底；后者仍是单次 HTTP 请求上限。P1-2（给 `transfer_timeout` 设 cap）依然开放。
- **未改行为**：`DirectDelivery` / `QuickSendView` 仍用 `.merged` 单管道，CFR §3 的 P2-3（stderr 混入 JSON）保持开放。

### 7.4 验证矩阵

| 层 | 结果 |
|---|---|
| Python 单测 | `Ran 63 tests / OK` |
| 回归套件 | `全部通过 · 74 项断言` |
| 构建 | `EXIT=0`，零 warning / 零 error；戳记闸门因 `quaderno_direct.py` 改动自动重建运行时（`2283645bcf55`） |
| 签名 / 安装 | `codesign --verify --deep --strict` 通过；安装后 `check` 通过 |
| 进程封装 | Swift 探针 3 组场景全部符合预期 |
| 真机 | 24 MiB upload 4.47 s / download 1.23 s，SHA-256 双向一致，测试条目与 history 记录已清理 |
| CI | 新 workflow 未在 GitHub runner 上执行（需远端），仅做本地 YAML 解析与依赖核对 |

### 7.5 本轮未收敛

- 评估清单的 P1（4 项）、P2（5 项）、P3（2 项）全部保持开放，包括 8 个原始 P2 缺陷。
- `download()` 的整份响应载入、P2-3 的 stderr 分离、孤儿清理的 `BaseException` 与请求预算、`--speed-limit 1` 语义、文档 SSOT（`docs/PRODUCT.md:39` 仍写 1.1.0）、`icon/` / `output/` 未跟踪处置。
- 真机失效注入（拔线）、Hardened Runtime 公证版、>100 MiB 文件、Wi-Fi 链路、设备休眠态仍未测。

---

## 8. 缺口清单续做：清理语义、流式下载、超时上界与 stderr 隔离（2026-11-05 07:30 后）

- **范围**：承接第 3 节缺口清单的 S1 项，设备处于已连接状态（FUJITSU QUADERNO A5，USB ECM，`en5` IPv6 link-local）。**不含**并发架构改造（P2-5 主线程 `tcdrain`、P2-6 30 s 锁）——排队语义需用户确认，故保持开放。
- **关键假设**：① `MAX_TRANSFER_SECONDS = 3000` 刻意低于 Swift 侧 3600 s 外层硬上限，使请求级错误先于进程被杀抵达用户；② `--speed-limit 1` 阈值未改，因「链路慢」与「设备渲染阻塞」的判定边界未定义；③ 不触碰设备既有 735 条用户数据，真机验证只用自有探针文件并即时删除。

### 8.1 落地项

| 项 | 改动 | 对应缺口 |
|---|---|---|
| 清理路径异常语义 | `upload()` 的 `except BaseException` → `except Exception`；`discard_incomplete()` 的 DELETE 用 `time_limit=15 s`；`remove_orphans()` 用 60 s 总预算 + 每次 15 s 上限，失败不再静默 `continue`，而是把 `last_error` 写回 `orphans.json`；`load_orphans()` 指定 UTF-8 编码 | P0-1 / P1-1 |
| 流式下载 | `request(..., output_path=...)` 让 curl 直接写目标临时文件；`download()` 用该通道 + `os.replace` + `finally` 清理，响应体不再进入 `Response.content`；未知大小时用 3000 s 上限而非 120 s 元数据基线 | P0-3 |
| 超时上界 | `transfer_timeout()` 加 `min(MAX_TRANSFER_SECONDS, ...)`，1.2 GiB 从 4920 s 收敛到 3000 s | P1-2 的 cap 部分 |
| stderr 隔离 | `DirectDelivery` / `QuickSendView` 由 `.merged` 改 `.separate`；`DirectDelivery` 只解析 stdout（整体 JSON 优先，失败时退化为最后一行 JSON），stderr 仅进 `details` | P0-2 / P2-3 |
| 构建诊断与戳记断言 | `build-app.sh` 重建不再丢弃 PyInstaller 输出，失败时打印尾部 30 行并给出完整日志路径；新增 `SourceStampTests` 断言戳记随源码变化、缺文件必失败（`skipUnless(zsh)` 保证 Ubuntu CI 可跳过） | P1-4 |

### 8.2 验证矩阵

| 层 | 结果 |
|---|---|
| Python 单测 | `Ran 69 tests / OK`（新增 6 项：cap、清理短超时与预算、失败记录、KeyboardInterrupt 不清理、流式下载、戳记闸门；同步修正 `FileManagementTests` 的 download 桩） |
| 回归套件 | `全部通过 · 74 项断言` |
| 构建 / 签名 | 两次 `./gui/build-app.sh` `EXIT=0`，零 warning / 零 error；首次因源码变更自动重建运行时 `9074490394b1`，二次跳过；`codesign --verify --deep --strict` 通过 |
| stderr 误报 A/B | 同一输入（stderr 警告 + stdout JSON）：基线 `.merged` 逻辑 → `LEGACY_SUCCESS=false`；当前逻辑 → `SUCCESS=true`。三种 stdout 形态（单 JSON / 进度行+JSON / 含 U+2028 的 JSON 字符串）全部 `SUCCESS=true` |
| 真机端到端 | 24 MiB：upload 4.97 s、download 1.20 s / 19.96 MiB/s；**128 MiB（134,217,695 B）**：upload 16.04 s、download 5.53 s / 23.15 MiB/s。两者 SHA-256 双向一致、`transfer_timeout(128 MiB)=632 s`、条目已 delete |
| 状态核对 | 设备 Received 735 条前后不变、无探针残留；`orphans.json` 未产生；`history.jsonl` 47 条无探针记录（备份 `/tmp/truescale-history-backup-r2-20261105-073749.jsonl`）；`check` 通过 |

### 8.3 新增观察（诊断层陷阱，非产品缺陷）

设备 Received 中存在文件名内嵌 **U+2028 LINE SEPARATOR** 的文档。`browse` 输出是**单个合法 JSON**，但 Python `str.splitlines()` 会把 U+2028 当行分隔符切成 3 段，导致「反向逐行找最后一个 JSON」的诊断脚本返回 0 条。已改用整体 `json.loads` 复核为 735 条。Swift 侧 `split(separator: "\n")` 不切 U+2028，但本轮仍把 `DirectDelivery` 调整为**整体解析优先**，属防御性加固，不是已复现回归的修复。

### 8.4 本轮未收敛

- P0-4：P2-5 主线程 `tcdrain`、P2-6 30 s 并发锁（架构改动，待确认排队语义）。
- P1-2 剩余：`--speed-limit 1` 只判完全无数据；两层超时（Python 3000 s / Swift 3600 s）的错误消息归因未做真机注入。
- 上一轮离线探测的三处输入缺口仍在：0 字节 PDF 判成功、180 字符文件名原样上传、同名重复改 `_8hex.pdf`；依赖缺失仍被 `main()` 归为「无法连接设备」。
- `orphans.json` 按 pin 隔离 + `ORPHAN_LIMIT=20` 静默截断 + 无时间戳；设备目录索引延迟 3–4 s 未做 UI 补偿。
- 真机拔线/断电失效注入、Hardened Runtime 公证版、Wi-Fi 链路、>128 MiB 文件、设备休眠态、真实 `book.sh` 大输出、CI 远端执行、文档 SSOT（`PRODUCT.md:39` 仍 1.1.0）仍未验证。
- `icon/`、`output/` 两个历史遗留未跟踪目录未纳入提交。本地提交，未 push、未自合。

> 状态索引：以下 §8.4 条目已于 §9 收敛 —— P2-5 / P2-6 并发架构、异常输入三缺口、依赖错误分类、设备目录索引延迟 UI 补偿、文档 SSOT（`PRODUCT.md:39`）。其余条目（`--speed-limit` 阈值、`orphans.json` 生命周期、失效注入、CI 远端执行、`icon/` / `output/`）仍开放。

## 9. 排队等待与输入边界（2026-11-05，用户确认「可以改为排队等待」后执行）

### 9.1 落地项

| 项 | 改动 | 对应缺口 |
|---|---|---|
| App 侧 FIFO 队列 | 新增 `DeliveryQueue` actor（`CheckedContinuation` 非阻塞等待 + 槽位直接移交），`DirectDelivery.run` 先 `acquire()` 再启动 helper，用 `defer { Task { await release() } }` 保证取消 / 早退也放行。排队不计入 3600 s 进程硬超时 | P0-4 / P2-6 |
| 跨进程锁排队 | `connection_lock()` 默认 `timeout` 由 30 s 改为 `LOCK_WAIT_SECONDS = MAX_TRANSFER_SECONDS = 3000`；排队时向 **stderr** 输出一次中文/英/日提示（stdout 仍是严格 JSON 通道）；超时文案沿用既有条目 | P0-4 / P2-6 |
| 串口切换线程模型 | `QuickSendMonitor.refresh()` 的 IOKit 扫描与切换整体移到 `DispatchQueue.global(.utility)`，主线程只接收结果；`tcdrain` 改为 `dup` fd + 后台线程 + `DispatchSemaphore` 2 s 有界 join，静态 `DrainState` 防止卡死时重复起线程 | P0-4 / P2-5 |
| 切换失败重试 | 失败不写入 `switchedPort`，按 3/6/12/24/30 s 指数退避重试；设备拔出时清空状态 | P1 / P2-4 |
| 空输入 | `upload()` 在 `stat()` 后拒绝 0 字节 PDF，先于任何设备请求 | P1-1 |
| 名称边界 | 新增 `remote_file_name()`：折叠 C0 控制字符与设备特殊字符、保留 U+2028 等 Unicode、统一截断到 `MAX_REMOTE_NAME = 100`（含 `.pdf`）；原先只有同名冲突分支才截断 | P1-1 |
| 重复请求幂等 | 同名冲突时用 `GET /documents/{id}/file` 流式落盘比对 SHA-256：内容一致直接返回 `skipped=True`，不写设备；不一致用确定性 `stem_<sha8>.pdf`，仅当该名也被占用才追加 uuid。比对失败一律走新建，不误报成功 | P1-1 |
| 错误分类 | `main()` 把 `TimeoutExpired` / `FileNotFoundError` 从 `OSError` 大类中分离，分别给出超时与「本机缺少工具或文件」提示（含路径），连接类 `OSError` 保持原文案 | P1-2 |
| 目录索引补偿 | `DeviceFilesModel` 新增 `visible()` / `expectedNames()` / `refreshUntilVisible()`：改动后 0/3/6 s 有界追赶刷新，按名称前 40 字符前缀匹配（兼容截断与内容后缀）；`ConversionViewModel` 投递成功后调用 `noteDelivered()` | P1-4 |
| 文档 SSOT | `PRODUCT.md:39` 直连版基线 1.1.0 → 1.2.2（与 `Info.plist` / `CHANGELOG` 一致）；`CHANGELOG` 增加 Unreleased 段；`TODO.md` 勾选四项已收敛工作 | P2-3 |

### 9.2 验证矩阵

| 层 | 结果 |
|---|---|
| Python 单测 | **77 项 / OK**（新增 8 项：空文件、名称边界、长名上传、幂等跳过、确定性后缀、依赖分类、锁上限、双线程排队；同步修正 `TransportTests` 的冲突桩以隔离新逻辑） |
| 回归套件 | **74/74 通过**；`zsh -n` 三个脚本通过 |
| 构建 / 签名 | **两次** `./gui/build-app.sh` 均 `EXIT=0`，零 warning / 零 error；首次因源码变更自动重建运行时 `8a5f571cbf43`，二次戳记复用并跳过；两次 `codesign --verify --deep --strict` 通过；`check` 通过（`en5` IPv6 link-local，root_entries 12） |
| App 队列探针 | 三个并发 `DirectDelivery.run` 调用：helper 日志严格 `start A/end A/start B/end B/start C/end C`，`ALL_OK=true`；最终 defer 版 `ELAPSED=1.34s`（单个 0.4 s × 3，串行） |
| 排队提示解析 | helper 同时输出两行 stderr（含中文排队提示）与一行 stdout JSON：当前 `DirectDelivery` `SUCCESS=true`、`MESSAGE` 正确、stderr 仅进 `details` |
| 真机输入边界 | 0 字节 PDF → `ok=false`「PDF 文件为空，未上传。」（0.35 s，无设备写入）；202 字符文件名 → 设备侧 100 字符、SHA-256 一致（3.05 s）；同一 2 MiB 文件第二次上传 → `skipped=true`「设备上已有内容相同的文件，未重复投递。」（0.63 s vs 首次 2.29 s） |
| 真机并发排队 | 两个 CLI 进程同一瞬间各投递 4 MiB：**两者 `ok=true`**，一个 stderr 出现「正在等待另一项设备投递完成…」，wall 5.28 s（串行），无 30 s 直接失败 |
| 状态核对 | 设备 Received **735 条前后不变**、无探针残留；`orphans.json` 未产生；`history.jsonl` 50 → 45（备份 `/tmp/truescale-history-backup-r3-20261105-080613.jsonl`） |

### 9.3 关键假设

1. 排队发生在 **App 层**，进程级 3600 s 硬超时只约束单次事务；因此 `LOCK_WAIT_SECONDS` 可对齐 3000 s 而不与外层上限冲突。跨进程（官方 App / 手工 CLI）撞锁时最坏仍可能先触发外层上限，归因顺序未改，列为待确认。
2. 幂等语义取「**内容相同则跳过**」，不做覆盖、不写 history；不同内容同名文件保留为确定性副本。若产品语义应为「覆盖」或「总是生成版本副本」，需另定。
3. 名称上限取 100 **字符**（非字节），保留 U+2028 等已有设备文件名字符；未做固件 NAME_MAX 字节级实测。
4. `tcdrain` 卡死时后台线程可能长期占用，静态槽位会拒绝后续 drain 直至其结束；此为真机串口卡死注入才能收敛的边界。
5. 未执行破坏性失效注入（拔线 / 断电 / 限速），未改 `--speed-limit`、两层 cap 数值、`icon/` / `output/` 处置。

### 9.4 本轮未收敛

- **S1 未验**：真机串口卡死 / 拔线 / 断电 / 限速失效注入；Hardened Runtime 公证版；Wi-Fi 链路、>128 MiB、设备休眠态、真实 `book.sh` 大输出、CI workflow 远端执行。
- **S2 仍在**：`--speed-limit 1` 只判完全无数据；`orphans.json` 按 pin 隔离 + 20 条静默截断 + 无时间戳；非 UTF-8 输入、兜底重复投递；设备页延迟刷新的 UI 呈现与快捷键 / Finder 投递链路（`deliver.sh`）未接 `noteDelivered()`。
- **S3**：`test.sh` 74 项断言中「行为不变量 vs 实现快照」未分类；`icon/`、`output/` 未处置。
- 构建前需先把旧 `gui/*.app` 移出仓库目录，否则本会话的批量删除护栏会拦截 `build-app.sh` 的 `rm -rf`（旧产物已备份至 `/tmp/truescale-prebuild-app-20261105-080409.app`）。
