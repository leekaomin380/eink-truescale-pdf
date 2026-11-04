#!/usr/bin/env python3
"""Local, pinned-TLS Quaderno transport. No official application at runtime.
Protocol reference: https://github.com/janten/dpt-rp1-py (MIT).
Delivery only reads folders and adds documents; it never deletes or overwrites anything.
Deleting, moving and creating folders happen only as explicit actions from the App's file manager.
"""
import argparse
import fcntl
import functools
import glob
import termios
from contextlib import contextmanager
import base64
import hashlib
import json
import os
import shutil
from pathlib import Path
import re
import ipaddress
import selectors
import time
from concurrent.futures import ThreadPoolExecutor
import sys
import tempfile
import unicodedata
from urllib.parse import quote, urlparse
import uuid
from datetime import datetime

import subprocess
from Crypto.PublicKey import RSA
from Crypto.Hash import SHA256
from Crypto.Signature import pkcs1_15
import yaml

ROOT = Path.home() / 'Library/Application Support/Quaderno Converter/Direct'
APP_BUNDLE_ID = 'io.github.leekaomin380.quaderno-converter'
OFFICIAL_APP = Path('/Applications/QUADERNO PC App.app')

# User-facing messages: zh-Hans source text -> (English, 日本語). Same languages as the App.
MESSAGES = {
    '设备请求失败（HTTP {status}）。请检查配对和连接。': (
        'Device request failed (HTTP {status}). Check the pairing and connection.',
        '端末へのリクエストに失敗しました（HTTP {status}）。ペアリングと接続を確認してください。'),
    '设备证书与已配对设备不一致，已拒绝连接。': (
        "The device certificate does not match the paired device. Connection refused.",
        '端末の証明書がペアリング済みの端末と一致しないため、接続を拒否しました。'),
    '设备地址无法连接，请检查 USB / Wi-Fi 和设备唤醒状态。': (
        'Cannot reach the device address. Check USB / Wi-Fi and make sure the device is awake.',
        '端末のアドレスに接続できません。USB / Wi-Fi と、端末がスリープ中でないかを確認してください。'),
    'USB 上未检测到 QUADERNO，设备已断开。请重新插拔 USB 线后重试。': (
        'No QUADERNO found on USB — the device has disconnected. Unplug and reconnect the USB cable, then try again.',
        'USB 上に QUADERNO が見つかりません（接続が切れています）。USB ケーブルを挿し直してから再試行してください。'),
    'QUADERNO 仍在 USB 上，但 USB 网络链路已断开，自动恢复未成功（常见于 Mac 睡眠唤醒后）。请重新插拔 USB 线后重试。': (
        'The QUADERNO is still on USB, but its USB network link is down and automatic recovery failed '
        '(common after the Mac wakes from sleep). Unplug and reconnect the USB cable, then try again.',
        'QUADERNO は USB に接続されていますが、USB ネットワークのリンクが切れており、自動復旧に失敗しました'
        '（Mac のスリープ解除後によく起こります）。USB ケーブルを挿し直してから再試行してください。'),
    '未找到可连接的已配对设备。': (
        'No reachable paired device was found.',
        '接続できるペアリング済み端末が見つかりません。'),
    '设备未返回有效的登录凭据。': (
        'The device did not return valid login credentials.',
        '端末から有効なログイン資格情報が返されませんでした。'),
    '设备返回的登录凭据格式异常。': (
        'The device returned malformed login credentials.',
        '端末から返されたログイン資格情報の形式が不正です。'),
    '无法读取设备 Document 目录。': (
        "Cannot read the device's Document folder.",
        '端末の Document フォルダーを読み取れません。'),
    '设备已直连，认证及目录读取通过': (
        'Device connected directly; authentication and folder reading passed',
        '端末に直接接続しました。認証とフォルダーの読み取りに成功しました'),
    '设备 Received 文件夹不存在，未上传文件。': (
        'The Received folder does not exist on the device. Nothing was uploaded.',
        '端末に Received フォルダーがないため、アップロードしませんでした。'),
    '文件已上传，但回读校验不一致。请保留本地 PDF 并检查设备。': (
        'The file was uploaded, but the read-back check did not match. Keep the local PDF and check the device.',
        'アップロードしましたが、読み戻しの照合が一致しません。ローカルの PDF を残して端末を確認してください。'),
    '回读已通过，但设备目录未确认新文件。': (
        "Read-back passed, but the new file was not confirmed in the device's folder.",
        '読み戻しは成功しましたが、端末のフォルダーで新しいファイルを確認できませんでした。'),
    '已保存至 {folder}：{name}（回读通过，已请求设备打开）': (
        'Saved to {folder}: {name} (verified; asked the device to open it)',
        '{folder} に保存しました：{name}（照合済み、端末に表示を要求しました）'),
    '已保存至 {folder}：{name}（回读通过，设备未接受打开请求，请从 {folder} 打开）': (
        'Saved to {folder}: {name} (verified; the device did not accept the open request — open it from {folder})',
        '{folder} に保存しました：{name}（照合済み。端末が表示要求を受け付けなかったため、{folder} から開いてください）'),
    '尚未配置直连。请在 App 的「设置 → 设备」中迁移现有配对。': (
        'Direct connection is not set up yet. Import the existing pairing in the app under Settings → Device.',
        '直接接続がまだ設定されていません。App の「設定 → 端末」で既存のペアリングを移行してください。'),
    '未找到唯一的已有配对。请先确认当前 Mac 的设备配对信息。': (
        "Could not find a single existing pairing. Check this Mac's device pairing first.",
        '既存のペアリングを一意に特定できません。この Mac の端末ペアリング情報を確認してください。'),
    '请输入主机名或 IP 地址，不含协议和端口。': (
        'Enter a host name or IP address without a scheme or port.',
        'ホスト名または IP アドレスを、プロトコルやポートを付けずに入力してください。'),
    '无法确认设备证书。请连接已配对的设备并检查地址。': (
        'Cannot verify the device certificate. Connect the paired device and check the address.',
        '端末の証明書を確認できません。ペアリング済みの端末を接続し、アドレスを確認してください。'),
    '无法读取设备证书。': (
        'Cannot read the device certificate.',
        '端末の証明書を読み取れません。'),
    '已有不同的设备配置；为避免覆盖，请先保留原配对再更换设备。': (
        'A different device is already configured. To avoid overwriting it, keep the original pairing before switching devices.',
        '別の端末がすでに設定されています。上書きを避けるため、元のペアリングを保持してから端末を切り替えてください。'),
    '剪贴板摘录': ('Clipboard excerpt', 'クリップボードの抜粋'),
    '另一项设备投递正在进行，请稍后重试。': (
        'Another delivery to the device is in progress. Try again shortly.',
        '別の送信が進行中です。しばらくしてから再試行してください。'),
    '快捷键投递排版配置无效，请在 App 中检查排版设置。': (
        'The hotkey-send layout settings are invalid. Check the layout in the app.',
        'ショートカット送信のレイアウト設定が無効です。App でレイアウトを確認してください。'),
    '渲染失败：{detail}': ('Rendering failed: {detail}', 'レンダリングに失敗しました：{detail}'),
    '{error}；PDF 已保留：{path}': ('{error} The PDF was kept: {path}', '{error} PDF は保存してあります：{path}'),
    '请选择已有的 PDF 文件。': ('Choose an existing PDF file.', '既存の PDF ファイルを選んでください。'),
    '无法连接设备，请检查 USB / Wi-Fi、设备唤醒状态及设备地址。': (
        'Cannot connect to the device. Check USB / Wi-Fi, whether the device is awake, and the device address.',
        '端末に接続できません。USB / Wi-Fi、端末のスリープ状態、端末のアドレスを確認してください。'),
    '设备协议或配对信息异常，请重新检查连接配置。': (
        'Unexpected device protocol or pairing data. Check the connection settings again.',
        '端末のプロトコルまたはペアリング情報に異常があります。接続設定を確認し直してください。'),
    '直连不可用，已经 QUADERNO PC App 投递：{name}（由官方 App 送达，未做回读校验）': (
        'Direct connection unavailable; sent through QUADERNO PC App: {name} (delivered by the official app, not read back)',
        '直接接続が使えないため QUADERNO PC App 経由で送信しました：{name}（公式 App による送信、読み戻し照合なし）'),
    '直连不可用，经 QUADERNO PC App 投递也失败（设备离线或投递被取消）。': (
        'Direct connection unavailable, and delivery through QUADERNO PC App also failed (device offline or delivery cancelled).',
        '直接接続が使えず、QUADERNO PC App 経由の送信も失敗しました（端末がオフラインか、送信が取り消されました）。'),
    '已交给 QUADERNO PC App，但 60 秒内未确认送达。请在设备上检查。': (
        'Handed to QUADERNO PC App, but delivery was not confirmed within 60 seconds. Check the device.',
        'QUADERNO PC App に渡しましたが、60 秒以内に送信を確認できませんでした。端末で確認してください。'),
    '{error}（打开 QUADERNO PC App 后重试，可经官方 App 投递）': (
        '{error} (Open QUADERNO PC App and try again to send through the official app.)',
        '{error}（QUADERNO PC App を開いて再試行すると、公式 App 経由で送信できます）'),
    # File management (App 设备文件 tab): explicit user actions only.
    '设备上找不到这个文件夹：{path}': ('Folder not found on the device: {path}', '端末にこのフォルダーが見つかりません：{path}'),
    '条目标识无效。': ('Invalid item identifier.', '項目の識別子が無効です。'),
    '已请求设备打开：{name}': ('Asked the device to open: {name}', '端末に表示を要求しました：{name}'),
    '已下载到 {path}': ('Downloaded to {path}', '{path} にダウンロードしました'),
    '请选择要保存到的位置。': ('Choose where to save it.', '保存先を選んでください。'),
    '已删除：{name}': ('Deleted: {name}', '削除しました：{name}'),
    '已新建文件夹：{name}': ('Created folder: {name}', 'フォルダーを作成しました：{name}'),
    '已移动：{name}': ('Moved: {name}', '移動しました：{name}'),
    'QUADERNO 截屏': ('QUADERNO Screenshot', 'QUADERNO スクリーンショット'),
    '已保存截屏：{name}': ('Screenshot saved: {name}', 'スクリーンショットを保存しました：{name}'),
    '已保存截屏：{name}（桌面也放了一份）': (
        'Screenshot saved: {name} (a copy is on the Desktop)',
        'スクリーンショットを保存しました：{name}（デスクトップにもコピーしました）'),
    '第{page}页': ('p{page}', '{page}ページ'),
    '截屏转换失败：{detail}': ('Could not convert the screenshot: {detail}', 'スクリーンショットを変換できませんでした：{detail}'),
    'TrueScale · 截屏已保存': ('TrueScale · Screenshot saved', 'TrueScale · スクリーンショットを保存しました'),
    'TrueScale · 截屏失败': ('TrueScale · Screenshot failed', 'TrueScale · スクリーンショットに失敗しました'),
    '已将设备切换到网络模式。': ('Switched the device to network mode.', '端末をネットワークモードに切り替えました。'),
    '设备已处于网络模式，无需切换。': ('The device is already in network mode.', '端末はすでにネットワークモードです。'),
    '文件夹名称不能为空，也不能包含「/」。': ('A folder name cannot be empty or contain "/".', 'フォルダー名は空にできず、「/」も使えません。'),
    # deliver.sh, through the `text` action
    '未找到 pandoc': ('pandoc not found', 'pandoc が見つかりません'),
    '未找到 typst': ('typst not found', 'typst が見つかりません'),
    '缺少排版模板': ('The layout template is missing', 'レイアウトテンプレートがありません'),
    '无法进入渲染目录': ('Cannot enter the rendering folder', 'レンダリング用フォルダーに入れません'),
    '无法创建临时目录': ('Cannot create a temporary folder', '一時フォルダーを作成できません'),
    'TrueScale · 投递失败': ('TrueScale · Delivery failed', 'TrueScale · 送信に失敗しました'),
    'TrueScale · 已保存至 Received': ('TrueScale · Saved to Received', 'TrueScale · Received に保存しました'),
    '投递失败，请查看设备连接': ('Delivery failed. Check the device connection.', '送信に失敗しました。端末の接続を確認してください。'),
    '未选择文件': ('No files selected', 'ファイルが選択されていません'),
    '{file}：暂只支持 PDF、EPUB、Markdown 和 TXT': (
        '{file}: only PDF, EPUB, Markdown and TXT are supported for now',
        '{file}：現在は PDF・EPUB・Markdown・TXT のみ対応しています'),
    'TrueScale · 正在排版': ('TrueScale · Typesetting', 'TrueScale · 組版中'),
    '{file}，完成后自动投递': (
        '{file}. It will be sent when ready.',
        '{file}。完了後に自動で送信します。'),
    '{file}：电子书排版失败': ('{file}: could not typeset the e-book', '{file}：電子書籍を組版できませんでした'),
    '已投递 {sent} 个，失败 {failed} 个。{first}': (
        'Sent {sent}, failed {failed}. {first}', '{sent} 件送信、{failed} 件失敗。{first}'),
    '已投递 {sent} 个文件': ('Sent {sent} files', '{sent} 件のファイルを送信しました'),
    '已投递 1 个文件': ('Sent 1 file', '1 件のファイルを送信しました'),
    '剪贴板为空，已取消': ('The clipboard is empty — cancelled', 'クリップボードが空のため取り消しました'),
    'TrueScale · 本机渲染与设备直连自检': (
        'TrueScale · Local rendering and direct-connection self-check',
        'TrueScale · ローカルレンダリングと直接接続のセルフチェック'),
    '✅ PDF 渲染通过': ('✅ PDF rendering passed', '✅ PDF のレンダリングに成功'),
    '✅ 设备认证与目录读取通过；本次自检未上传文件。': (
        '✅ Device authentication and folder reading passed; no file was uploaded by this check.',
        '✅ 端末の認証とフォルダーの読み取りに成功しました。このチェックではファイルをアップロードしていません。'),
}


@functools.lru_cache(maxsize=1)
def language():
    """'zh', 'ja' or 'en'. The App passes its own UI language; otherwise follow macOS."""
    preferred = os.environ.get('QUADERNO_LANG', '')
    # Ctrl+1 runs outside the App: use the language chosen in the App's settings, else macOS's.
    # The App's preferences by file path: `defaults read <bundle id>` would resolve to a sandbox
    # container of the same bundle id (the App Store edition) instead of this App's own file.
    app_preferences = str(Path.home() / 'Library/Preferences' / APP_BUNDLE_ID)
    for domain, key in ([] if preferred else [(app_preferences, 'AppLanguage'), ('-g', 'AppleLanguages')]):
        try:
            output = subprocess.run(['/usr/bin/defaults', 'read', domain, key],
                                    capture_output=True, text=True, timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            continue
        match = re.search(r'([A-Za-z]{2,3})[-_A-Za-z]*', output.stdout.replace('(', ' '))
        if output.returncode == 0 and match:
            preferred = match.group(1)
            break
    preferred = preferred.lower()
    return 'zh' if preferred.startswith('zh') else 'ja' if preferred.startswith('ja') else 'en'


def tr(text, **values):
    english, japanese = MESSAGES.get(text, (text, text))
    template = {'en': english, 'ja': japanese}.get(language(), text)
    return template.format(**values) if values else template


class DirectError(Exception):
    pass


class DeviceResponseError(DirectError):
    def __init__(self, status):
        self.status = status
        super().__init__(tr('设备请求失败（HTTP {status}）。请检查配对和连接。', status=status))


class ConnectionFailure(DirectError):
    def __init__(self, code):
        self.code = code
        message = tr("设备证书与已配对设备不一致，已拒绝连接。" if code == 90 else
                     "设备地址无法连接，请检查 USB / Wi-Fi 和设备唤醒状态。")
        super().__init__(message)


class DeviceUnreachable(DirectError):
    """Direct connection failed before anything was uploaded: safe to hand the PDF to the official app."""


class UsbDisconnected(DirectError):
    def __init__(self):
        super().__init__(tr('USB 上未检测到 QUADERNO，设备已断开。请重新插拔 USB 线后重试。'))


class UsbLinkDown(DirectError):
    def __init__(self):
        super().__init__(tr('QUADERNO 仍在 USB 上，但 USB 网络链路已断开，自动恢复未成功（常见于 Mac 睡眠唤醒后）。请重新插拔 USB 线后重试。'))


FUJITSU_USB_VENDOR = 0x04c5


def quaderno_in_ioreg(output):
    # One block per enumerated USB device; FMVDP51 (A5) and FMVDP41 (A4) share the prefix.
    for block in output.split('+-o ')[1:]:
        if (f'"idVendor" = {FUJITSU_USB_VENDOR}' in block and
                '"USB Product Name" = "FMVDP' in block):
            return True
    return False


# Plugged in, the device first enumerates as a USB serial device (product 0x1656) and only
# becomes a network device (0x1657) after the host writes this documented switch sequence to
# that serial port (dpt-rp1-py docs/linux-ethernet-over-usb.md, CDC/ECM variant for macOS).
# QUADERNO PC App does this silently; without it the device stays unreachable (observed).
SERIAL_MODE_PRODUCT = 0x1656
CDC_ECM_SWITCH = b'\x01\x00\x00\x01\x00\x00\x00\x01\x01\x04'


def serial_mode_port(ioreg_output):
    """The QUADERNO's /dev/cu.* port while it is in serial mode, else None."""
    for block in ('\n' + ioreg_output).split('\n+-o ')[1:]:
        if (f'"idVendor" = {FUJITSU_USB_VENDOR}' in block and
                f'"idProduct" = {SERIAL_MODE_PRODUCT}' in block):
            match = re.search(r'"IOCalloutDevice" = "(/dev/cu\.[^"]+)"', block)
            if match:
                return match.group(1)
            ports = glob.glob('/dev/cu.usbmodem*')
            return ports[0] if len(ports) == 1 else None
    return None


def switch_to_network_mode(wait=10):
    """Switch a serial-mode QUADERNO to Ethernet-over-USB. False when nothing needed switching."""
    try:
        output = subprocess.run(['/usr/sbin/ioreg', '-r', '-c', 'IOUSBHostDevice', '-l'],
                                capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    port = serial_mode_port(output)
    if not port:
        return False
    descriptor = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        attributes = termios.tcgetattr(descriptor)
        attributes[0] = attributes[1] = attributes[3] = 0  # raw: no processing, no echo
        attributes[2] |= termios.CLOCAL | termios.CREAD
        termios.tcsetattr(descriptor, termios.TCSANOW, attributes)
        os.write(descriptor, CDC_ECM_SWITCH)
        termios.tcdrain(descriptor)
    finally:
        os.close(descriptor)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:  # measured: re-enumerates and advertises within ~2 s
        if advertising_interfaces(dns_sd_output(['-B', '_dp_fujitsu._tcp', 'local.'], duration=1)):
            break
    return True


NETWORK_MODE_PRODUCT = 0x1657
IFM_AVALID, IFM_ACTIVE = 0x1, 0x2  # IOLinkStatus bits (IOKit/network/IONetworkMedium.h)


def usb_link_down(ioreg_output):
    """True when the QUADERNO is a USB network device whose Ethernet link reports inactive.

    Observed 2026-11-04: when the Mac sleeps, en5 goes link_off; after the Mac wakes the device
    stays enumerated (0x1657) but never raises the link again, even with its screen awake.
    """
    for block in ('\n' + ioreg_output).split('\n+-o ')[1:]:
        if (f'"idVendor" = {FUJITSU_USB_VENDOR}' in block and
                f'"idProduct" = {NETWORK_MODE_PRODUCT}' in block):
            match = re.search(r'"IOLinkStatus" = (\d+)', block)
            if not match:
                return False  # no network driver attached yet: nothing to judge
            status = int(match.group(1))
            return bool(status & IFM_AVALID) and not status & IFM_ACTIVE
    return False


def reenumerate_quaderno():
    """Software replug: ask macOS to re-enumerate the QUADERNO. No root needed (verified 2026-11-04).

    Calls IOUSBDeviceInterface187::USBDeviceReEnumerate through ctypes; vtable slots and UUIDs
    were taken from the macOS SDK headers with offsetof (Release 3, Open 8, Close 9, ReEnumerate 37).
    Returns True when the request was accepted.
    """
    import ctypes
    iokit = ctypes.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cf.CFUUIDGetConstantUUIDWithBytes.restype = ctypes.c_void_p
    cf.CFUUIDGetConstantUUIDWithBytes.argtypes = [ctypes.c_void_p] + [ctypes.c_uint8] * 16
    iokit.IOServiceNameMatching.restype = ctypes.c_void_p
    iokit.IOServiceNameMatching.argtypes = [ctypes.c_char_p]
    iokit.IOServiceGetMatchingServices.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    iokit.IOIteratorNext.restype = ctypes.c_uint32
    iokit.IOIteratorNext.argtypes = [ctypes.c_uint32]
    iokit.IOObjectRelease.argtypes = [ctypes.c_uint32]
    iokit.IOCreatePlugInInterfaceForService.argtypes = [
        ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int32)]

    def uuid_ref(hex_bytes):
        return cf.CFUUIDGetConstantUUIDWithBytes(None, *bytes.fromhex(hex_bytes))

    class UUIDBytes(ctypes.Structure):
        _fields_ = [('bytes', ctypes.c_uint8 * 16)]

    user_client = uuid_ref('9dc7b7809ec011d4a54f000a27052861')  # kIOUSBDeviceUserClientTypeID
    plugin_id = uuid_ref('c244e858109c11d491d40050e4c6426f')    # kIOCFPlugInInterfaceID
    device_187 = UUIDBytes((ctypes.c_uint8 * 16)(*bytes.fromhex('3c9ee1eb240211b28e7e000a27801e86')))

    def method(instance, slot, restype, *argtypes):
        vtable = ctypes.cast(ctypes.cast(instance, ctypes.POINTER(ctypes.c_void_p))[0],
                             ctypes.POINTER(ctypes.c_void_p))
        return ctypes.CFUNCTYPE(restype, ctypes.c_void_p, *argtypes)(vtable[slot])

    requested = False
    for name in (b'FMVDP51', b'FMVDP41'):  # A5 / A4
        iterator = ctypes.c_uint32()
        # IOServiceGetMatchingServices consumes the matching dictionary.
        if iokit.IOServiceGetMatchingServices(0, iokit.IOServiceNameMatching(name), ctypes.byref(iterator)):
            continue
        try:
            while service := iokit.IOIteratorNext(iterator):
                try:
                    plugin, score = ctypes.c_void_p(), ctypes.c_int32()
                    if iokit.IOCreatePlugInInterfaceForService(service, user_client, plugin_id,
                                                               ctypes.byref(plugin), ctypes.byref(score)):
                        continue
                    device = ctypes.c_void_p()
                    method(plugin, 1, ctypes.c_int32, UUIDBytes, ctypes.POINTER(ctypes.c_void_p))(
                        plugin, device_187, ctypes.byref(device))
                    method(plugin, 3, ctypes.c_uint32)(plugin)
                    if not device:
                        continue
                    try:
                        if method(device, 8, ctypes.c_int32)(device) == 0:  # USBDeviceOpen
                            requested |= method(device, 37, ctypes.c_int32, ctypes.c_uint32)(device, 0) == 0
                            method(device, 9, ctypes.c_int32)(device)    # USBDeviceClose
                    finally:
                        method(device, 3, ctypes.c_uint32)(device)
                finally:
                    iokit.IOObjectRelease(service)
        finally:
            iokit.IOObjectRelease(iterator.value)
    return requested


def usb_link_stuck_now():
    try:
        output = subprocess.run(['/usr/sbin/ioreg', '-r', '-c', 'IOUSBHostDevice', '-l'],
                                capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    return usb_link_down(output)


def recover_usb_link(wait=12):
    """Re-enumerate a QUADERNO whose USB link is stuck down. True when a recovery was attempted."""
    if not usb_link_stuck_now():
        return False
    try:
        if not reenumerate_quaderno():
            return False
    except (OSError, AttributeError):
        return False
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:  # measured: link active within ~2 s, still in 0x1657
        time.sleep(0.5)
        try:
            switch_to_network_mode(wait=max(1, deadline - time.monotonic()))  # in case it came back as serial
        except OSError:
            pass
        if advertising_interfaces(dns_sd_output(['-B', '_dp_fujitsu._tcp', 'local.'], duration=1)):
            break
    return True


def prepare_usb():
    """Bring a USB-attached QUADERNO to a reachable state; failures are left to discovery to report."""
    try:
        switch_to_network_mode()
    except OSError:
        pass  # port busy or gone: the official app may be switching it; carry on and let discovery decide
    recover_usb_link()


def quaderno_on_usb():
    """True / False when the USB bus could be read; None when it could not."""
    try:
        result = subprocess.run(['/usr/sbin/ioreg', '-r', '-c', 'IOUSBHostDevice', '-d', '1'],
                                capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return quaderno_in_ioreg(result.stdout) if result.returncode == 0 else None


def dns_sd_output(arguments, duration=0.8):
    """Bounded read of macOS mDNS, including interface-scoped IPv6 records."""
    process = subprocess.Popen(['/usr/bin/dns-sd'] + arguments, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    output = []
    end = time.monotonic() + duration
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while time.monotonic() < end:
            if not selector.select(max(0, end - time.monotonic())):
                break
            data = os.read(process.stdout.fileno(), 65536)
            if not data:
                break
            output.append(data)
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()
    return b''.join(output).decode(errors='replace')


def advertising_interfaces(service_output):
    interfaces = set()
    for line in service_output.splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[1] == 'Add' and '_dp_fujitsu._tcp.' in fields:
            interfaces.add(fields[3])
    return interfaces


def parse_endpoints(address_output, service_output):
    # Prefer the interface actually advertising Fujitsu Digital Paper, not a generic
    # Android hostname on the Wi-Fi LAN. Every candidate still has to pass TLS pinning.
    interfaces = advertising_interfaces(service_output)
    candidates = []
    for line in address_output.splitlines():
        fields = line.split()
        if len(fields) < 7 or fields[1] != 'Add':
            continue
        address = fields[5]
        try:
            ip = ipaddress.ip_address(address.split('%', 1)[0])
        except ValueError:
            continue
        if ip.is_unspecified or ip.is_loopback or ip.is_multicast:
            continue
        target = '[' + address.lower() + ']' if ip.version == 6 else address
        if target not in [item[2] for item in candidates]:
            candidates.append((fields[3] not in interfaces, ip.version != 6, target))
    return [target for _, _, target in sorted(candidates, key=lambda item: item[:2])]


def discover_endpoints(address):
    host = address.strip('[]')
    try:
        ipaddress.ip_address(host.split('%', 1)[0])
        return [address]
    except ValueError:
        pass
    if not host.rstrip('.').lower().endswith('.local'):
        return [address]
    with ThreadPoolExecutor(max_workers=2) as executor:
        addresses = executor.submit(dns_sd_output, ['-G', 'v4v6', host])
        services = executor.submit(dns_sd_output, ['-B', '_dp_fujitsu._tcp', 'local.'])
        service_output = services.result()
        found = parse_endpoints(addresses.result(), service_output)
    # The device can drop off the USB bus while still plugged in; it then stays gone
    # until replugged. Fail at once instead of timing out against a same-named LAN host.
    # A Wi-Fi connection still advertises the service, so it is never blocked here.
    if not advertising_interfaces(service_output):
        if quaderno_on_usb() is False:
            raise UsbDisconnected()
        # Still on USB but the link is down (recovery already ran in prepare_usb):
        # say so instead of timing out against a same-named LAN host.
        if usb_link_stuck_now():
            raise UsbLinkDown()
    return found or [address]


BASE_REQUEST_SECONDS = 120
# Conservative floor for USB Ethernet / Wi-Fi throughput when sizing transfer limits.
MIN_TRANSFER_BYTES_PER_SECOND = 256 * 1024
STALL_SECONDS = 90  # no byte moved for this long: the link is dead
# Cap below ProcessRunner's 3600 s outer deadline: on a huge transfer the user must see a
# specific request error before the App kills the whole helper process.
MAX_TRANSFER_SECONDS = 3000
# Cleanup runs on an already-failed path. A DELETE must not inherit the upload's long limit,
# and the whole sweep must finish inside a bounded budget.
CLEANUP_REQUEST_SECONDS = 15
CLEANUP_BUDGET_SECONDS = 60


def transfer_timeout(size):
    """Total curl time limit: base + size at the floor rate, capped by MAX_TRANSFER_SECONDS."""
    scaled = BASE_REQUEST_SECONDS + -(-max(0, size) // MIN_TRANSFER_BYTES_PER_SECOND)
    return min(MAX_TRANSFER_SECONDS, scaled)


def file_sha256(path):
    """Hash a file in 1 MiB chunks: peak memory is bounded, not proportional to file size."""
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


class Response:
    def __init__(self, status, headers, content):
        self.status_code, self.headers, self.content = status, headers, content

    def json(self):
        return json.loads(self.content)


class Device:
    def __init__(self, settings, private_key, client_id):
        self.settings = settings
        self.private_key, self.client_id = private_key, client_id
        self.cookie = ''
        self.target = settings.get('address', '')
        self.base = 'https://digitalpaper.local:8443'

    def request(self, method, endpoint, *, json_body=None, source=None, allow_missing=False,
                transfer_size=0, verify_sha256=None, time_limit=None, output_path=None):
        # System curl resolves USB mDNS correctly on macOS; no proxy or external runtime.
        # transfer_size: bytes expected to move (upload / readback); scales the total time limit.
        # verify_sha256: hash the curl output file in chunks instead of loading it into memory.
        # time_limit: override for short, failure-path requests (cleanup) or unknown-size downloads.
        # output_path: stream a binary response straight to disk, never into the Python heap.
        max_time = time_limit if time_limit is not None else transfer_timeout(transfer_size)
        with tempfile.TemporaryDirectory(prefix='quaderno-http-') as directory:
            directory = Path(directory)
            headers, output = directory / 'headers', directory / 'response'
            body = str(output_path) if output_path is not None else str(output)
            args = ['/usr/bin/curl', '--silent', '--show-error', '--noproxy', '*',
                    '--connect-timeout', '2', '--max-time', str(max_time), '--request', method,
                    # A link that stops moving data (e.g. Mac slept mid-transfer) fails after
                    # STALL_SECONDS instead of waiting out a long size-scaled limit.
                    '--speed-limit', '1', '--speed-time', str(STALL_SECONDS),
                    '--connect-to', 'digitalpaper.local:8443:' + self.target + ':8443',
                    '--insecure', '--pinnedpubkey', self.settings['public_key_pin'],
                    '--dump-header', str(headers), '--output', body, '--write-out', '%{http_code}',
                    '--config', '-']
            config = ''
            if self.cookie:
                config += 'header = "Cookie: Credentials=' + self.cookie + '"\n'
            if json_body is not None:
                payload = directory / 'request.json'
                payload.write_text(json.dumps(json_body))
                os.chmod(payload, 0o600)
                args += ['--header', 'Content-Type: application/json', '--data-binary', '@' + str(payload)]
            if source is not None:
                # curl form quoting protects spaces, semicolons and quotes in paths.
                escaped = str(source).replace('\\', '\\\\').replace('"', '\\"')
                args += ['--form', 'file=@"' + escaped + '";filename=document.pdf;type=application/pdf']
            args += [self.base + endpoint]
            result = subprocess.run(args, input=config.encode(), capture_output=True, timeout=max_time + 10)
            if result.returncode:
                raise ConnectionFailure(result.returncode)
            status = int(result.stdout)
            header_map = {}
            for line in headers.read_text().splitlines():
                if ':' in line:
                    key, value = line.split(':', 1)
                    header_map[key.lower()] = value.strip()
            if status == 404 and allow_missing:
                return None
            if not 200 <= status < 300:
                raise DeviceResponseError(status)
            if verify_sha256 is not None:
                # curl already wrote the body to disk; verify it there and return no body bytes.
                # A full readback of a 1 GB PDF must not allocate 1 GB of Python heap.
                if file_sha256(Path(body)) != verify_sha256:
                    raise DirectError(tr('文件已上传，但回读校验不一致。请保留本地 PDF 并检查设备。'))
                return Response(status, header_map, b'')
            if output_path is not None:
                return Response(status, header_map, b'')
            return Response(status, header_map, output.read_bytes())

    def cached_endpoint(self):
        if not self.settings.get('address') or not self.settings.get('public_key_pin'):
            return None
        try:
            cached = json.loads((ROOT / 'endpoint-cache.json').read_text())
            if (cached.get('address') != self.settings['address'] or
                cached.get('public_key_pin') != self.settings['public_key_pin']):
                return None
            target = cached['target']
            ipaddress.ip_address(target.strip('[]').split('%', 1)[0])
            return target
        except (OSError, ValueError, KeyError):
            return None

    def remember_endpoint(self):
        if not self.settings.get('address') or not self.settings.get('public_key_pin'):
            return
        try:
            save_private(ROOT / 'endpoint-cache.json', json.dumps({
                'address': self.settings['address'],
                'public_key_pin': self.settings['public_key_pin'],
                'target': self.target}).encode())
        except OSError:
            pass  # A cache write failure must not invalidate successful authentication.

    def authenticate(self):
        # Reuse only a numeric address, never bypass TLS pinning or fresh authentication.
        # A USB reconnect / changed interface falls back to full mDNS discovery.
        nonce = None
        last_error = None
        cached = self.cached_endpoint()
        if cached:
            self.target = cached
            try:
                nonce = self.request('GET', '/auth/nonce/' + quote(self.client_id, safe='')).json()['nonce']
            except (ConnectionFailure, DeviceResponseError) as error:
                last_error = error
        if nonce is None:
            for target in discover_endpoints(self.settings['address']):
                if target == cached:
                    continue
                self.target = target
                try:
                    nonce = self.request('GET', '/auth/nonce/' + quote(self.client_id, safe='')).json()['nonce']
                    break
                except (ConnectionFailure, DeviceResponseError) as error:
                    last_error = error
        if nonce is None:
            raise last_error or DirectError(tr('未找到可连接的已配对设备。'))
        signed = pkcs1_15.new(RSA.import_key(self.private_key)).sign(SHA256.new(nonce.encode()))
        response = self.request('PUT', '/auth', json_body={
            'client_id': self.client_id, 'nonce_signed': base64.b64encode(signed).decode()})
        cookie = response.headers.get('set-cookie', '').split(';', 1)[0]
        if not cookie.startswith('Credentials='):
            raise DirectError(tr('设备未返回有效的登录凭据。'))
        value = cookie.split('=', 1)[1]
        if not re.fullmatch(r'[A-Za-z0-9+/=_-]+', value):
            raise DirectError(tr('设备返回的登录凭据格式异常。'))
        self.cookie = value
        self.remember_endpoint()

    def discard_incomplete(self, document_id):
        """Best-effort delete of an unverified entry. A short explicit deadline keeps a failed
        upload from turning into a second long stall; the failure reason is persisted."""
        try:
            self.request('DELETE', '/documents/' + entry_id(document_id),
                         allow_missing=True, time_limit=CLEANUP_REQUEST_SECONDS)
        except (DirectError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            remember_orphan(self.settings.get('public_key_pin', ''), document_id, str(error))

    def remove_orphans(self):
        pin = self.settings.get('public_key_pin', '')
        deadline = time.monotonic() + CLEANUP_BUDGET_SECONDS
        for document_id in pending_orphans(pin):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break  # bounded sweep: never 20 x 120 s in front of a real delivery
            try:
                self.request('DELETE', '/documents/' + entry_id(document_id), allow_missing=True,
                             time_limit=min(CLEANUP_REQUEST_SECONDS, max(1, int(remaining))))
            except (DirectError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                mark_orphan_failure(pin, document_id, str(error))
                continue  # still unreachable or refused: recorded, retried next connection
            forget_orphan(pin, document_id)

    def resolve(self, path):
        response = self.request('GET', '/resolve/entry/path/' + quote(path, safe=''), allow_missing=True)
        return response.json() if response else None

    def check(self):
        self.authenticate()
        root = self.resolve('Document')
        if not root:
            raise DirectError(tr('无法读取设备 Document 目录。'))
        entries = self.request('GET', '/folders/' + root['entry_id'] + '/entries2').json()['entry_list']
        return {'ok': True, 'message': tr('设备已直连，认证及目录读取通过'), 'root_entries': len(entries), 'connection': self.target}

    def screenshot(self, folder, fmt, desktop=None):
        """Save what the device shows now, ink included, into folder as png / jpeg / pdf.

        The name says what was on screen: the open document's title and page, then the time
        (falls back to 「QUADERNO 截屏」 on the home screen). With desktop set, a copy also goes
        there for immediate use, unless folder already is that directory.

        PNG comes from the device (lossless; for e-ink greys it is also smaller than the device's
        JPEG). JPEG and PDF are converted locally with sips; the PDF page is the screen's physical
        size (227.18 dpi, 156.97 x 209.30 mm on A5), so it prints and shares at true 1:1.
        """
        folder = Path(folder).expanduser()
        folder.mkdir(parents=True, exist_ok=True)
        png = self.request('GET', '/system/controls/screen_shot').content
        extension = {'png': 'png', 'jpeg': 'jpg', 'pdf': 'pdf'}[fmt]
        try:
            viewing = self.request('GET', '/viewer/status/current_viewing', allow_missing=True)
            label = viewing_label(viewing.json()) if viewing else None
        except (DirectError, ValueError):
            label = None
        stem = (label or tr('QUADERNO 截屏')) + ' ' + datetime.now().strftime('%Y-%m-%d %H.%M.%S')
        target = unique_path(folder, stem, extension)
        with tempfile.TemporaryDirectory(prefix='quaderno-shot-') as work:
            source = Path(work) / 'screen.png'
            source.write_bytes(png)
            if fmt == 'png':
                command = None
            elif fmt == 'jpeg':
                command = ['/usr/bin/sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '90', str(source)]
            else:
                command = ['/usr/bin/sips', '-s', 'dpiWidth', '227.18', '-s', 'dpiHeight', '227.18',
                           '-s', 'format', 'pdf', str(source)]
            if command:
                converted = Path(work) / ('converted.' + extension)
                result = subprocess.run(command + ['--out', str(converted)], capture_output=True, timeout=60)
                if result.returncode or not converted.exists():
                    raise DirectError(tr('截屏转换失败：{detail}', detail=result.stderr.decode(errors='replace')[-160:]))
                shutil.copyfile(converted, target)
            else:
                target.write_bytes(png)
        result = {'ok': True, 'message': tr('已保存截屏：{name}', name=target.name), 'path': str(target)}
        if desktop is not None:
            desktop = Path(desktop).expanduser()
            if desktop.is_dir() and desktop.resolve() != folder.resolve():
                copy = unique_path(desktop, stem, extension)
                shutil.copyfile(target, copy)
                result['desktop_path'] = str(copy)
                result['message'] = tr('已保存截屏：{name}（桌面也放了一份）', name=target.name)
        return result

    # ---- File management: only explicit actions from the App's 设备文件 tab ----

    def browse(self, path):
        folder = self.resolve(path)
        if not folder or folder.get('entry_type', 'folder') != 'folder':
            raise DirectError(tr('设备上找不到这个文件夹：{path}', path=path))
        items = self.request('GET', '/folders/' + folder['entry_id'] + '/entries2').json()['entry_list']
        entries = [{'id': item['entry_id'], 'name': item.get('entry_name', ''), 'type': item.get('entry_type', ''),
                    'path': item.get('entry_path', ''), 'size': item.get('file_size'),
                    'modified': item.get('modified_date') or item.get('created_date')} for item in items]
        entries.sort(key=lambda entry: (entry['type'] != 'folder', entry['name'].lower()))
        return {'ok': True, 'message': '', 'entries': entries,
                'folder': {'id': folder['entry_id'], 'path': folder.get('entry_path') or path}}

    def open_document(self, document_id, name):
        self.request('PUT', '/viewer/controls/open2', json_body={'document_id': entry_id(document_id), 'page': 1})
        return {'ok': True, 'message': tr('已请求设备打开：{name}', name=name)}

    def download(self, document_id, destination):
        if not destination or not Path(destination).is_absolute():
            raise DirectError(tr('请选择要保存到的位置。'))
        destination = Path(destination)
        temporary = destination.with_name('.' + destination.name + '.download')
        # Size is unknown without an extra metadata request, so use the capped ceiling rather
        # than the 120 s metadata baseline. curl streams straight into the temporary file:
        # a 1 GB document never passes through Response.content.
        try:
            self.request('GET', '/documents/' + entry_id(document_id) + '/file',
                         time_limit=MAX_TRANSFER_SECONDS, output_path=temporary)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        return {'ok': True, 'message': tr('已下载到 {path}', path=destination), 'path': str(destination)}

    def delete(self, item_id, kind, name):
        collection = 'folders' if kind == 'folder' else 'documents'
        self.request('DELETE', '/' + collection + '/' + entry_id(item_id))
        return {'ok': True, 'message': tr('已删除：{name}', name=name)}

    def make_folder(self, parent_id, name):
        name = (name or '').strip()
        if not name or '/' in name:
            raise DirectError(tr('文件夹名称不能为空，也不能包含「/」。'))
        self.request('POST', '/folders2', json_body={'folder_name': name, 'parent_folder_id': entry_id(parent_id)})
        return {'ok': True, 'message': tr('已新建文件夹：{name}', name=name)}

    def move(self, document_id, folder_id, name):
        self.request('PUT', '/documents/' + entry_id(document_id),
                     json_body={'parent_folder_id': entry_id(folder_id)})
        return {'ok': True, 'message': tr('已移动：{name}', name=name)}

    def upload(self, source, destination='Document/Received'):
        if not self.cookie:
            self.authenticate()
        parent = self.resolve(destination)
        if not parent or parent.get('entry_type', 'folder') != 'folder':
            if destination == 'Document/Received':
                raise DirectError(tr('设备 Received 文件夹不存在，未上传文件。'))
            raise DirectError(tr('设备上找不到这个文件夹：{path}', path=destination))
        # Entries left by an earlier interrupted upload would otherwise take this file's name.
        self.remove_orphans()
        remote = destination + '/' + source.name
        if self.resolve(remote):
            remote = destination + '/' + source.stem[:100] + '_' + uuid.uuid4().hex[:8] + '.pdf'
        # Size and hash come from stat/streaming, never from holding the whole PDF in memory.
        size = source.stat().st_size
        expected = file_sha256(source)
        created = self.request('POST', '/documents2', json_body={
            'file_name': remote.split('/')[-1], 'parent_folder_id': parent['entry_id'],
            'document_source': ''}).json()
        document_id = created['document_id']
        # From here until readback passes, a failure leaves an entry with missing or wrong content
        # on the device: remove it (or remember it for the next connection) before reporting.
        try:
            self.request('PUT', '/documents/' + document_id + '/file', source=source, transfer_size=size)
            # Start device rendering immediately after the complete upload.
            # Success is still withheld until readback and directory verification finish.
            display_requested = False
            try:
                self.request('PUT', '/viewer/controls/open2',
                             json_body={'document_id': document_id, 'page': 1})
                display_requested = True
            except (DirectError, OSError, subprocess.TimeoutExpired):
                pass
            # request() hashes curl's output file in chunks and returns no body bytes.
            self.request('GET', '/documents/' + document_id + '/file',
                         transfer_size=size, verify_sha256=expected)
        except Exception:
            # KeyboardInterrupt / SystemExit must not issue another HTTPS request on their way out.
            self.discard_incomplete(document_id)
            raise
        info = self.resolve(remote)
        if not info or info['entry_id'] != document_id:
            raise DirectError(tr('回读已通过，但设备目录未确认新文件。'))
        name = remote.rsplit('/', 1)[-1]
        message = tr('已保存至 {folder}：{name}（回读通过，已请求设备打开）' if display_requested else
                     '已保存至 {folder}：{name}（回读通过，设备未接受打开请求，请从 {folder} 打开）',
                     name=name, folder=destination.rsplit('/', 1)[-1])
        record_delivery(name, display_requested, document_id=document_id, remote=remote)
        return {'ok': True, 'message': message, 'path': remote, 'sha256': expected,
                'display_requested': display_requested}



ORPHAN_LIMIT = 20


def load_orphans():
    try:
        data = json.loads((ROOT / 'orphans.json').read_text(encoding='utf-8'))
        return [item for item in data if isinstance(item, dict) and 'pin' in item and 'id' in item]
    except (OSError, ValueError, TypeError, UnicodeError):
        return []


def pending_orphans(pin):
    return [item['id'] for item in load_orphans() if item['pin'] == pin]


def remember_orphan(pin, document_id, error=None):
    entry = {'pin': pin, 'id': document_id}
    if error:
        entry['last_error'] = error[:200]
    orphans = [item for item in load_orphans() if item['id'] != document_id]
    orphans = (orphans + [entry])[-ORPHAN_LIMIT:]
    try:
        save_private(ROOT / 'orphans.json', json.dumps(orphans).encode())
    except OSError:
        pass


def mark_orphan_failure(pin, document_id, error):
    """Keep the last cleanup failure visible instead of silently continuing."""
    orphans = load_orphans()
    for item in orphans:
        if item['pin'] == pin and item['id'] == document_id:
            item['last_error'] = error[:200]
    try:
        save_private(ROOT / 'orphans.json', json.dumps(orphans).encode())
    except OSError:
        pass


def forget_orphan(pin, document_id):
    orphans = load_orphans()
    remaining = [item for item in orphans if not (item['pin'] == pin and item['id'] == document_id)]
    if len(remaining) != len(orphans):
        try:
            save_private(ROOT / 'orphans.json', json.dumps(remaining).encode())
        except OSError:
            pass


HISTORY_LIMIT = 50


def record_delivery(name, display_requested, via='direct', document_id=None, remote=None):
    """Append a verified delivery for the App's「最近投递」. Never fails the delivery itself."""
    append_history({'status': 'ok', 'name': name, 'opened': display_requested, 'via': via,
                    'document_id': document_id, 'remote': remote})


def record_failure(name, message, kept=None):
    """A failed delivery, with the local PDF kept for retry (shown with 重试 / 在 Finder 中显示)."""
    append_history({'status': 'failed', 'name': name, 'message': message,
                    'kept': kept if kept and Path(kept).exists() else None})


def append_history(entry):
    # QUADERNO_SOURCE: clipboard (Ctrl+1) / finder (right-click) / app / files (Device Files) / retry.
    entry = {'time': datetime.now().astimezone().isoformat(timespec='seconds'),
             'source': os.environ.get('QUADERNO_SOURCE', 'app'), **entry}
    path = ROOT / 'history.jsonl'
    try:
        lines = path.read_text().splitlines() if path.exists() else []
        lines = (lines + [json.dumps(entry, ensure_ascii=False)])[-HISTORY_LIMIT:]
        save_private(path, ('\n'.join(lines) + '\n').encode())
    except OSError:
        pass


def app_preference(key):
    """A value the App saved in its own preferences (read by file path: see language())."""
    try:
        result = subprocess.run(['/usr/bin/defaults', 'read', str(Path.home() / 'Library/Preferences' / APP_BUNDLE_ID), key],
                                capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def viewing_label(status):
    """「标题 第3页」from /viewer/status/current_viewing; None when no document is open."""
    views = [view for view in (status or {}).get('views') or [] if isinstance(view, dict)]
    if not views:
        return None
    view = views[0]
    title = view.get('title') or Path(view.get('entry_path') or '').stem
    # Drop the time suffix TrueScale adds to clipboard deliveries; the screenshot carries its own.
    title = re.sub(r'_\d{8}-\d{6}$', '', title)
    title = re.sub(r'[/\\:*?"<>|\x00-\x1f]', '_', title).strip(' ._')[:40].strip()
    if not title:
        return None
    pages = [str(v.get('current_page')) for v in views
             if v.get('entry_id') == view.get('entry_id') and str(v.get('current_page') or '').isdigit()]
    if not pages:
        return title
    return title + ' ' + tr('第{page}页', page='–'.join(dict.fromkeys(pages)))


def unique_path(folder, stem, extension):
    target = folder / (stem + '.' + extension)
    counter = 2
    while target.exists():
        target = folder / f'{stem} {counter}.{extension}'
        counter += 1
    return target


def screenshot_desktop_copy():
    """App 设置「同时在桌面放一份」，默认开。"""
    return app_preference('ScreenshotDesktopCopy') not in ('0', 'false', 'NO')


def screenshot_settings(folder=None, fmt=None):
    """Explicit arguments win; otherwise the App's 截屏导出 settings; otherwise Pictures, PNG."""
    folder = folder or app_preference('ScreenshotFolder') or str(Path.home() / 'Pictures' / tr('QUADERNO 截屏'))
    fmt = (fmt or app_preference('ScreenshotFormat') or 'png').lower()
    return folder, fmt if fmt in ('png', 'jpeg', 'pdf') else 'png'


def entry_id(value):
    """Device entry ids go into URL paths; accept only the id alphabet the device uses."""
    if not value or not re.fullmatch(r'[A-Za-z0-9_-]+', value):
        raise DirectError(tr('条目标识无效。'))
    return value


def save_private(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_device():
    if not (ROOT / 'connection.json').exists():
        raise DirectError(tr('尚未配置直连。请在 App 的「设置 → 设备」中迁移现有配对。'))
    settings = json.loads((ROOT / 'connection.json').read_text())
    return Device(settings, (ROOT / 'privatekey.pem').read_bytes(),
                  (ROOT / 'clientid.txt').read_text().strip())


def connect_device():
    """Load the pairing and authenticate. Any failure here happened before an upload started."""
    if os.environ.get('QUADERNO_DIRECT_DISABLED') == '1':  # exercise the fallback path on purpose
        raise DeviceUnreachable(tr('设备地址无法连接，请检查 USB / Wi-Fi 和设备唤醒状态。'))
    try:
        prepare_usb()
        device = load_device()
        device.authenticate()
        return device
    except DirectError as error:
        raise DeviceUnreachable(str(error)) from error
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        raise DeviceUnreachable(tr('无法连接设备，请检查 USB / Wi-Fi、设备唤醒状态及设备地址。')) from error


def official_app_running():
    if not OFFICIAL_APP.exists():
        return False
    result = subprocess.run(['/usr/bin/pgrep', '-f', str(OFFICIAL_APP / 'Contents/MacOS/')],
                            capture_output=True, timeout=5)
    return result.returncode == 0


def official_log():
    logs = list((Path.home() / 'Library/Application Support/Fujitsu').rglob('logfile.log'))
    return max(logs, key=lambda path: path.stat().st_mtime) if logs else None


def hand_off(pdf, timeout=60):
    """Minimum availability: let the running QUADERNO PC App deliver the PDF (its --print queue).

    The official client deletes the file it has uploaded, so it gets a same-named copy; a consumed
    copy means it took the file, new E_MW_* errors in its log mean delivery failed.
    """
    folder = Path(tempfile.mkdtemp(prefix='handoff-', dir=ROOT.parent))
    copy = folder / pdf.name
    shutil.copy2(pdf, copy)
    log = official_log()
    offset = log.stat().st_size if log else 0
    subprocess.run(['/usr/bin/open', '-gj', '-na', str(OFFICIAL_APP), '--args', '--print', str(copy)],
                   capture_output=True, timeout=30)
    status = 'unknown'
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not copy.exists():
            status = 'ok'
            break
        if log and log.exists() and log.stat().st_size > offset:
            with log.open('rb') as stream:
                stream.seek(offset)
                if re.search(rb'E_MW_DEVICE_NOT_FOUND|E_MW_CANCELLED|E_MW_UO_SRC_NO_VALID_CONTENT', stream.read()):
                    status = 'failed'
                    break
        time.sleep(0.2)
    if status != 'unknown':  # an unconfirmed copy stays for the client to pick up later
        shutil.rmtree(folder, ignore_errors=True)
    if status == 'failed':
        raise DirectError(tr('直连不可用，经 QUADERNO PC App 投递也失败（设备离线或投递被取消）。'))
    if status == 'unknown':
        raise DirectError(tr('已交给 QUADERNO PC App，但 60 秒内未确认送达。请在设备上检查。'))
    record_delivery(pdf.name, False, via='official')
    return {'ok': True, 'fallback': True, 'path': 'QUADERNO PC App',
            'message': tr('直连不可用，已经 QUADERNO PC App 投递：{name}（由官方 App 送达，未做回读校验）', name=pdf.name)}


def hand_off_or_raise(pdf, error):
    if official_app_running():
        return hand_off(pdf)
    if OFFICIAL_APP.exists():
        raise DirectError(tr('{error}（打开 QUADERNO PC App 后重试，可经官方 App 投递）', error=error)) from error
    raise error


def import_pairing(address):
    # Explicit setup action only. Runtime operations never consult the official app's files.
    origin = Path.home() / 'Library/Application Support/Fujitsu/QUADERNO PC App'
    candidates = [p for p in origin.rglob('privatekey.dat') if (p.parent / 'deviceid.dat').is_file()]
    if len(candidates) != 1:
        raise DirectError(tr('未找到唯一的已有配对。请先确认当前 Mac 的设备配对信息。'))
    parsed = urlparse('https://' + address)
    if not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.port:
        raise DirectError(tr('请输入主机名或 IP 地址，不含协议和端口。'))
    # Bootstrap validates the device's existing certificate chain and canonical hostname.
    # Store its public-key pin, so runtime no longer depends on vendor-installed trust roots.
    result = subprocess.run(['/usr/bin/curl', '--silent', '--show-error', '--noproxy', '*',
        '--connect-timeout', '5', '--max-time', '15', '--connect-to',
        'digitalpaper.local:8443:' + address + ':8443', '--output', '/dev/null',
        '--write-out', '%{certs}', 'https://digitalpaper.local:8443/'], capture_output=True, timeout=20)
    if result.returncode:
        raise DirectError(tr('无法确认设备证书。请连接已配对的设备并检查地址。'))
    match = re.search(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', result.stdout, re.S)
    if not match:
        raise DirectError(tr('无法读取设备证书。'))
    public_key = RSA.import_key(match.group()).publickey().export_key(format='DER')
    pin = 'sha256//' + base64.b64encode(hashlib.sha256(public_key).digest()).decode()
    settings = {'address': address, 'public_key_pin': pin}
    key = candidates[0].read_bytes()
    client_id = (candidates[0].parent / 'deviceid.dat').read_text().strip()
    # Validate the key and authenticate before writing anything.
    RSA.import_key(key)
    device = Device(settings, key, client_id)
    result = device.check()
    if (ROOT / 'connection.json').exists():
        old = json.loads((ROOT / 'connection.json').read_text())
        if old.get('public_key_pin') != settings['public_key_pin']:
            raise DirectError(tr('已有不同的设备配置；为避免覆盖，请先保留原配对再更换设备。'))
    save_private(ROOT / 'privatekey.pem', key)
    save_private(ROOT / 'clientid.txt', client_id.encode())
    save_private(ROOT / 'connection.json', json.dumps(settings).encode())
    return result


def clean_title(text):
    text = re.sub(r'!\[([^]]*)\]\([^)]*\)', r'\1', text)
    text = re.sub(r'\[([^]]+)\]\([^)]*\)', r'\1', text)
    text = re.sub(r'^[\s#>*+\-\d.)、]+', '', text)
    text = re.sub(r'[`*_~]', '', text)
    text = ''.join(c for c in text if not unicodedata.category(c).startswith('C'))
    text = re.sub(r'[/\\:*?"<>|]', '_', text)
    return re.sub(r'\s+', ' ', text).strip(' ._')[:32]


def prepare_markdown(text):
    text = text.lstrip('\ufeff')
    metadata = {}
    body = text
    frontmatter = re.match(r'\A---\s*\n(.*?)\n(?:---|\.\.\.)\s*(?:\n|$)', text, re.S)
    if frontmatter:
        try:
            value = yaml.safe_load(frontmatter.group(1))
            if isinstance(value, dict):
                metadata = value
                body = text[frontmatter.end():]
        except yaml.YAMLError:
            pass
    raw_title = metadata.get('title')
    title = clean_title(raw_title) if isinstance(raw_title, str) else ''
    candidates = []
    fenced = False
    fence = ''
    for line in body.splitlines():
        stripped = line.strip()
        if re.match(r'^(`{3,}|~{3,})', stripped):
            mark = stripped[0]
            if not fenced:
                fence, fenced = mark, True
            elif mark == fence:
                fenced = False
            continue
        if fenced or not stripped or re.fullmatch(r'[-=_* ]{3,}', stripped):
            continue
        heading = re.match(r'^#{1,6}\s+(.+?)(?:\s+#+)?$', stripped)
        if heading and not title:
            title = clean_title(heading.group(1))
            break
        if not re.match(r'^(https?://|!\[|\|)', stripped):
            candidates.append(stripped)
    if not title and candidates:
        title = clean_title(re.split(r'[。！？!?]', candidates[0], maxsplit=1)[0])
    title = title or tr('剪贴板摘录')
    # A title the author wrote in front matter stays the page title. A name derived from the first
    # heading or sentence only names the file and the PDF document: as `title` the template would
    # print it above the body, which already contains that heading or sentence (seen on device).
    if not (isinstance(raw_title, str) and clean_title(raw_title)):
        metadata.pop('title', None)
        metadata['pagetitle'] = title
    # Keep original body exactly; title selection changes metadata and filename only.
    rendered = '---\n' + yaml.safe_dump(metadata, allow_unicode=True, sort_keys=False) + '---\n\n' + body
    return title, rendered


@contextmanager
def connection_lock(timeout=30):
    # Device authentication has mutable nonce/session state shared by App and Ctrl+1.
    # Serialize complete transactions, not only the upload portion.
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(ROOT / 'transfer.lock', os.O_CREAT | os.O_RDWR, 0o600)
    acquired = False
    deadline = time.monotonic() + timeout
    try:
        while not acquired:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise DirectError(tr('另一项设备投递正在进行，请稍后重试。'))
                time.sleep(0.1)
        yield
    finally:
        if acquired:
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def load_clipboard_layout():
    path = ROOT.parent / 'clipboard-layout.json'
    if not path.exists():
        return None, 'factory'
    try:
        saved = json.loads(path.read_text())
        mode = 'shared' if saved.get('useShared', True) else 'independent'
        profile = saved[mode]
        for key, unit in [('pageW', 'mm'), ('pageH', 'mm'), ('margin', 'mm'),
                          ('bodySize', 'pt'), ('leading', 'em')]:
            value = profile[key]
            if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+)?' + unit, value):
                raise ValueError(key)
            number = float(value[:-len(unit)])
            if not 0 < number < 2000:
                raise ValueError(key)
        for key in ['latinFont', 'cjkFont', 'docLang']:
            if not isinstance(profile[key], str) or not profile[key] or '\x00' in profile[key]:
                raise ValueError(key)
        if type(profile['printTime']) is not bool:
            raise ValueError('printTime')
        return profile, mode
    except (OSError, ValueError, KeyError, TypeError):
        raise DirectError(tr('快捷键投递排版配置无效，请在 App 中检查排版设置。'))


def apply_clipboard_layout(args, directory):
    profile, mode = load_clipboard_layout()
    if profile is None:
        args.print_time = False
        args.doc_lang = 'zh'
        return mode
    args.font = [profile['latinFont'], profile['cjkFont']]
    args.page_width, args.page_height = profile['pageW'], profile['pageH']
    args.size, args.margin, args.leading = profile['bodySize'], profile['margin'], profile['leading']
    args.print_time, args.doc_lang = profile['printTime'], profile['docLang']
    # Font URLs are exported by CoreText for the exact chosen families and variants.
    paths = profile.get('fontFiles', [])
    valid = (isinstance(paths, list) and len(paths) >= 2 and all(
        isinstance(item, str) and Path(item).is_absolute() and Path(item).is_file() and
        Path(item).suffix.lower() in ['.ttf', '.ttc', '.otf', '.otc'] for item in paths))
    if valid:
        fonts = directory / 'fonts'
        fonts.mkdir(exist_ok=True)
        for index, item in enumerate(paths):
            link = fonts / ('selected-' + str(index) + Path(item).suffix)
            link.unlink(missing_ok=True)
            link.symlink_to(item)
        args.font_directory = str(fonts)
    else:
        args.font_directory = None
    return mode


def can_use_restricted_fonts(text):
    # Unknown scripts / emoji keep the full system fallback set, preventing missing glyphs.
    if '$' in text or '\\(' in text or '\\[' in text:
        return False  # Preserve the complete system font fallback for mathematics.
    ranges = [(0, 0x024F), (0x0370, 0x03FF), (0x2000, 0x22FF),
              (0x3000, 0x303F), (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xFF01, 0xFF65)]
    return all(any(low <= ord(char) <= high for low, high in ranges) for char in text)


def render_and_upload(args):
    directory = Path(args.directory).resolve()
    mode = apply_clipboard_layout(args, directory)
    text = Path(args.input).resolve().read_text()
    title, markdown = prepare_markdown(text)
    rendered = directory / 'render.md'
    rendered.write_text(markdown)
    # A file sent from Finder keeps its own name; clipboard text gets a dated title.
    name = clean_title(getattr(args, 'title', None) or '')
    stem = name or title + '_' + datetime.now().strftime('%Y%m%d-%H%M%S')
    output = directory / (stem + '.pdf')
    command = [args.pandoc, str(rendered), '-f', args.format, '--template=' + args.template,
               '-o', str(output), '--pdf-engine=' + args.typst]
    if args.print_time:
        command += ['-V', 'printtime=' + datetime.now().strftime('%Y-%m-%d %H:%M')]
    command += ['-M', 'lang=' + args.doc_lang]
    for font in args.font:
        command += ['-V', 'mainfont=' + font]
    for key, value in [('pagewidth', args.page_width), ('pageheight', args.page_height),
                       ('pagemargin', args.margin), ('bodysize', args.size), ('leading', args.leading)]:
        command += ['-V', key + '=' + value]
    if args.font_directory and can_use_restricted_fonts(text):
        command += ['--pdf-engine-opt=--ignore-system-fonts',
                    '--pdf-engine-opt=--font-path=' + args.font_directory]
    # One helper startup; overlap fresh authentication with local PDF rendering.
    # Keep the complete transaction serialized against other App / hotkey deliveries.
    with connection_lock():
        with ThreadPoolExecutor(max_workers=1) as executor:
            connection = executor.submit(connect_device)
            result = subprocess.run(command, cwd='/tmp', capture_output=True, timeout=120)
            if result.returncode:
                output.unlink(missing_ok=True)
                (directory / 'render.log').write_bytes(result.stderr)
                raise DirectError(tr('渲染失败：{detail}', detail=result.stderr.decode(errors='replace')[-160:]))
            try:
                try:
                    device = connection.result()
                except DeviceUnreachable as error:
                    result = hand_off_or_raise(output, error)
                else:
                    result = device.upload(output)
            except Exception as error:
                record_failure(output.name, str(error), kept=str(output))
                raise DirectError(tr('{error}；PDF 已保留：{path}', error=error, path=output)) from error
    output.unlink(missing_ok=True)
    result['layout_source'] = mode
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'import-pairing', 'upload', 'prepare', 'render-upload', 'text',
                                           'browse', 'open-doc', 'download', 'delete', 'mkdir', 'move', 'usb-switch',
                                           'screenshot', 'layout'])
    parser.add_argument('--address', default='Android.local')
    parser.add_argument('--file')
    parser.add_argument('--input')
    parser.add_argument('--markdown')
    parser.add_argument('--directory')
    parser.add_argument('--pandoc')
    parser.add_argument('--typst')
    parser.add_argument('--template')
    parser.add_argument('--format', default='markdown')
    parser.add_argument('--font', action='append', default=[])
    parser.add_argument('--page-width', default='157.1mm')
    parser.add_argument('--page-height', default='209.5mm')
    parser.add_argument('--margin', default='14mm')
    parser.add_argument('--size', default='10.5pt')
    parser.add_argument('--leading', default='0.85em')
    parser.add_argument('--font-directory')
    parser.add_argument('values', nargs='*', help='text: MESSAGE [key=value ...]')
    parser.add_argument('--path', default='Document', help='browse: device folder path')
    parser.add_argument('--id', help='device entry id for open-doc / download / delete / move; parent for mkdir')
    parser.add_argument('--kind', choices=['document', 'folder'], default='document')
    parser.add_argument('--name', default='', help='display name (messages) or new folder name')
    parser.add_argument('--to', help='download: absolute local path; move: destination folder id')
    parser.add_argument('--folder', help='upload: device folder path (default Document/Received); screenshot: local folder')
    parser.add_argument('--image-format', dest='image_format', choices=['png', 'jpeg', 'pdf'], help='screenshot format')
    parser.add_argument('--title', help='file name for render-upload; default derives one from the text')
    args = parser.parse_args()
    if args.action == 'text':
        # deliver.sh: print MESSAGE translated, with key=value substitutions.
        message, *pairs = args.values or ['']
        print(tr(message, **dict(pair.split('=', 1) for pair in pairs)))
        return
    try:
        if args.action == 'prepare':
            title, rendered = prepare_markdown(Path(args.input).read_text())
            Path(args.markdown).write_text(rendered)
            print(title)
            return
        if args.action == 'layout':
            # deliver.sh: the ⌃1 / Finder layout as JSON, {} when none is saved (factory defaults apply).
            profile, _ = load_clipboard_layout()
            print(json.dumps(profile or {}, ensure_ascii=False))
            return
        if args.action == 'render-upload':
            result = render_and_upload(args)
            print(json.dumps(result, ensure_ascii=False))
            return
        with connection_lock():
            if args.action == 'import-pairing':
                result = import_pairing(args.address)
            elif args.action == 'check':
                prepare_usb()
                result = load_device().check()
            elif args.action == 'usb-switch':
                switched = switch_to_network_mode()
                result = {'ok': True, 'message': tr('已将设备切换到网络模式。' if switched else '设备已处于网络模式，无需切换。')}
            elif args.action == 'screenshot':
                folder, fmt = screenshot_settings(args.folder, args.image_format)
                desktop = Path.home() / 'Desktop' if screenshot_desktop_copy() else None
                result = connect_device().screenshot(folder, fmt, desktop)
            elif args.action in ('browse', 'open-doc', 'download', 'delete', 'mkdir', 'move'):
                device = connect_device()
                result = {
                    'browse': lambda: device.browse(args.path),
                    'open-doc': lambda: device.open_document(args.id, args.name),
                    'download': lambda: device.download(args.id, args.to),
                    'delete': lambda: device.delete(args.id, args.kind, args.name),
                    'mkdir': lambda: device.make_folder(args.id, args.name),
                    'move': lambda: device.move(args.id, args.to, args.name),
                }[args.action]()
            else:
                source = Path(args.file)
                if not source.is_file() or source.suffix.lower() != '.pdf':
                    raise DirectError(tr('请选择已有的 PDF 文件。'))
                folder = args.folder or 'Document/Received'
                try:
                    try:
                        device = connect_device()
                    except DeviceUnreachable as error:
                        if folder != 'Document/Received':
                            raise  # the official app's queue can only deliver to Received
                        result = hand_off_or_raise(source, error)
                    else:
                        result = device.upload(source, folder)
                except Exception as error:
                    record_failure(source.name, str(error), kept=str(source))
                    raise
        print(json.dumps(result, ensure_ascii=False))
    except Exception as error:
        if isinstance(error, (OSError, subprocess.TimeoutExpired)):
            message = tr('无法连接设备，请检查 USB / Wi-Fi、设备唤醒状态及设备地址。')
        elif isinstance(error, DirectError):
            message = str(error)
        else:
            message = tr('设备协议或配对信息异常，请重新检查连接配置。')
        print(json.dumps({'ok': False, 'message': message}, ensure_ascii=False))
        sys.exit(1)


if __name__ == '__main__':
    main()
