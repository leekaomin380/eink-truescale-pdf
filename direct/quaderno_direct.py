#!/usr/bin/env python3
"""Local, pinned-TLS Quaderno transport. No official application at runtime.
Protocol reference: https://github.com/janten/dpt-rp1-py (MIT).
Delivery only reads folders and adds documents; it never deletes or overwrites anything.
Deleting, moving and creating folders happen only as explicit actions from the App's file manager.
"""
import argparse
import fcntl
import functools
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
    '已保存至 Received：{name}（回读通过，已请求设备打开）': (
        'Saved to Received: {name} (verified; asked the device to open it)',
        'Received に保存しました：{name}（照合済み、端末に表示を要求しました）'),
    '已保存至 Received：{name}（回读通过，设备未接受打开请求，请从 Received 打开）': (
        'Saved to Received: {name} (verified; the device did not accept the open request — open it from Received)',
        'Received に保存しました：{name}（照合済み。端末が表示要求を受け付けなかったため、Received から開いてください）'),
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
    '快捷投递排版配置无效，请在 App 中检查排版设置。': (
        'The quick-send layout settings are invalid. Check the layout in the app.',
        'クイック送信のレイアウト設定が無効です。App でレイアウトを確認してください。'),
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
    '文件夹名称不能为空，也不能包含「/」。': ('A folder name cannot be empty or contain "/".', 'フォルダー名は空にできず、「/」も使えません。'),
    # deliver.sh, through the `text` action
    '未找到 pandoc': ('pandoc not found', 'pandoc が見つかりません'),
    '未找到 typst': ('typst not found', 'typst が見つかりません'),
    '缺少排版模板': ('The layout template is missing', 'レイアウトテンプレートがありません'),
    '无法进入渲染目录': ('Cannot enter the rendering folder', 'レンダリング用フォルダーに入れません'),
    '无法创建临时目录': ('Cannot create a temporary folder', '一時フォルダーを作成できません'),
    'Quaderno · 投递失败': ('Quaderno · Delivery failed', 'Quaderno · 送信に失敗しました'),
    'Quaderno · 已保存至 Received': ('Quaderno · Saved to Received', 'Quaderno · Received に保存しました'),
    '投递失败，请查看设备连接': ('Delivery failed. Check the device connection.', '送信に失敗しました。端末の接続を確認してください。'),
    '未选择文件': ('No files selected', 'ファイルが選択されていません'),
    '{file}：暂只支持 PDF、Markdown 和 TXT': (
        '{file}: only PDF, Markdown and TXT are supported for now',
        '{file}：現在は PDF・Markdown・TXT のみ対応しています'),
    '已发送 {sent} 个，失败 {failed} 个。{first}': (
        'Sent {sent}, failed {failed}. {first}', '{sent} 件送信、{failed} 件失敗。{first}'),
    '已发送 {sent} 个文件': ('Sent {sent} files', '{sent} 件のファイルを送信しました'),
    '已发送 1 个文件': ('Sent 1 file', '1 件のファイルを送信しました'),
    '剪贴板为空，已取消': ('The clipboard is empty — cancelled', 'クリップボードが空のため取り消しました'),
    'Quaderno · 本机渲染与设备直连自检': (
        'Quaderno · Local rendering and direct-connection self-check',
        'Quaderno · ローカルレンダリングと直接接続のセルフチェック'),
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


FUJITSU_USB_VENDOR = 0x04c5


def quaderno_in_ioreg(output):
    # One block per enumerated USB device; FMVDP51 (A5) and FMVDP41 (A4) share the prefix.
    for block in output.split('+-o ')[1:]:
        if (f'"idVendor" = {FUJITSU_USB_VENDOR}' in block and
                '"USB Product Name" = "FMVDP' in block):
            return True
    return False


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
    if not advertising_interfaces(service_output) and quaderno_on_usb() is False:
        raise UsbDisconnected()
    return found or [address]


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

    def request(self, method, endpoint, *, json_body=None, source=None, allow_missing=False):
        # System curl resolves USB mDNS correctly on macOS; no proxy or external runtime.
        with tempfile.TemporaryDirectory(prefix='quaderno-http-') as directory:
            directory = Path(directory)
            headers, output = directory / 'headers', directory / 'response'
            args = ['/usr/bin/curl', '--silent', '--show-error', '--noproxy', '*',
                    '--connect-timeout', '2', '--max-time', '120', '--request', method,
                    '--connect-to', 'digitalpaper.local:8443:' + self.target + ':8443',
                    '--insecure', '--pinnedpubkey', self.settings['public_key_pin'],
                    '--dump-header', str(headers), '--output', str(output), '--write-out', '%{http_code}',
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
            result = subprocess.run(args, input=config.encode(), capture_output=True, timeout=125)
            if result.returncode:
                raise ConnectionFailure(result.returncode)
            status = int(result.stdout)
            header_map = {}
            for line in headers.read_text().splitlines():
                if ':' in line:
                    key, value = line.split(':', 1)
                    header_map[key.lower()] = value.strip()
            response = Response(status, header_map, output.read_bytes())
            if status == 404 and allow_missing:
                return None
            if not 200 <= status < 300:
                raise DeviceResponseError(status)
            return response

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
        content = self.request('GET', '/documents/' + entry_id(document_id) + '/file').content
        temporary = destination.with_name('.' + destination.name + '.download')
        temporary.write_bytes(content)
        os.replace(temporary, destination)
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

    def upload(self, source):
        if not self.cookie:
            self.authenticate()
        destination = 'Document/Received'
        parent = self.resolve(destination)
        if not parent or parent.get('entry_type', 'folder') != 'folder':
            raise DirectError(tr('设备 Received 文件夹不存在，未上传文件。'))
        remote = destination + '/' + source.name
        if self.resolve(remote):
            remote = destination + '/' + source.stem[:100] + '_' + uuid.uuid4().hex[:8] + '.pdf'
        created = self.request('POST', '/documents2', json_body={
            'file_name': remote.split('/')[-1], 'parent_folder_id': parent['entry_id'],
            'document_source': ''}).json()
        document_id = created['document_id']
        self.request('PUT', '/documents/' + document_id + '/file', source=source)
        # Start device rendering immediately after the complete upload.
        # Success is still withheld until readback and directory verification finish.
        display_requested = False
        try:
            self.request('PUT', '/viewer/controls/open2',
                         json_body={'document_id': document_id, 'page': 1})
            display_requested = True
        except (DirectError, OSError, subprocess.TimeoutExpired):
            pass
        expected = hashlib.sha256(source.read_bytes()).hexdigest()
        actual = hashlib.sha256(self.request('GET', '/documents/' + document_id + '/file').content).hexdigest()
        if actual != expected:
            raise DirectError(tr('文件已上传，但回读校验不一致。请保留本地 PDF 并检查设备。'))
        info = self.resolve(remote)
        if not info or info['entry_id'] != document_id:
            raise DirectError(tr('回读已通过，但设备目录未确认新文件。'))
        name = remote.rsplit('/', 1)[-1]
        message = tr('已保存至 Received：{name}（回读通过，已请求设备打开）' if display_requested else
                     '已保存至 Received：{name}（回读通过，设备未接受打开请求，请从 Received 打开）', name=name)
        record_delivery(name, display_requested)
        return {'ok': True, 'message': message, 'path': remote, 'sha256': expected,
                'display_requested': display_requested}



HISTORY_LIMIT = 50


def record_delivery(name, display_requested, via='direct'):
    """Append a verified delivery for the App's「最近投递」. Never fails the delivery itself."""
    # QUADERNO_SOURCE: clipboard (Ctrl+1) / finder (right-click) / app; set by the caller.
    entry = {'time': datetime.now().astimezone().isoformat(timespec='seconds'), 'name': name,
             'source': os.environ.get('QUADERNO_SOURCE', 'app'), 'opened': display_requested, 'via': via}
    path = ROOT / 'history.jsonl'
    try:
        lines = path.read_text().splitlines() if path.exists() else []
        lines = (lines + [json.dumps(entry, ensure_ascii=False)])[-HISTORY_LIMIT:]
        save_private(path, ('\n'.join(lines) + '\n').encode())
    except OSError:
        pass


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
    metadata['title'] = title
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
        raise DirectError(tr('快捷投递排版配置无效，请在 App 中检查排版设置。'))


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
                raise DirectError(tr('{error}；PDF 已保留：{path}', error=error, path=output)) from error
    output.unlink(missing_ok=True)
    result['layout_source'] = mode
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'import-pairing', 'upload', 'prepare', 'render-upload', 'text',
                                           'browse', 'open-doc', 'download', 'delete', 'mkdir', 'move'])
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
        if args.action == 'render-upload':
            result = render_and_upload(args)
            print(json.dumps(result, ensure_ascii=False))
            return
        with connection_lock():
            if args.action == 'import-pairing':
                result = import_pairing(args.address)
            elif args.action == 'check':
                result = load_device().check()
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
                try:
                    device = connect_device()
                except DeviceUnreachable as error:
                    result = hand_off_or_raise(source, error)
                else:
                    result = device.upload(source)
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
