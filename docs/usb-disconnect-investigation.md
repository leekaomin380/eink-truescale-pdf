# FMVDP51 USB 连接自行断开：现象与日志证据

调查日期：2026-10-31。主机：Apple Silicon Mac，macOS（Darwin 27.2）。设备：FUJITSU QUADERNO A5（FMVDP51），USB 有线连接。

## 现象

设备一直插在 Mac 上，但一段时间后官方 QUADERNO PC App 显示「未连接」，第三方直连工具也连不上。
只有物理拔插 USB 线才能恢复。

## 主机侧证据（macOS 内核日志）

USB 枚举分两步：先以 PID `0x1656` 出现，约 2 秒后断开，再以 `0x1657`（CDC 复合设备，带 USB 网卡）重新出现。
这和 Android 设备切换 USB gadget 模式的过程一致，属于正常行为。

异常发生在已稳定连接之后：

| 连接建立（0x1657） | 断开 | 持续 | 断开前最后一次主机流量 | 断开时 Mac 状态 |
|---|---|---|---|---|
| 09:39:13 | 11:26:57 | 1 h 48 min | 10:59:18（约 28 min 前） | 唤醒，使用电池 |
| 13:34:29 | 14:35:32 | 1 h 01 min | 14:34:27，官方 App 每 5 min 轮询一次，最后一次成功轮询在断开前 65 s | 唤醒，使用电池 |

断开时内核日志如下：

```
AppleUSBHostPort::terminateDevice: destroying 0x04c5/1657/0100 (FMVDP51): hardware connection lost
AppleUSBIORequest::complete: device 1 (FMVDP51) endpoint 0x82: status 0xe00002ed (transaction error)
en5 detaching
```

断开之后，日志里没有出现任何重新枚举，直到 15:21:34 人工拔插。

## 能排除的

- **Mac 睡眠**：两次断开时 Mac 都处于唤醒状态（见 `pmset -g log`）。Mac 的下一次睡眠分别在断开后 2.7 min 和 21 min。
- **网络层或软件层**：`hardware connection lost` 的意思是端口检测到设备从总线上消失，而不是 TCP 或 mDNS 出错。断开前 65 s 设备还正常响应官方 App 的 HTTPS 轮询。
- **主机无法重新连接**：断开后设备不再出现在 USB 总线上，主机侧没有可以重试的对象。

## 尚未确认的（需要实验）

1. 断开是否由设备进入休眠或自动关机触发。两次断开都发生在最后一次有效使用约 30 min 后，但手头只有两个样本，不能确定。
2. 设备唤醒后为什么不重新枚举 USB。这是最可能需要富士通在固件侧确认的地方。
3. 线缆或接口接触。需要换线、换口复测。
4. Mac 使用电池时的端口电源策略。两次断开都发生在电池供电时，需要接电源对照复测。

## 复现与采集

```bash
/usr/bin/log show --last 8h --style compact \
  --predicate 'process == "kernel" AND eventMessage CONTAINS "FMVDP51"'
```

## 补充（2026-11-01）：插着线却一直没有网卡

另一种「连不上」与上文不同：设备一直在 USB 总线上，但停留在串口模式（0x1656），没有网卡。
原因是设备需要主机写入切换序列才进入网卡模式，平时由 QUADERNO PC App 代做；官方 App 未运行时就会停在串口模式。
TrueScale 现已自行切换（见 DIRECT-DELIVERY.md）。上文「休眠后自行掉出 USB 总线」是另一个现象，仍待确认。

## 补充（2026-11-04）：Mac 睡眠唤醒后网卡链路不恢复（已自动修复）

第三种「连不上」：设备仍在 USB 总线上，处于网卡模式（0x1657），`en5` 也存在，但链路是 `inactive`，
没有 IPv6 地址，mDNS 也没有 `_dp_fujitsu` 服务。

| 时间 | 事件 |
|---|---|
| 20:29:56 | 插拔后 `en5 link ACTIVE`，20:30:07 投递成功 |
| 20:36:36 | Mac 闲置睡眠（使用电池） |
| 20:36:37 | `en5` link_off，USB 设备没有断开 |
| 20:37:54 | Mac 唤醒；之后 `en5` 一直 inactive，20:40、20:41 两次投递失败 |
| 20:48 | QUADERNO 屏幕已唤醒，链路仍 inactive，期间无任何链路事件 |
| 20:49:55 | 用户态调用 `USBDeviceReEnumerate`（无需 root），约 2 s 后链路 active，`check` 通过 |

结论：链路断开由 Mac 睡眠触发，设备唤醒后不会自己重新上报链路，但软件触发的重新枚举（等价于插拔）可以恢复。
11-04 上午 09:51:43 也有一次同样的 `en5` link_off 紧跟 Mac 唤醒。

实现：`prepare_usb()` 在连接前先做串口→网卡切换，再检查 `ioreg` 中 0x1657 设备的 `IOLinkStatus`
（valid 且非 active 即判定为卡住），卡住时经 ctypes 调用 IOKit 重新枚举并等待服务广播（最多 12 s）。
仍未恢复时报 `UsbLinkDown`，提示插拔，不再去连 Wi-Fi 上同名的 `Android.local`。

另外记录到一次模式切换没有生效：18:05:21 设备以 0x1656 枚举，18:05:30、18:05:46 两次写入切换序列后都没有切换，
直到 18:06:40 才进入 0x1657。只有一个样本，原因未明，暂不处理。
