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
