#!/usr/bin/env python3
"""Local, pinned-TLS Quaderno transport. No official application at runtime.
Protocol reference: https://github.com/janten/dpt-rp1-py (MIT).
Only reads and creates documents; never deletes or overwrites device documents.
"""
import argparse
import fcntl
from contextlib import contextmanager
import base64
import hashlib
import json
import os
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


class DirectError(Exception):
    pass


class DeviceResponseError(DirectError):
    def __init__(self, status):
        self.status = status
        super().__init__(f'设备请求失败（HTTP {status}）。请检查配对和连接。')


class ConnectionFailure(DirectError):
    def __init__(self, code):
        self.code = code
        message = ("设备证书与已配对设备不一致，已拒绝连接。" if code == 90 else
                   "设备地址无法连接，请检查 USB / Wi-Fi 和设备唤醒状态。")
        super().__init__(message)


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


def parse_endpoints(address_output, service_output):
    # Prefer the interface actually advertising Fujitsu Digital Paper, not a generic
    # Android hostname on the Wi-Fi LAN. Every candidate still has to pass TLS pinning.
    interfaces = set()
    for line in service_output.splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[1] == 'Add' and '_dp_fujitsu._tcp.' in fields:
            interfaces.add(fields[3])
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
        found = parse_endpoints(addresses.result(), services.result())
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
            raise last_error or DirectError('未找到可连接的已配对设备。')
        signed = pkcs1_15.new(RSA.import_key(self.private_key)).sign(SHA256.new(nonce.encode()))
        response = self.request('PUT', '/auth', json_body={
            'client_id': self.client_id, 'nonce_signed': base64.b64encode(signed).decode()})
        cookie = response.headers.get('set-cookie', '').split(';', 1)[0]
        if not cookie.startswith('Credentials='):
            raise DirectError('设备未返回有效的登录凭据。')
        value = cookie.split('=', 1)[1]
        if not re.fullmatch(r'[A-Za-z0-9+/=_-]+', value):
            raise DirectError('设备返回的登录凭据格式异常。')
        self.cookie = value
        self.remember_endpoint()

    def resolve(self, path):
        response = self.request('GET', '/resolve/entry/path/' + quote(path, safe=''), allow_missing=True)
        return response.json() if response else None

    def check(self):
        self.authenticate()
        root = self.resolve('Document')
        if not root:
            raise DirectError('无法读取设备 Document 目录。')
        entries = self.request('GET', '/folders/' + root['entry_id'] + '/entries2').json()['entry_list']
        return {'ok': True, 'message': '设备已直连，认证及目录读取通过', 'root_entries': len(entries), 'connection': self.target}

    def upload(self, source):
        if not self.cookie:
            self.authenticate()
        destination = 'Document/Received'
        parent = self.resolve(destination)
        if not parent or parent.get('entry_type', 'folder') != 'folder':
            raise DirectError('设备 Received 文件夹不存在，未上传文件。')
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
            raise DirectError('文件已上传，但回读校验不一致。请保留本地 PDF 并检查设备。')
        info = self.resolve(remote)
        if not info or info['entry_id'] != document_id:
            raise DirectError('回读已通过，但设备目录未确认新文件。')
        name = remote.rsplit('/', 1)[-1]
        message = ('已保存至 Received：' + name +
                   ('（回读通过，已请求设备打开）' if display_requested else
                    '（回读通过，设备未接受打开请求，请从 Received 打开）'))
        return {'ok': True, 'message': message, 'path': remote, 'sha256': expected,
                'display_requested': display_requested}



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
        raise DirectError('尚未配置直连。请在 App 的「快捷投递」中迁移现有配对。')
    settings = json.loads((ROOT / 'connection.json').read_text())
    return Device(settings, (ROOT / 'privatekey.pem').read_bytes(),
                  (ROOT / 'clientid.txt').read_text().strip())


def import_pairing(address):
    # Explicit setup action only. Runtime operations never consult the official app's files.
    origin = Path.home() / 'Library/Application Support/Fujitsu/QUADERNO PC App'
    candidates = [p for p in origin.rglob('privatekey.dat') if (p.parent / 'deviceid.dat').is_file()]
    if len(candidates) != 1:
        raise DirectError('未找到唯一的已有配对。请先确认当前 Mac 的设备配对信息。')
    parsed = urlparse('https://' + address)
    if not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.port:
        raise DirectError('请输入主机名或 IP 地址，不含协议和端口。')
    # Bootstrap validates the device's existing certificate chain and canonical hostname.
    # Store its public-key pin, so runtime no longer depends on vendor-installed trust roots.
    result = subprocess.run(['/usr/bin/curl', '--silent', '--show-error', '--noproxy', '*',
        '--connect-timeout', '5', '--max-time', '15', '--connect-to',
        'digitalpaper.local:8443:' + address + ':8443', '--output', '/dev/null',
        '--write-out', '%{certs}', 'https://digitalpaper.local:8443/'], capture_output=True, timeout=20)
    if result.returncode:
        raise DirectError('无法确认设备证书。请连接已配对的设备并检查地址。')
    match = re.search(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', result.stdout, re.S)
    if not match:
        raise DirectError('无法读取设备证书。')
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
            raise DirectError('已有不同的设备配置；为避免覆盖，请先保留原配对再更换设备。')
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
    title = title or '剪贴板摘录'
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
                    raise DirectError('另一项设备投递正在进行，请稍后重试。')
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
        raise DirectError('快捷投递排版配置无效，请在 App 中检查排版设置。')


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
    output = directory / (title + '_' + datetime.now().strftime('%Y%m%d-%H%M%S') + '.pdf')
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
        device = load_device()
        with ThreadPoolExecutor(max_workers=1) as executor:
            authentication = executor.submit(device.authenticate)
            result = subprocess.run(command, cwd='/tmp', capture_output=True, timeout=120)
            if result.returncode:
                output.unlink(missing_ok=True)
                (directory / 'render.log').write_bytes(result.stderr)
                raise DirectError('渲染失败：' + result.stderr.decode(errors='replace')[-160:])
            try:
                authentication.result()
                result = device.upload(output)
            except Exception as error:
                raise DirectError(str(error) + '；PDF 已保留：' + str(output)) from error
    output.unlink(missing_ok=True)
    result['layout_source'] = mode
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['check', 'import-pairing', 'upload', 'prepare', 'render-upload'])
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
    args = parser.parse_args()
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
            else:
                source = Path(args.file)
                if not source.is_file() or source.suffix.lower() != '.pdf':
                    raise DirectError('请选择已有的 PDF 文件。')
                result = load_device().upload(source)
        print(json.dumps(result, ensure_ascii=False))
    except Exception as error:
        if isinstance(error, (OSError, subprocess.TimeoutExpired)):
            message = '无法连接设备，请检查 USB / Wi-Fi、设备唤醒状态及设备地址。'
        elif isinstance(error, DirectError):
            message = str(error)
        else:
            message = '设备协议或配对信息异常，请重新检查连接配置。'
        print(json.dumps({'ok': False, 'message': message}, ensure_ascii=False))
        sys.exit(1)


if __name__ == '__main__':
    main()
