"""Offline invariants: clipboard naming, source preservation, no overwrite, pinned transport."""
import contextlib
from datetime import datetime, timedelta
import hashlib
import inspect
import io
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

os.environ['QUADERNO_LANG'] = 'zh-Hans'  # assertions below use the source-language text
spec = importlib.util.spec_from_file_location('direct', Path(__file__).parents[1] / 'direct/quaderno_direct.py')
direct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(direct)
# Never touch the real pairing / history folder, even in tests that do not patch ROOT.
direct.ROOT = Path(tempfile.mkdtemp()) / 'Direct'
# Never write to a real serial port from tests (connect_device switches USB mode first).
direct.switch_to_network_mode = lambda wait=10: False
# Never re-enumerate the real USB device from tests; UsbLinkTests exercises the original.
REAL_RECOVER_USB_LINK = direct.recover_usb_link
direct.recover_usb_link = lambda wait=12: False


class NamingTests(unittest.TestCase):
    def test_frontmatter_title_and_body_preserved(self):
        title, result = direct.prepare_markdown('---\ntitle: 我的阅读\nauthor: 高明\n---\n\n原始正文 $PATH @mention\n')
        self.assertEqual(title, '我的阅读')
        self.assertIn('author: 高明', result)
        self.assertTrue(result.endswith('\n原始正文 $PATH @mention\n'))

    def test_second_level_heading(self):
        title, _ = direct.prepare_markdown('开场白\n\n## **Quaderno 直连方案**\n正文')
        self.assertEqual(title, 'Quaderno 直连方案')

    def test_code_heading_not_used(self):
        title, _ = direct.prepare_markdown('```sh\n# rm example\n```\n普通正文。第二句。')
        self.assertEqual(title, '普通正文')

    def test_plain_text_no_heading_required(self):
        title, _ = direct.prepare_markdown('这段内容用于解释复制投递如何命名。还有其他内容。')
        self.assertEqual(title, '这段内容用于解释复制投递如何命名')

    def test_unicode_and_illegal_characters(self):
        title, _ = direct.prepare_markdown('# 中文/测试:标题?\n正文')
        self.assertEqual(title, '中文_测试_标题')
        self.assertLessEqual(len(title), 32)

    def test_empty_metadata_title_falls_back(self):
        title, _ = direct.prepare_markdown('---\ntitle: ""\n---\n## 实际标题')
        self.assertEqual(title, '实际标题')


class TransportTests(unittest.TestCase):
    def test_pinned_tls_proxy_bypass_and_no_redirects(self):
        device = direct.Device({'address': 'Android.local', 'public_key_pin': 'sha256//expected'}, b'', '')
        def fake_run(args, **kwargs):
            self.assertEqual(args[args.index('--pinnedpubkey') + 1], 'sha256//expected')
            self.assertEqual(args[args.index('--noproxy') + 1], '*')
            self.assertNotIn('--location', args)
            Path(args[args.index('--dump-header') + 1]).write_text('HTTP/1.1 200 OK\n')
            Path(args[args.index('--output') + 1]).write_text('{}')
            return type('Result', (), {'returncode': 0, 'stdout': b'200'})()
        with patch.object(direct.subprocess, 'run', side_effect=fake_run):
            self.assertEqual(device.request('GET', '/test').status_code, 200)

    def test_collision_creates_new_document_and_verifies_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / '同名.pdf'
            source.write_bytes(b'%PDF-test-content')
            device = direct.Device({}, b'', '')
            device.authenticate = lambda: None
            # This case exercises naming only; duplicate detection has its own tests below.
            device.matches_content = lambda entry, expected: False
            device.resolve = lambda path: ({'entry_id': 'root'} if path == 'Document/Received' else
                {'entry_id': 'old'} if path.endswith('/同名.pdf') else {'entry_id': 'new'})
            calls = []
            def request(method, endpoint, **kwargs):
                calls.append((method, endpoint, kwargs))
                if method == 'POST':
                    self.assertNotEqual(kwargs['json_body']['file_name'], source.name)
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                return direct.Response(200, {}, source.read_bytes())
            device.request = request
            result = device.upload(source)
            self.assertEqual(result['sha256'], hashlib.sha256(source.read_bytes()).hexdigest())
            get_kwargs = [kw for m, ep, kw in calls if m == 'GET' and ep == '/documents/new/file']
            self.assertEqual(len(get_kwargs), 1)
            self.assertEqual(get_kwargs[0]['transfer_size'], len(b'%PDF-test-content'))
            self.assertEqual(get_kwargs[0]['verify_sha256'],
                             hashlib.sha256(b'%PDF-test-content').hexdigest())
            self.assertFalse(any(method == 'DELETE' for method, _, _ in calls))
            self.assertTrue(source.exists())

    def test_failed_readback_does_not_report_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'test.pdf'; source.write_bytes(b'%PDF-original')
            device = direct.Device({}, b'', '')
            device.authenticate = lambda: None
            device.resolve = lambda path: {'entry_id': 'root'} if path == 'Document/Received' else None
            def request(method, endpoint, **kw):
                if method == 'POST':
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                payload = b'wrong bytes'
                if kw.get('verify_sha256') and hashlib.sha256(payload).hexdigest() != kw['verify_sha256']:
                    raise direct.DirectError('文件已上传，但回读校验不一致。请保留本地 PDF 并检查设备。')
                return direct.Response(200, {}, payload)
            device.request = request
            with self.assertRaisesRegex(direct.DirectError, '回读校验不一致'):
                device.upload(source)

    def test_save_location_and_open_request_are_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / '可查找.pdf'; source.write_bytes(b'%PDF-test')
            device = direct.Device({}, b'', '')
            device.authenticate = lambda: None
            seen = []
            def resolve(path):
                seen.append(path)
                if path == 'Document/Received': return {'entry_id': 'received', 'entry_type': 'folder'}
                return {'entry_id': 'new'} if len(seen) > 2 else None
            device.resolve = resolve
            def request(method, endpoint, **kwargs):
                if endpoint == '/documents2':
                    self.assertEqual(kwargs['json_body']['parent_folder_id'], 'received')
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                if endpoint == '/viewer/controls/open2':
                    self.assertEqual(kwargs['json_body'], {'document_id': 'new', 'page': 1})
                    raise direct.DirectError('viewer unavailable')
                return direct.Response(200, {}, source.read_bytes())
            device.request = request
            result = device.upload(source)
            self.assertTrue(result['ok'])
            self.assertFalse(result['display_requested'])
            self.assertEqual(result['path'], 'Document/Received/可查找.pdf')
            self.assertIn('设备未接受打开请求', result['message'])

    def test_missing_received_folder_does_not_upload(self):
        device = direct.Device({}, b'', '')
        device.authenticate = lambda: None
        device.resolve = lambda path: None
        device.request = lambda *a, **kw: self.fail('unexpected upload')
        with self.assertRaisesRegex(direct.DirectError, 'Received 文件夹不存在'):
            device.upload(Path('document.pdf'))


class InterruptedUploadTests(unittest.TestCase):
    """A failure between creating the entry and verifying it must not leave the entry behind."""

    def device(self, source, fail, deleted, delete_fails=False, listed=True):
        device = direct.Device({'public_key_pin': 'sha256//pin'}, b'', '')
        device.authenticate = lambda: None
        uploaded = []
        device.resolve = lambda path: ({'entry_id': 'root'} if path == 'Document/Received' else
                                       {'entry_id': 'new'} if uploaded and listed else None)
        def request(method, endpoint, **kwargs):
            if method == 'PUT' and endpoint.endswith('/file') and (method, endpoint) != fail:
                uploaded.append(endpoint)
            if method == 'DELETE':
                if delete_fails:
                    raise direct.ConnectionFailure(7)
                deleted.append(endpoint)
                return direct.Response(204, {}, b'')
            if method == 'POST':
                return direct.Response(201, {}, b'{"document_id":"new"}')
            if (method, endpoint) == fail:
                raise direct.ConnectionFailure(56)
            if endpoint.endswith('/file') and method == 'GET':
                payload = b'corrupt' if fail == 'mismatch' else source.read_bytes()
                expected = kwargs.get('verify_sha256')
                if expected and hashlib.sha256(payload).hexdigest() != expected:
                    raise direct.DirectError('文件已上传，但回读校验不一致。请保留本地 PDF 并检查设备。')
                return direct.Response(200, {}, payload)
            return direct.Response(204, {}, b'')
        device.request = request
        return device

    def test_failed_transfer_or_readback_deletes_the_new_entry(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'a.pdf'; source.write_bytes(b'%PDF-a')
            for fail in (('PUT', '/documents/new/file'), ('GET', '/documents/new/file'), 'mismatch'):
                deleted = []
                with self.assertRaises(direct.DirectError):
                    self.device(source, fail, deleted).upload(source)
                self.assertEqual(deleted, ['/documents/new'], fail)
            self.assertEqual(direct.pending_orphans('sha256//pin'), [])

    def test_unreachable_cleanup_is_retried_before_the_next_upload_frees_the_name(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'a.pdf'; source.write_bytes(b'%PDF-a')
            with self.assertRaises(direct.DirectError):
                self.device(source, ('PUT', '/documents/new/file'), [], delete_fails=True).upload(source)
            self.assertEqual(direct.pending_orphans('sha256//pin'), ['new'])
            self.assertEqual(direct.pending_orphans('sha256//other-device'), [])
            deleted = []
            result = self.device(source, None, deleted).upload(source)
            self.assertEqual(deleted, ['/documents/new'])  # the orphan, removed before naming
            self.assertEqual(result['path'], 'Document/Received/a.pdf')
            self.assertEqual(direct.pending_orphans('sha256//pin'), [])

    def test_verified_content_is_kept_when_only_the_directory_check_fails(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'a.pdf'; source.write_bytes(b'%PDF-a')
            deleted = []
            with self.assertRaisesRegex(direct.DirectError, '设备目录未确认'):
                self.device(source, None, deleted, listed=False).upload(source)
            self.assertEqual(deleted, [])


class StreamingUploadTests(unittest.TestCase):
    """Upload must not hold the whole PDF, or its readback, in memory."""

    def test_file_sha256_spans_multiple_chunks(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'big.pdf'
            payload = b'%PDF-chunked' * 300000  # > 3 MiB, crosses several 1 MiB chunks
            source.write_bytes(payload)
            self.assertEqual(direct.file_sha256(source), hashlib.sha256(payload).hexdigest())

    def test_upload_never_reads_source_as_one_blob(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'a.pdf'; source.write_bytes(b'%PDF-a')
            device = direct.Device({'public_key_pin': 'sha256//pin'}, b'', '')
            device.authenticate = lambda: None
            device.resolve = lambda path: {'entry_id': 'root'} if path == 'Document/Received' else {'entry_id': 'new'}
            seen = {}
            def request(method, endpoint, **kwargs):
                if method == 'GET' and endpoint.endswith('/file'):
                    seen['verify'] = kwargs.get('verify_sha256')
                    seen['size'] = kwargs.get('transfer_size')
                    if seen['verify'] != hashlib.sha256(b'%PDF-a').hexdigest():
                        raise direct.DirectError('回读校验不一致')
                    return direct.Response(200, {}, b'')
                return direct.Response(201 if method == 'POST' else 204, {},
                                       b'{"document_id":"new"}' if method == 'POST' else b'')
            device.request = request
            original = Path.read_bytes
            read_calls = []
            def spy(path_self, *args, **kwargs):
                read_calls.append(str(path_self))
                return original(path_self, *args, **kwargs)
            with patch.object(Path, 'read_bytes', spy):
                result = device.upload(source)
            self.assertTrue(result['ok'])
            self.assertNotIn(str(source), read_calls)
            self.assertEqual(seen['size'], len(b'%PDF-a'))
            self.assertEqual(seen['verify'], hashlib.sha256(b'%PDF-a').hexdigest())

    def test_request_verifies_readback_on_disk_without_loading_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = b'%PDF-streamed' * 1000
            expected = hashlib.sha256(payload).hexdigest()
            device = direct.Device({'address': 'a', 'public_key_pin': 'sha256//p'}, b'', '')
            def fake_run(args, **kwargs):
                Path(args[args.index('--dump-header') + 1]).write_text('HTTP/1.1 200 OK\n')
                Path(args[args.index('--output') + 1]).write_bytes(payload)
                return type('Result', (), {'returncode': 0, 'stdout': b'200'})()
            with patch.object(direct.subprocess, 'run', side_effect=fake_run):
                response = device.request('GET', '/documents/new/file',
                                          transfer_size=len(payload), verify_sha256=expected)
                self.assertEqual(response.content, b'')
                with self.assertRaisesRegex(direct.DirectError, '回读校验不一致'):
                    device.request('GET', '/documents/new/file', verify_sha256='0' * 64)


class TransferTimeoutTests(unittest.TestCase):
    def test_limit_scales_with_size_and_stall_detection_is_always_on(self):
        self.assertEqual(direct.transfer_timeout(0), 120)
        self.assertEqual(direct.transfer_timeout(1), 121)
        self.assertEqual(direct.transfer_timeout(100 * 1024 * 1024), 120 + 400)
        device = direct.Device({'address': 'a', 'public_key_pin': 'sha256//p'}, b'', '')
        seen = []
        def fake_run(args, **kwargs):
            seen.append((args[args.index('--max-time') + 1], args[args.index('--speed-time') + 1], kwargs['timeout']))
            self.assertEqual(args[args.index('--speed-limit') + 1],
                             str(direct.MIN_LINK_BYTES_PER_SECOND))
            Path(args[args.index('--dump-header') + 1]).write_text('HTTP/1.1 200 OK\n')
            Path(args[args.index('--output') + 1]).write_text('{}')
            return type('Result', (), {'returncode': 0, 'stdout': b'200'})()
        with patch.object(direct.subprocess, 'run', side_effect=fake_run):
            device.request('GET', '/small')
            device.request('GET', '/big', transfer_size=100 * 1024 * 1024)
        self.assertEqual(seen, [('120', '90', 130), ('520', '90', 530)])
        self.assertGreater(direct.MIN_LINK_BYTES_PER_SECOND, 1)
        self.assertLess(direct.MIN_LINK_BYTES_PER_SECOND, direct.MIN_TRANSFER_BYTES_PER_SECOND)


class DiscoveryTests(unittest.TestCase):
    def test_hostname_collision_prefers_fujitsu_interface(self):
        addresses = """10:00:00 Add 40000003 11 Android.local. FE80::1234%en0 120
10:00:00 Add 40000003 11 Android.local. 192.168.31.40 120
10:00:00 Add 40000003 28 Android.local. FE80::845B:CEFF:FEFC:6A91%en5 120
10:00:00 Add 40000002 28 Android.local. 0.0.0.0 1 No Such Record
"""
        services = "10:00:00 Add 2 28 local. _dp_fujitsu._tcp. Digital Paper FMVDP51"
        found = direct.parse_endpoints(addresses, services)
        self.assertEqual(found[0], '[fe80::845b:ceff:fefc:6a91%en5]')
        self.assertNotIn('0.0.0.0', found)
        self.assertEqual(len(found), 3)

    def test_rejected_pin_falls_through_before_authentication(self):
        key = direct.RSA.generate(1024).export_key()
        device = direct.Device({'address': 'Android.local'}, key, 'test-client')
        events = []
        def request(method, endpoint, **kwargs):
            events.append((device.target, method, endpoint))
            if device.target == 'wrong' and endpoint.startswith('/auth/nonce'):
                raise direct.ConnectionFailure(90)
            if endpoint.startswith('/auth/nonce'):
                return direct.Response(200, {}, b'{"nonce":"test-nonce"}')
            return direct.Response(204, {'set-cookie': 'Credentials=test123; Path=/'}, b'')
        device.request = request
        with patch.object(direct, 'discover_endpoints', return_value=['wrong', 'paired']):
            device.authenticate()
        self.assertEqual(device.target, 'paired')
        self.assertFalse(any(target == 'wrong' and method != 'GET' for target, method, _ in events))

    def test_numeric_address_does_not_require_mdns(self):
        with patch.object(direct, 'dns_sd_output', side_effect=AssertionError('unexpected discovery')):
            self.assertEqual(direct.discover_endpoints('192.168.1.2'), ['192.168.1.2'])
            self.assertEqual(direct.discover_endpoints('[fe80::1234%en5]'), ['[fe80::1234%en5]'])

    def test_removed_and_invalid_dns_records_are_ignored(self):
        output = """10:00:00 Rmv 2 28 Android.local. FE80::1234%en5 120
10:00:00 Add 2 28 Android.local. invalid 120
10:00:00 Add 2 28 Android.local. :: 120
"""
        self.assertEqual(direct.parse_endpoints(output, ''), [])

    def test_usb_dropout_fails_fast_without_probing_lan_namesake(self):
        lan = "10:00:00 Add 40000003 11 Android.local. 192.168.31.40 120"
        browse_header = "Browsing for _dp_fujitsu._tcp.local.\n"
        def dns_sd(arguments, duration=0.8):
            return lan if arguments[0] == '-G' else browse_header
        with patch.object(direct, 'dns_sd_output', side_effect=dns_sd), \
             patch.object(direct, 'quaderno_on_usb', return_value=False):
            with self.assertRaises(direct.UsbDisconnected):
                direct.discover_endpoints('Android.local')

    def test_wifi_advertisement_or_unreadable_bus_is_not_blocked(self):
        lan = "10:00:00 Add 40000003 11 Android.local. 192.168.31.40 120"
        services = "10:00:00 Add 2 11 local. _dp_fujitsu._tcp. Digital Paper FMVDP51"
        for service_output, on_usb in ((services, False), ('', None)):
            def dns_sd(arguments, duration=0.8):
                return lan if arguments[0] == '-G' else service_output
            with patch.object(direct, 'dns_sd_output', side_effect=dns_sd), \
                 patch.object(direct, 'quaderno_on_usb', return_value=on_usb), \
                 patch.object(direct, 'usb_link_stuck_now', return_value=False), \
                 patch.object(direct, 'usb_link_idle_now', return_value=False):
                self.assertEqual(direct.discover_endpoints('Android.local'), ['192.168.31.40'])

    def test_stuck_usb_link_fails_fast_with_its_own_message(self):
        lan = "10:00:00 Add 40000003 11 Android.local. 192.168.31.40 120"
        def dns_sd(arguments, duration=0.8):
            return lan if arguments[0] == '-G' else ''
        with patch.object(direct, 'dns_sd_output', side_effect=dns_sd), \
             patch.object(direct, 'quaderno_on_usb', return_value=True), \
             patch.object(direct, 'usb_link_stuck_now', return_value=True), \
             patch.object(direct, 'usb_link_idle_now', return_value=False):
            with self.assertRaises(direct.UsbLinkDown):
                direct.discover_endpoints('Android.local')

    def test_idle_usb_link_without_any_address_reports_link_failure(self):
        def dns_sd(arguments, duration=0.8):
            return ''
        with patch.object(direct, 'dns_sd_output', side_effect=dns_sd), \
             patch.object(direct, 'quaderno_on_usb', return_value=True), \
             patch.object(direct, 'usb_link_stuck_now', return_value=False), \
             patch.object(direct, 'usb_link_idle_now', return_value=True):
            with self.assertRaises(direct.UsbLinkDown):
                direct.discover_endpoints('Android.local')

    def test_ioreg_detection_requires_fujitsu_vendor_and_model(self):
        quaderno = '+-o FMVDP51@00100000  <class IOUSBHostDevice>\n  {\n    "USB Product Name" = "FMVDP51"\n    "idVendor" = 1221\n  }\n'
        other = '+-o Keyboard@00200000  <class IOUSBHostDevice>\n  {\n    "USB Product Name" = "FMVDP-like"\n    "idVendor" = 1452\n  }\n'
        self.assertTrue(direct.quaderno_in_ioreg(other + quaderno))
        self.assertFalse(direct.quaderno_in_ioreg(other))
        self.assertFalse(direct.quaderno_in_ioreg(''))


class TransactionTests(unittest.TestCase):
    def test_concurrent_transactions_are_blocked_then_released(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp)):
            with direct.connection_lock(timeout=0):
                with self.assertRaisesRegex(direct.DirectError, '另一项设备投递'):
                    with direct.connection_lock(timeout=0):
                        self.fail('concurrent lock acquired')
            with direct.connection_lock(timeout=0):
                pass


class SpeedSafetyTests(unittest.TestCase):
    def test_non_chinese_latin_scripts_keep_complete_font_fallback(self):
        self.assertTrue(direct.can_use_restricted_fonts('中文 English α2 + Δnet'))
        for text in ['日本語かな', '한글', 'emoji 😀', 'עברית', 'العربية']:
            self.assertFalse(direct.can_use_restricted_fonts(text))

    def test_cache_does_not_skip_pinning_or_fresh_authentication(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp)):
            key = direct.RSA.generate(1024).export_key()
            settings = {'address': 'Android.local', 'public_key_pin': 'expected-pin'}
            device = direct.Device(settings, key, 'client')
            direct.save_private(Path(temp) / 'endpoint-cache.json', direct.json.dumps({
                **settings, 'target': '[fe80::1234%en5]'}).encode())
            calls = []
            def request(method, endpoint, **kwargs):
                calls.append((method, endpoint))
                if endpoint.startswith('/auth/nonce'):
                    return direct.Response(200, {}, b'{"nonce":"fresh-nonce"}')
                return direct.Response(204, {'set-cookie': 'Credentials=newcookie; Path=/'}, b'')
            device.request = request
            with patch.object(direct, 'discover_endpoints', side_effect=AssertionError('unnecessary scan')):
                device.authenticate()
            self.assertEqual(calls[1], ('PUT', '/auth'))
            self.assertEqual(device.settings['public_key_pin'], 'expected-pin')

    def test_stale_cached_usb_address_falls_back_to_discovery(self):
        device = direct.Device({'address': 'Android.local'}, direct.RSA.generate(1024).export_key(), 'client')
        device.cached_endpoint = lambda: 'stale'
        def request(method, endpoint, **kwargs):
            if device.target == 'stale': raise direct.ConnectionFailure(7)
            if endpoint.startswith('/auth/nonce'): return direct.Response(200, {}, b'{"nonce":"fresh"}')
            return direct.Response(204, {'set-cookie': 'Credentials=newcookie'}, b'')
        device.request = request
        with patch.object(direct, 'discover_endpoints', return_value=['new-usb']): device.authenticate()
        self.assertEqual(device.target, 'new-usb')

    def test_cache_is_bound_to_configured_device_pin(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp)):
            direct.save_private(Path(temp) / 'endpoint-cache.json', direct.json.dumps({
                'address': 'Android.local', 'public_key_pin': 'old-pin', 'target': '[fe80::1234%en5]'}).encode())
            device = direct.Device({'address': 'Android.local', 'public_key_pin': 'new-pin'}, b'', '')
            self.assertIsNone(device.cached_endpoint())

    def test_open_is_requested_after_upload_before_full_readback(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'speed.pdf'; source.write_bytes(b'%PDF-test')
            device = direct.Device({}, b'', ''); device.cookie = 'authenticated'
            sequence = []
            device.resolve = lambda path: ({'entry_id': 'received'} if path == 'Document/Received' else
                {'entry_id': 'new'} if 'GET-file' in sequence else None)
            def request(method, endpoint, **kw):
                if endpoint == '/documents2': return direct.Response(201, {}, b'{"document_id":"new"}')
                sequence.append('open' if endpoint.endswith('open2') else method + '-file')
                return direct.Response(200, {}, source.read_bytes())
            device.request = request
            self.assertTrue(device.upload(source)['ok'])
            self.assertEqual(sequence, ['PUT-file', 'open', 'GET-file'])

    def test_render_pipeline_preserves_pdf_if_upload_fails(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'config'):
            directory = Path(temp); input_file = directory / 'input.md'; input_file.write_text('有意义的正文。')
            args = SimpleNamespace(directory=temp, input=str(input_file), pandoc='pandoc', typst='typst',
                format='markdown', template='template', font=[], page_width='157mm', page_height='209mm',
                margin='14mm', size='10pt', leading='0.85em', font_directory=None)
            class FakeDevice:
                def authenticate(self): pass
                def upload(self, source): raise direct.DirectError('test network failure')
            def render(command, **kw):
                Path(command[command.index('-o') + 1]).write_bytes(b'%PDF-preserved')
                return SimpleNamespace(returncode=0, stderr=b'')
            with patch.object(direct, 'load_device', return_value=FakeDevice()), patch.object(direct.subprocess, 'run', side_effect=render):
                with self.assertRaisesRegex(direct.DirectError, 'PDF 已保留'):
                    direct.render_and_upload(args)
            self.assertEqual(next(directory.glob('*.pdf')).read_bytes(), b'%PDF-preserved')

    def test_finder_file_keeps_its_own_name(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'config'):
            directory = Path(temp); input_file = directory / 'notes.md'; input_file.write_text('# 别的标题\n正文')
            args = SimpleNamespace(directory=temp, input=str(input_file), pandoc='pandoc', typst='typst',
                format='markdown', template='template', font=[], page_width='157mm', page_height='209mm',
                margin='14mm', size='10pt', leading='0.85em', font_directory=None, title='读书笔记: 第一章')
            uploaded = []
            class FakeDevice:
                def authenticate(self): pass
                def upload(self, source): uploaded.append(source.name); return {'ok': True}
            def render(command, **kw):
                Path(command[command.index('-o') + 1]).write_bytes(b'%PDF')
                return SimpleNamespace(returncode=0, stderr=b'')
            with patch.object(direct, 'load_device', return_value=FakeDevice()), patch.object(direct.subprocess, 'run', side_effect=render):
                direct.render_and_upload(args)
            self.assertEqual(uploaded, ['读书笔记_ 第一章.pdf'])


class ClipboardLayoutTests(unittest.TestCase):
    def profile(self, size):
        return dict(cjkFont='Songti SC', latinFont='Times New Roman', bodySize=size,
                    margin='12mm', leading='0.7em', pageW='157.1mm', pageH='209.5mm',
                    docLang='zh', printTime=True, fontFiles=[])

    def test_shared_then_independent_without_changing_shared_settings(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            path = Path(temp) / 'clipboard-layout.json'
            saved = {'useShared': True, 'shared': self.profile('10.5pt'), 'independent': self.profile('14pt')}
            path.write_text(direct.json.dumps(saved))
            self.assertEqual(direct.load_clipboard_layout()[0]['bodySize'], '10.5pt')
            saved['useShared'] = False; path.write_text(direct.json.dumps(saved))
            actual, mode = direct.load_clipboard_layout()
            self.assertEqual((actual['bodySize'], mode), ('14pt', 'independent'))
            self.assertEqual(direct.json.loads(path.read_text())['shared']['bodySize'], '10.5pt')

    def test_current_shared_changes_are_read_on_each_invocation(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            path = Path(temp) / 'clipboard-layout.json'
            for size in ['10pt', '13pt']:
                path.write_text(direct.json.dumps({'useShared': True, 'shared': self.profile(size)}))
                self.assertEqual(direct.load_clipboard_layout()[0]['bodySize'], size)

    def test_invalid_saved_units_do_not_silently_change_layout(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            profile = self.profile('wrong-unit')
            (Path(temp) / 'clipboard-layout.json').write_text(direct.json.dumps({'shared': profile}))
            with self.assertRaisesRegex(direct.DirectError, '排版配置无效'):
                direct.load_clipboard_layout()

    def test_formula_keeps_system_font_fallback(self):
        self.assertFalse(direct.can_use_restricted_fonts(r'数学：$\alpha + \beta$'))
        self.assertFalse(direct.can_use_restricted_fonts(r'\[\text{中文公式}\]'))





class MessageLanguageTests(unittest.TestCase):
    def tearDown(self):
        direct.language.cache_clear()

    def message_in(self, language, text, **values):
        direct.language.cache_clear()
        with patch.dict(os.environ, {'QUADERNO_LANG': language}):
            return direct.tr(text, **values)

    def test_app_language_selects_translation(self):
        text = '已保存至 {folder}：{name}（回读通过，已请求设备打开）'
        self.assertEqual(self.message_in('en', text, name='a.pdf', folder='Received'),
                         'Saved to Received: a.pdf (verified; asked the device to open it)')
        self.assertTrue(self.message_in('ja', text, name='a.pdf', folder='Received').startswith('Received に保存しました：a.pdf'))
        self.assertTrue(self.message_in('zh-Hans', text, name='a.pdf', folder='Received').startswith('已保存至 Received：a.pdf'))

    def test_unsupported_language_falls_back_to_english(self):
        self.assertEqual(self.message_in('de-DE', '未选择文件'), 'No files selected')

    def test_every_template_keeps_its_placeholders(self):
        import string
        fields = lambda text: {name for _, name, _, _ in string.Formatter().parse(text) if name}
        for source, translations in direct.MESSAGES.items():
            for translated in translations:
                self.assertEqual(fields(translated), fields(source), source)

    def test_hotkey_follows_language_chosen_in_app(self):
        from types import SimpleNamespace
        def defaults(command, **kwargs):
            if command[2].endswith('Library/Preferences/' + direct.APP_BUNDLE_ID) and command[3] == 'AppLanguage':
                return SimpleNamespace(returncode=0, stdout='ja\n')
            return SimpleNamespace(returncode=0, stdout='(\n    "zh-Hans-CN"\n)\n')
        direct.language.cache_clear()
        with patch.dict(os.environ, {}, clear=False), patch.object(direct.subprocess, 'run', side_effect=defaults):
            os.environ.pop('QUADERNO_LANG', None)
            self.assertEqual(direct.language(), 'ja')
        os.environ['QUADERNO_LANG'] = 'zh-Hans'
        direct.language.cache_clear()


class HistoryTests(unittest.TestCase):
    def test_history_keeps_latest_entries_with_source(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'), \
             patch.object(direct, 'HISTORY_LIMIT', 3), patch.dict(os.environ, {'QUADERNO_SOURCE': 'finder'}):
            for index in range(5):
                direct.record_delivery(f'{index}.pdf', True)
            import json
            entries = [json.loads(line) for line in (Path(temp) / 'Direct/history.jsonl').read_text().splitlines()]
            self.assertEqual([entry['name'] for entry in entries], ['2.pdf', '3.pdf', '4.pdf'])
            self.assertEqual({entry['source'] for entry in entries}, {'finder'})



class OfficialFallbackTests(unittest.TestCase):
    def render_args(self, temp):
        from types import SimpleNamespace
        input_file = Path(temp) / 'input.md'
        input_file.write_text('# 降级测试\n正文')
        return SimpleNamespace(directory=temp, input=str(input_file), pandoc='pandoc', typst='typst',
            format='markdown', template='template', font=[], page_width='157mm', page_height='209mm',
            margin='14mm', size='10pt', leading='0.85em', font_directory=None, title='降级测试')

    def fake_render(self, command, **kwargs):
        from types import SimpleNamespace
        Path(command[command.index('-o') + 1]).write_bytes(b'%PDF-fallback')
        return SimpleNamespace(returncode=0, stderr=b'')

    def test_unreachable_device_hands_pdf_to_running_official_app(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            handed = []
            unreachable = direct.DeviceUnreachable('USB 上未检测到 QUADERNO')
            with patch.object(direct, 'connect_device', side_effect=unreachable), \
                 patch.object(direct, 'official_app_running', return_value=True), \
                 patch.object(direct, 'hand_off', side_effect=lambda pdf: handed.append(pdf.name) or {'ok': True, 'fallback': True}), \
                 patch.object(direct.subprocess, 'run', side_effect=self.fake_render):
                result = direct.render_and_upload(self.render_args(temp))
            self.assertTrue(result['fallback'])
            self.assertEqual(handed, ['降级测试.pdf'])

    def test_failure_after_upload_started_never_falls_back(self):
        class FailingDevice:
            def upload(self, source):
                raise direct.DirectError('文件已上传，但回读校验不一致。')
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            with patch.object(direct, 'connect_device', return_value=FailingDevice()), \
                 patch.object(direct, 'official_app_running', return_value=True), \
                 patch.object(direct, 'hand_off', side_effect=AssertionError('duplicate delivery')), \
                 patch.object(direct.subprocess, 'run', side_effect=self.fake_render):
                with self.assertRaisesRegex(direct.DirectError, '回读校验不一致'):
                    direct.render_and_upload(self.render_args(temp))

    def test_closed_official_app_is_suggested_not_launched(self):
        error = direct.DeviceUnreachable('USB 上未检测到 QUADERNO')
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(direct, 'OFFICIAL_APP', Path(temp)), \
             patch.object(direct, 'official_app_running', return_value=False), \
             patch.object(direct, 'hand_off', side_effect=AssertionError('must not launch')):
            with self.assertRaisesRegex(direct.DirectError, '打开 QUADERNO PC App 后重试'):
                direct.hand_off_or_raise(Path(temp) / 'a.pdf', error)

    def hand_off_with(self, behaviour):
        """Run hand_off against a fake official client; behaviour(copy, log) acts like the client."""
        import json
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            log = Path(temp) / 'logfile.log'
            log.write_text('start\n')
            pdf = Path(temp) / '原件.pdf'
            pdf.write_bytes(b'%PDF')
            def run(command, **kwargs):
                from types import SimpleNamespace
                behaviour(Path(command[-1]), log)
                return SimpleNamespace(returncode=0)
            with patch.object(direct, 'official_log', return_value=log), patch.object(direct.subprocess, 'run', side_effect=run):
                try:
                    return direct.hand_off(pdf, timeout=1), pdf.exists(), (Path(temp) / 'Direct/history.jsonl')
                except direct.DirectError as error:
                    return error, pdf.exists(), None

    def test_consumed_copy_counts_as_delivered_and_is_recorded(self):
        import json
        result, original_kept, history = self.hand_off_with(lambda copy, log: copy.unlink())
        self.assertTrue(result['ok'])
        self.assertTrue(original_kept)

    def test_client_log_error_is_a_failure(self):
        result, original_kept, _ = self.hand_off_with(
            lambda copy, log: log.write_text('start\nE_MW_DEVICE_NOT_FOUND\n'))
        self.assertIsInstance(result, direct.DirectError)
        self.assertIn('也失败', str(result))
        self.assertTrue(original_kept)


class FileManagementTests(unittest.TestCase):
    def device(self, responses=None):
        key = direct.RSA.generate(1024).export_key()
        device = direct.Device({'address': 'Android.local'}, key, 'test-client')
        calls = []
        def request(method, endpoint, json_body=None, **kwargs):
            calls.append((method, endpoint, json_body))
            if endpoint.startswith('/resolve/'):
                return {'entry_id': 'root', 'entry_type': 'folder', 'entry_path': 'Document'}
            payload = (responses or {}).get(endpoint, b'{}')
            # download() now asks curl to stream straight to disk; emulate that contract.
            if kwargs.get('output_path') is not None:
                Path(kwargs['output_path']).write_bytes(payload)
                return direct.Response(200, {}, b'')
            return direct.Response(200, {}, payload)
        device.request = request
        device.resolve = lambda path: request('GET', '/resolve/' + path)
        return device, calls

    def test_browse_lists_folders_first(self):
        import json
        listing = json.dumps({'entry_list': [
            {'entry_id': 'd1', 'entry_name': 'b.pdf', 'entry_type': 'document', 'file_size': 10},
            {'entry_id': 'f1', 'entry_name': 'Received', 'entry_type': 'folder'},
            {'entry_id': 'd2', 'entry_name': 'A.pdf', 'entry_type': 'document'}]}).encode()
        device, _ = self.device({'/folders/root/entries2': listing})
        result = device.browse('Document')
        self.assertEqual([e['name'] for e in result['entries']], ['Received', 'A.pdf', 'b.pdf'])
        self.assertEqual(result['folder']['id'], 'root')

    def test_each_action_uses_the_documented_endpoint(self):
        device, calls = self.device({'/documents/d1/file': b'%PDF'})
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'out.pdf'
            device.download('d1', str(target))
            self.assertEqual(target.read_bytes(), b'%PDF')
        device.open_document('d1', 'a.pdf')
        device.delete('d1', 'document', 'a.pdf')
        device.delete('f1', 'folder', 'Old')
        device.make_folder('root', '  Reading ')
        device.move('d1', 'f2', 'a.pdf')
        self.assertEqual(calls, [
            ('GET', '/documents/d1/file', None),
            ('PUT', '/viewer/controls/open2', {'document_id': 'd1', 'page': 1}),
            ('DELETE', '/documents/d1', None),
            ('DELETE', '/folders/f1', None),
            ('POST', '/folders2', {'folder_name': 'Reading', 'parent_folder_id': 'root'}),
            ('PUT', '/documents/d1', {'parent_folder_id': 'f2'})])

    def test_ids_and_names_are_validated_before_any_request(self):
        device, calls = self.device()
        for action in (lambda: device.delete('../folders/x', 'document', 'x'),
                       lambda: device.move('d1', 'f/2', 'x'),
                       lambda: device.make_folder('root', 'a/b'),
                       lambda: device.make_folder('root', '   '),
                       lambda: device.download('d1', 'relative.pdf')):
            with self.assertRaises(direct.DirectError):
                action()
        self.assertEqual(calls, [])


class HistoryDetailTests(unittest.TestCase):
    def entries(self, root):
        import json
        path = root / 'history.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_failed_render_upload_is_recorded_with_kept_pdf(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            input_file = Path(temp) / 'input.md'; input_file.write_text('# 失败记录\n正文')
            args = SimpleNamespace(directory=temp, input=str(input_file), pandoc='pandoc', typst='typst',
                format='markdown', template='template', font=[], page_width='157mm', page_height='209mm',
                margin='14mm', size='10pt', leading='0.85em', font_directory=None, title='失败记录')
            class Broken:
                def upload(self, source): raise direct.DirectError('回读校验不一致')
            def render(command, **kw):
                Path(command[command.index('-o') + 1]).write_bytes(b'%PDF')
                return SimpleNamespace(returncode=0, stderr=b'')
            with patch.object(direct, 'connect_device', return_value=Broken()), \
                 patch.object(direct.subprocess, 'run', side_effect=render):
                with self.assertRaises(direct.DirectError):
                    direct.render_and_upload(args)
            [entry] = self.entries(Path(temp) / 'Direct')
            self.assertEqual((entry['status'], entry['name'], entry['message']), ('failed', '失败记录.pdf', '回读校验不一致'))
            self.assertTrue(Path(entry['kept']).exists())

    def test_upload_into_chosen_folder_records_document_id(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp) / 'Direct'):
            source = Path(temp) / 'a.pdf'; source.write_bytes(b'%PDF-a')
            key = direct.RSA.generate(1024).export_key()
            device = direct.Device({'address': 'Android.local'}, key, 'c'); device.cookie = 'x'
            resolved = []
            def resolve(path):
                resolved.append(path)
                if path == 'Document/Reading': return {'entry_id': 'f9', 'entry_type': 'folder'}
                if path == 'Document/Reading/a.pdf' and len(resolved) > 2: return {'entry_id': 'new'}
                return None
            device.resolve = resolve
            def request(method, endpoint, **kw):
                if endpoint == '/documents2':
                    self.assertEqual(kw['json_body']['parent_folder_id'], 'f9')
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                return direct.Response(200, {}, source.read_bytes())
            device.request = request
            device.upload(source, 'Document/Reading')
            [entry] = self.entries(Path(temp) / 'Direct')
            self.assertEqual((entry['status'], entry['document_id'], entry['remote']), ('ok', 'new', 'Document/Reading/a.pdf'))


class SerialModeTests(unittest.TestCase):
    def test_finds_the_quaderno_serial_port_only_in_serial_mode(self):
        serial = ('+-o FMVDP51@00100000  <class IOUSBHostDevice>\n  "idProduct" = 5718\n  "USB Product Name" = "FMVDP51"\n'
                  '  "idVendor" = 1221\n  | +-o IOSerialBSDClient\n  |     "IOCalloutDevice" = "/dev/cu.usbmodem101"\n')
        network = serial.replace('5718', '5719').replace('"IOCalloutDevice" = "/dev/cu.usbmodem101"', '')
        other = '+-o Modem@00200000\n  "idProduct" = 5718\n  "idVendor" = 1452\n  "IOCalloutDevice" = "/dev/cu.usbmodem9"\n'
        self.assertEqual(direct.serial_mode_port(other + serial), '/dev/cu.usbmodem101')
        self.assertIsNone(direct.serial_mode_port(network))
        self.assertIsNone(direct.serial_mode_port(other))
        self.assertEqual(direct.CDC_ECM_SWITCH, bytes([1, 0, 0, 1, 0, 0, 0, 1, 1, 4]))


class UsbRecoveryFaultTests(unittest.TestCase):
    def test_serial_switch_handles_partial_write_and_temporary_busy(self):
        received = bytearray()
        counts = iter([BlockingIOError(), 3, InterruptedError(), 7])
        def write(fd, data):
            result = next(counts)
            if isinstance(result, Exception):
                raise result
            received.extend(data[:result])
            return result
        with patch.object(direct.os, 'write', side_effect=write), \
             patch.object(direct.fcntl, 'ioctl'), patch.object(direct.time, 'sleep'):
            direct.write_serial_switch(99)
        self.assertEqual(bytes(received), direct.CDC_ECM_SWITCH)

    def test_serial_switch_has_deadline_for_stalled_write_and_drain(self):
        for stalled_write in (True, False):
            clock = iter([0, 0, 0, 1, 3, 4])
            def ioctl(fd, command, queued, mutate):
                queued[0] = 10
            with self.subTest(stalled_write=stalled_write), \
                 patch.object(direct.os, 'write', side_effect=BlockingIOError() if stalled_write else None,
                              return_value=10), \
                 patch.object(direct.fcntl, 'ioctl', side_effect=ioctl), \
                 patch.object(direct.time, 'monotonic', side_effect=lambda: next(clock)), \
                 patch.object(direct.time, 'sleep'):
                with self.assertRaises(TimeoutError):
                    direct.write_serial_switch(99)

    def test_serial_switch_against_real_pseudoterminal(self):
        import pty
        master, slave = pty.openpty()
        try:
            attributes = direct.termios.tcgetattr(slave)
            attributes[0] = attributes[1] = attributes[3] = 0
            direct.termios.tcsetattr(slave, direct.termios.TCSANOW, attributes)
            import select
            received = []
            def read_peer():
                if select.select([master], [], [], 3)[0]:
                    received.append(os.read(master, 10))
            reader = threading.Thread(target=read_peer)
            reader.start()
            try:
                direct.write_serial_switch(slave)
            finally:
                reader.join(timeout=4)
            self.assertEqual(received, [direct.CDC_ECM_SWITCH])
        finally:
            os.close(master)
            os.close(slave)

    def test_background_preparation_does_not_authenticate_or_claim_ready(self):
        output = io.StringIO()
        with patch.object(sys, 'argv', ['helper', 'usb-prepare']), \
             patch.object(direct, 'connection_lock', return_value=contextlib.nullcontext()) as lock, \
             patch.object(direct, 'prepare_usb', return_value={}) as prepare, \
             patch.object(direct, 'ioreg_devices', return_value=''), \
             patch.object(direct, 'load_device', side_effect=AssertionError('background authentication')), \
             contextlib.redirect_stdout(output):
            direct.main()
        lock.assert_called_once_with(timeout=0)
        prepare.assert_called_once_with()
        result = json.loads(output.getvalue())
        self.assertFalse(result['usb_present'])
        self.assertNotIn('ready', result)

    def test_background_recovery_skips_busy_cross_process_lock(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(direct, 'ROOT', Path(temp)):
            with direct.connection_lock():
                started = time.monotonic()
                with self.assertRaises(direct.DirectError):
                    with direct.connection_lock(timeout=0):
                        self.fail('concurrent recovery acquired delivery lock')
                self.assertLess(time.monotonic() - started, .5)


class UsbLinkTests(unittest.TestCase):
    NETWORK = ('+-o FMVDP51@00100000  <class IOUSBHostDevice>\n  "idProduct" = 5719\n  "USB Product Name" = "FMVDP51"\n'
               '  "idVendor" = 1221\n  +-o CDC Ethernet Control Model (ECM)@0\n  | +-o AppleUserECM\n'
               '  |   | |   "IOLinkStatus" = {status}\n  |   |   |   "BSD Name" = "en5"\n')

    def test_link_down_only_for_a_network_mode_quaderno_reporting_inactive(self):
        other = '+-o Dock@00200000\n  "idProduct" = 5719\n  "idVendor" = 1452\n  "IOLinkStatus" = 1\n'
        self.assertTrue(direct.usb_link_down(other + self.NETWORK.format(status=1)))
        self.assertFalse(direct.usb_link_down(self.NETWORK.format(status=3)))
        self.assertFalse(direct.usb_link_down(self.NETWORK.format(status=0)))  # status not valid: do not act
        self.assertFalse(direct.usb_link_down(self.NETWORK.replace('  |   | |   "IOLinkStatus" = {status}\n', '')))
        self.assertFalse(direct.usb_link_down(self.NETWORK.format(status=1).replace('5719', '5718')))
        self.assertFalse(direct.usb_link_down(other))

    def test_idle_link_is_detected_separately_from_a_stuck_link(self):
        self.assertTrue(direct.usb_link_idle(self.NETWORK.format(status=0)))
        self.assertFalse(direct.usb_link_idle(self.NETWORK.format(status=1)))
        self.assertFalse(direct.usb_link_idle(self.NETWORK.format(status=3)))
        self.assertFalse(direct.usb_link_idle(self.NETWORK.replace(
            '  |   | |   "IOLinkStatus" = {status}\n', '')))
        self.assertFalse(direct.usb_link_idle('+-o Dock\n  "idVendor" = 1452\n  "IOLinkStatus" = 0\n'))

    def test_recovery_reenumerates_only_a_stuck_link_and_stops_once_advertised(self):
        advertised = "10:00:00 Add 2 5 local. _dp_fujitsu._tcp. Digital Paper FMVDP51"
        with patch.object(direct, 'usb_link_stuck_now', return_value=False), \
             patch.object(direct, 'usb_link_idle_now', return_value=False), \
             patch.object(direct, 'reenumerate_quaderno', side_effect=AssertionError('healthy link replugged')):
            self.assertFalse(REAL_RECOVER_USB_LINK())
        with patch.object(direct, 'usb_link_stuck_now', return_value=True), \
             patch.object(direct, 'usb_link_idle_now', return_value=False), \
             patch.object(direct, 'reenumerate_quaderno', return_value=True) as reenumerate, \
             patch.object(direct, 'switch_to_network_mode', return_value=False), \
             patch.object(direct, 'dns_sd_output', return_value=advertised) as browse, \
             patch.object(direct.time, 'sleep'):
            self.assertTrue(REAL_RECOVER_USB_LINK())
        reenumerate.assert_called_once_with()
        self.assertEqual(browse.call_count, 1)
        with patch.object(direct, 'usb_link_stuck_now', return_value=True), \
             patch.object(direct, 'usb_link_idle_now', return_value=False), \
             patch.object(direct, 'reenumerate_quaderno', side_effect=OSError('IOKit unavailable')):
            self.assertFalse(REAL_RECOVER_USB_LINK())

    def test_idle_link_replugs_only_after_the_link_fails_to_come_up(self):
        advertised = "10:00:00 Add 2 5 local. _dp_fujitsu._tcp. Digital Paper FMVDP51"
        with patch.object(direct, 'usb_link_stuck_now', return_value=False), \
             patch.object(direct, 'usb_link_idle_now', return_value=True), \
             patch.object(direct, 'dns_sd_output', return_value=advertised), \
             patch.object(direct, 'reenumerate_quaderno', side_effect=AssertionError('normal plug-in replugged')), \
             patch.object(direct.time, 'sleep'):
            self.assertFalse(REAL_RECOVER_USB_LINK())
        with patch.object(direct, 'usb_link_stuck_now', return_value=False), \
             patch.object(direct, 'usb_link_idle_now', return_value=True), \
             patch.object(direct, 'dns_sd_output', return_value=''), \
             patch.object(direct, 'reenumerate_quaderno', return_value=True) as reenumerate, \
             patch.object(direct, 'switch_to_network_mode', return_value=False), \
             patch.object(direct.time, 'sleep'):
            self.assertTrue(REAL_RECOVER_USB_LINK(wait=0))
        reenumerate.assert_called_once_with()

    def test_idle_snapshot_cannot_reset_a_link_that_recovers_during_observation(self):
        with patch.object(direct, 'usb_link_stuck_now', return_value=False), \
             patch.object(direct, 'usb_link_idle_now', side_effect=[True, False]), \
             patch.object(direct, 'dns_sd_output', return_value=''), \
             patch.object(direct.time, 'sleep'), \
             patch.object(direct, 'reenumerate_quaderno', side_effect=AssertionError('recovered link reset')):
            self.assertFalse(REAL_RECOVER_USB_LINK(wait=0))

    def test_connecting_switches_and_recovers_before_authenticating(self):
        order = []
        device = Mock()
        device.authenticate.side_effect = lambda: order.append('auth')
        with patch.object(direct, 'switch_to_network_mode', side_effect=lambda: order.append('switch')), \
             patch.object(direct, 'recover_usb_link', side_effect=lambda: order.append('recover')), \
             patch.object(direct, 'load_device', return_value=device):
            self.assertIs(direct.connect_device(), device)
        self.assertEqual(order, ['switch', 'recover', 'auth'])


class ScreenshotTests(unittest.TestCase):
    def test_png_screenshot_is_saved_with_a_unique_dated_name(self):
        key = direct.RSA.generate(1024).export_key()
        device = direct.Device({'address': 'Android.local'}, key, 'c')
        calls = []
        device.request = lambda method, endpoint, **kw: calls.append(endpoint) or direct.Response(200, {}, b'\x89PNG-data')
        with tempfile.TemporaryDirectory() as temp:
            first = device.screenshot(temp, 'png')
            second = device.screenshot(temp, 'png')
            self.assertEqual(calls, ['/system/controls/screen_shot', '/viewer/status/current_viewing'] * 2)
            self.assertNotEqual(first['path'], second['path'])  # same second: a numbered name, no overwrite
            self.assertEqual(Path(first['path']).read_bytes(), b'\x89PNG-data')
            self.assertTrue(Path(first['path']).name.startswith('QUADERNO 截屏 '))

    def test_name_comes_from_the_open_document_and_a_copy_goes_to_the_desktop(self):
        key = direct.RSA.generate(1024).export_key()
        device = direct.Device({'address': 'Android.local'}, key, 'c')
        # Shape taken from a real FMVDP51 response (2026-11-02).
        viewing = {'orientation': 'portlait', 'view_mode': 'single', 'views': [{
            'current_page': '3', 'entry_id': 'e1', 'entry_path': 'Document/Received/读书笔记_20261102-114850.pdf',
            'title': '读书笔记_20261102-114850', 'total_page': '9'}]}
        device.request = lambda method, endpoint, **kw: direct.Response(
            200, {}, json.dumps(viewing).encode() if 'viewer' in endpoint else b'\x89PNG-data')
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as desktop:
            result = device.screenshot(folder, 'png', desktop)
            self.assertTrue(Path(result['path']).name.startswith('读书笔记 第3页 '))
            self.assertEqual(Path(result['desktop_path']).parent, Path(desktop))
            self.assertEqual(Path(result['desktop_path']).read_bytes(), b'\x89PNG-data')
            # Saving into the Desktop itself makes no second copy.
            self.assertNotIn('desktop_path', device.screenshot(desktop, 'png', desktop))

    def test_home_screen_falls_back_to_the_generic_name(self):
        self.assertIsNone(direct.viewing_label({'views': []}))
        self.assertEqual(direct.viewing_label({'views': [{'title': 'a/b:c', 'entry_id': 'x', 'current_page': '2'},
                                                        {'entry_id': 'x', 'current_page': '3'}]}), 'a_b_c 第2–3页')

    def test_settings_fall_back_to_pictures_and_png(self):
        with patch.object(direct, 'app_preference', return_value=None):
            folder, fmt = direct.screenshot_settings()
        self.assertTrue(folder.endswith('Pictures/QUADERNO 截屏'))
        self.assertEqual(fmt, 'png')
        with patch.object(direct, 'app_preference', side_effect=lambda key: {'ScreenshotFormat': 'PDF'}.get(key)):
            self.assertEqual(direct.screenshot_settings('/tmp/x')[1], 'pdf')



class PageTitleTests(unittest.TestCase):
    def test_derived_title_names_the_file_but_is_not_printed_twice(self):
        import yaml
        title, rendered = direct.prepare_markdown('# 只有一级标题\n\n正文一段。')
        meta = yaml.safe_load(rendered.split('---')[1])
        self.assertEqual(title, '只有一级标题')
        self.assertNotIn('title', meta)
        self.assertEqual(meta['pagetitle'], '只有一级标题')

    def test_front_matter_title_stays_the_page_title(self):
        import yaml
        _, rendered = direct.prepare_markdown('---\ntitle: 我的阅读\n---\n\n正文')
        meta = yaml.safe_load(rendered.split('---')[1])
        self.assertEqual(meta['title'], '我的阅读')
        self.assertNotIn('pagetitle', meta)


class FollowUpHardeningTests(unittest.TestCase):
    """Remaining robustness items from the 2026-11-05 gap list."""

    def test_transfer_timeout_is_capped_below_outer_deadline(self):
        self.assertEqual(direct.transfer_timeout(1200 * 1024 * 1024), direct.MAX_TRANSFER_SECONDS)
        self.assertLess(direct.MAX_TRANSFER_SECONDS, 3600)

    def test_cleanup_delete_has_short_deadline_and_bounded_sweep(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            pin = 'sha256//pin'
            direct.remember_orphan(pin, 'one')
            direct.remember_orphan(pin, 'two')
            seen = []
            device = direct.Device({'public_key_pin': pin}, b'', '')

            def request(method, endpoint, **kwargs):
                seen.append(kwargs.get('time_limit'))
                return direct.Response(204, {}, b'')

            device.request = request
            device.remove_orphans()
            self.assertEqual(seen, [direct.CLEANUP_REQUEST_SECONDS] * 2)
            self.assertEqual(direct.pending_orphans(pin), [])
            direct.remember_orphan(pin, 'three')
            seen.clear()
            with patch.object(direct.time, 'monotonic', side_effect=[0, direct.CLEANUP_BUDGET_SECONDS + 1]):
                device.remove_orphans()
            self.assertEqual(seen, [])
            self.assertEqual(direct.pending_orphans(pin), ['three'])

    def test_cleanup_failure_is_recorded_not_silent(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            pin = 'sha256//pin'
            direct.remember_orphan(pin, 'stuck')
            device = direct.Device({'public_key_pin': pin}, b'', '')

            def fail(method, endpoint, **kwargs):
                raise direct.ConnectionFailure(7)

            device.request = fail
            device.remove_orphans()
            record = [x for x in direct.load_orphans() if x['id'] == 'stuck']
            self.assertEqual(len(record), 1)
            self.assertIn('last_error', record[0])
            self.assertIsInstance(record[0]['last_error'], str)

    def test_keyboard_interrupt_does_not_issue_cleanup_request(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'a.pdf'
            source.write_bytes(b'%PDF-a')
            deleted = []
            device = direct.Device({'public_key_pin': 'sha256//pin'}, b'', '')
            device.authenticate = lambda: None
            device.resolve = lambda path: {'entry_id': 'root'} if path == 'Document/Received' else None

            def request(method, endpoint, **kwargs):
                if method == 'DELETE':
                    deleted.append(endpoint)
                    return direct.Response(204, {}, b'')
                if method == 'PUT' and endpoint.endswith('/file'):
                    raise KeyboardInterrupt()
                if method == 'POST':
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                return direct.Response(204, {}, b'')

            device.request = request
            with self.assertRaises(KeyboardInterrupt):
                device.upload(source)
            self.assertEqual(deleted, [])

    def test_download_streams_to_file_without_loading_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = b'%PDF-download' * 1000
            dest = Path(tmp) / 'out.pdf'
            device = direct.Device({'address': 'a', 'public_key_pin': 'sha256//p'}, b'', '')
            seen = {}

            def fake_run(args, **kwargs):
                Path(args[args.index('--dump-header') + 1]).write_text('HTTP/1.1 200 OK\n')
                body = Path(args[args.index('--output') + 1])
                seen['streams_outside_tempdir'] = tmp in str(body)
                seen['max_time'] = args[args.index('--max-time') + 1]
                body.write_bytes(payload)
                return type('Result', (), {'returncode': 0, 'stdout': b'200'})()

            with patch.object(direct.subprocess, 'run', side_effect=fake_run):
                result = device.download('abc123', str(dest))
            self.assertTrue(result['ok'])
            self.assertEqual(dest.read_bytes(), payload)
            self.assertTrue(seen['streams_outside_tempdir'])
            self.assertEqual(seen['max_time'], str(direct.MAX_TRANSFER_SECONDS))
            self.assertEqual([p.name for p in Path(tmp).iterdir()], ['out.pdf'])


@unittest.skipUnless(shutil.which('zsh') and Path('/usr/bin/shasum').exists(),
                     'source-stamp.sh needs zsh and /usr/bin/shasum')
class SourceStampTests(unittest.TestCase):
    def stamp(self, directory):
        script = Path(__file__).parents[1] / 'direct' / 'source-stamp.sh'
        return subprocess.run(
            ['/bin/zsh', '-c', 'source "$1"; direct_source_stamp "$2"', '_', str(script), str(directory)],
            capture_output=True, text=True)

    def test_stamp_changes_with_source_and_fails_on_missing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            for name in ('quaderno_direct.py', 'requirements-build.txt', 'build-helper.sh'):
                (d / name).write_text(name)
            first = self.stamp(d)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(len(first.stdout.strip()), 64)
            (d / 'quaderno_direct.py').write_text('changed')
            second = self.stamp(d)
            self.assertNotEqual(first.stdout.strip(), second.stdout.strip())
            (d / 'build-helper.sh').unlink()
            missing = self.stamp(d)
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(missing.stdout.strip(), '')


class InputBoundaryTests(unittest.TestCase):
    """Gaps found by the 2026-11-05 offline probe: empty input, long names, idempotency."""

    def device(self):
        device = direct.Device({'public_key_pin': 'sha256//pin'}, b'', '')
        device.authenticate = lambda: None
        device.remove_orphans = lambda: None
        return device

    def test_zero_byte_pdf_is_rejected_before_any_device_request(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'empty.pdf'
            source.write_bytes(b'')
            device = self.device()
            device.resolve = lambda path: {'entry_id': 'root'}
            calls = []
            device.request = lambda *args, **kwargs: calls.append(args)
            with self.assertRaisesRegex(direct.DirectError, 'PDF 文件为空'):
                device.upload(source)
            self.assertEqual(calls, [])

    def test_remote_name_is_bounded_and_folds_control_characters(self):
        long_name = direct.remote_file_name(Path('/tmp/' + 'L' * 180 + '.pdf'))
        self.assertEqual(len(long_name), direct.MAX_REMOTE_NAME)
        self.assertTrue(long_name.endswith('.pdf'))
        folded = direct.remote_file_name(Path('/tmp/a\nb:c.pdf'))
        self.assertNotIn('\n', folded)
        self.assertNotIn(':', folded)
        self.assertEqual(folded, 'a_b_c.pdf')

    def test_upload_posts_the_bounded_name(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / ('L' * 180 + '.pdf')
            source.write_bytes(b'%PDF-long')
            bounded = direct.remote_file_name(source)
            device = self.device()
            answers = iter([{'entry_id': 'root'}, None, {'entry_id': 'new'}])
            device.resolve = lambda path: next(answers)
            posted = []
            def request(method, endpoint, **kwargs):
                if method == 'POST':
                    posted.append(kwargs['json_body']['file_name'])
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                return direct.Response(200, {}, b'')
            device.request = request
            result = device.upload(source)
            self.assertEqual(posted, [bounded])
            self.assertEqual(result['path'], 'Document/Received/' + bounded)

    def test_identical_repeat_upload_is_skipped_without_writing(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'same.pdf'
            source.write_bytes(b'%PDF-same')
            device = self.device()
            device.resolve = lambda path: {'entry_id': 'root' if path == 'Document/Received' else 'old'}
            writes = []
            def request(method, endpoint, **kwargs):
                writes.append(method)
                if kwargs.get('output_path') is not None:
                    Path(kwargs['output_path']).write_bytes(source.read_bytes())
                return direct.Response(200, {}, b'')
            device.request = request
            result = device.upload(source)
            self.assertTrue(result['skipped'])
            self.assertEqual(result['path'], 'Document/Received/same.pdf')
            self.assertEqual(writes, ['GET'])  # readback only: no POST / PUT / DELETE

    def test_different_content_with_the_same_name_gets_a_deterministic_suffix(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            source = Path(tmp) / 'same.pdf'
            source.write_bytes(b'%PDF-new')
            expected = direct.file_sha256(source)
            answers = iter([{'entry_id': 'root'}, {'entry_id': 'old'}, None, {'entry_id': 'new'}])
            device = self.device()
            device.resolve = lambda path: next(answers)
            posted = []
            def request(method, endpoint, **kwargs):
                if kwargs.get('output_path') is not None:
                    Path(kwargs['output_path']).write_bytes(b'%PDF-old')
                    return direct.Response(200, {}, b'')
                if method == 'POST':
                    posted.append(kwargs['json_body']['file_name'])
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                return direct.Response(200, {}, b'')
            device.request = request
            device.upload(source)
            self.assertEqual(posted, ['same_' + expected[:8] + '.pdf'])

    def test_missing_local_dependency_is_not_reported_as_a_device_failure(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            out = io.StringIO()
            with patch.object(sys, 'argv', ['quaderno-direct', 'check']), \
                 patch.object(direct, 'prepare_usb', lambda: None), \
                 patch.object(direct, 'load_device',
                              side_effect=FileNotFoundError(2, 'No such file', '/usr/bin/curl')), \
                 contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
                direct.main()
            payload = json.loads(out.getvalue().strip())
            self.assertFalse(payload['ok'])
            self.assertIn('本机缺少直连所需的工具或文件', payload['message'])
            self.assertIn('/usr/bin/curl', payload['message'])


class QueuedDeliveryTests(unittest.TestCase):
    def test_lock_wait_is_aligned_with_a_full_transaction(self):
        self.assertEqual(inspect.signature(direct.connection_lock).parameters['timeout'].default,
                         direct.MAX_TRANSFER_SECONDS)
        self.assertEqual(direct.LOCK_WAIT_SECONDS, direct.MAX_TRANSFER_SECONDS)

    def test_second_transaction_waits_instead_of_failing(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            order, errors = [], []
            def worker(label, hold):
                try:
                    with direct.connection_lock(timeout=3):
                        order.append(label + ':start')
                        time.sleep(hold)
                        order.append(label + ':end')
                except Exception as error:  # surface thread failures in the assertion below
                    errors.append(repr(error))
            first = threading.Thread(target=worker, args=('first', 0.4))
            first.start()
            time.sleep(0.05)
            second = threading.Thread(target=worker, args=('second', 0))
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                second.start()
                first.join()
                second.join()
            self.assertEqual(errors, [])
            self.assertEqual(order, ['first:start', 'first:end', 'second:start', 'second:end'])
            self.assertIn('正在等待', stderr.getvalue())


class OrphanLifecycleTests(unittest.TestCase):
    """Orphan records must stay auditable: no silent truncation, bounded retries, TTL recovery."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / 'Direct'
        guard = patch.object(direct, 'ROOT', self.root)
        guard.start()
        self.addCleanup(guard.stop)
        self.pin = 'sha256//pin'

    def test_new_records_are_timestamped_and_over_limit_is_recorded_not_dropped(self):
        direct.remember_orphan(self.pin, 'a', 'boom')
        record = direct.load_orphans()[0]
        self.assertIn('created_at', record)
        self.assertEqual(record['attempts'], 0)
        self.assertEqual(record['last_error'], 'boom')
        with patch.object(direct, 'ORPHAN_LIMIT', 3):
            for index in range(5):
                direct.remember_orphan(self.pin, 'x%d' % index)
        ids = [item['id'] for item in direct.load_orphans()]
        self.assertEqual(len(ids), 6)
        self.assertIn('a', ids)
        self.assertIn('x4', ids)
        overflow = json.loads((self.root / 'orphans-overflow.json').read_text(encoding='utf-8'))
        self.assertGreaterEqual(overflow['count'], 1)
        self.assertIn('last_at', overflow)

    def test_retries_are_bounded_and_expired_records_leave_the_active_set(self):
        direct.remember_orphan(self.pin, 'stuck')
        device = direct.Device({'public_key_pin': self.pin}, b'', '')

        def fail(*args, **kwargs):
            raise direct.ConnectionFailure(7)

        device.request = fail
        for _ in range(direct.ORPHAN_MAX_ATTEMPTS):
            device.remove_orphans()
        record = [item for item in direct.load_orphans() if item['id'] == 'stuck'][0]
        self.assertEqual(record['attempts'], direct.ORPHAN_MAX_ATTEMPTS)
        self.assertTrue(record['abandoned'])
        self.assertEqual(direct.pending_orphans(self.pin), [])

        record['created_at'] = (datetime.now().astimezone()
                               - timedelta(days=31)).isoformat(timespec='seconds')
        direct.save_orphans(direct.load_orphans()[:0] + [record])
        self.assertEqual(direct.prune_expired_orphans(), 1)
        self.assertEqual(direct.load_orphans(), [])
        self.assertTrue((self.root / 'orphans-archive.json').exists())

    def test_legacy_records_without_timestamp_are_never_dropped(self):
        self.root.mkdir(parents=True, exist_ok=True)
        direct.save_orphans([{'pin': self.pin, 'id': 'legacy'}])
        self.assertEqual(direct.prune_expired_orphans(), 0)
        self.assertEqual(direct.pending_orphans(self.pin), ['legacy'])

    def test_other_device_records_are_not_touched_by_the_current_sweep(self):
        direct.remember_orphan(self.pin, 'mine')
        direct.remember_orphan('sha256//other', 'theirs')
        device = direct.Device({'public_key_pin': self.pin}, b'', '')
        device.request = lambda *a, **k: direct.Response(204, {}, b'')
        device.remove_orphans()
        self.assertEqual(direct.pending_orphans(self.pin), [])
        self.assertEqual(direct.pending_orphans('sha256//other'), ['theirs'])


class DeviceEncodingTests(unittest.TestCase):
    """The device echoes U+007F-U+00FF as a raw single byte, not UTF-8."""

    def test_latin1_range_is_folded_but_multibyte_scripts_are_kept(self):
        name = direct.remote_file_name(
            Path('/tmp/认知天性 (彼得·C·布朗  亨利·L·罗迪格三世) (z-library.sk, 1lib.sk).pdf'))
        self.assertNotIn('\u00b7', name)
        self.assertIn('认知天性', name)
        self.assertTrue(all(not ('\x7f' <= c <= '\xff') for c in name))
        kana = direct.remote_file_name(Path('/tmp/読み物·ノート.pdf'))
        self.assertIn('読み物', kana)
        self.assertNotIn('\u00b7', kana)

    def test_json_reply_with_raw_latin1_byte_is_still_parsable(self):
        payload = b'{"entry_id":"abc","entry_name":"A' + b'\xb7' + b'B"}'
        parsed = direct.Response(200, {}, payload).json()
        self.assertEqual(parsed['entry_id'], 'abc')
        self.assertIn('\ufffd', parsed['entry_name'])

    def test_response_header_with_raw_latin1_byte_does_not_fail_request(self):
        device = direct.Device({'address': 'Android.local', 'public_key_pin': 'sha256//expected'}, b'', '')
        def fake_run(args, **kwargs):
            Path(args[args.index('--dump-header') + 1]).write_bytes(
                b'HTTP/1.1 200 OK\r\nContent-Disposition: attachment; filename="a\xb7b.pdf"\r\n\r\n')
            Path(args[args.index('--output') + 1]).write_bytes(b'{}')
            return type('Result', (), {'returncode': 0, 'stdout': b'200'})()
        with patch.object(direct.subprocess, 'run', side_effect=fake_run):
            response = device.request('GET', '/documents/abc/file')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {})

    def test_failed_display_request_never_deletes_the_uploaded_document(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'a.pdf'
            source.write_bytes(b'%PDF-a')
            device = direct.Device({}, b'', '')
            device.authenticate = lambda: None
            seen = []
            def resolve(path):
                seen.append(path)
                if path == 'Document/Received':
                    return {'entry_id': 'root', 'entry_type': 'folder'}
                return {'entry_id': 'new'} if len(seen) > 2 else None
            device.resolve = resolve
            deleted = []
            def request(method, endpoint, **kwargs):
                if endpoint == '/viewer/controls/open2':
                    raise UnicodeDecodeError('utf-8', b'\xb7', 396, 397, 'invalid start byte')
                if method == 'DELETE':
                    deleted.append(endpoint)
                    return direct.Response(204, {}, b'')
                if method == 'POST':
                    return direct.Response(201, {}, b'{"document_id":"new"}')
                return direct.Response(200, {}, source.read_bytes())
            device.request = request
            result = device.upload(source)
            self.assertTrue(result['ok'])
            self.assertFalse(result['display_requested'])
            self.assertEqual(deleted, [])


class BookUploadTests(unittest.TestCase):
    """book-upload: one helper process, handshake overlapped with typesetting."""

    def args_for(self, root):
        source = root / 'book.epub'
        source.write_bytes(b'epub')
        directory = root / 'work'
        directory.mkdir()
        script = root / 'book.sh'
        script.write_text('#!/bin/sh\n')
        return (type('Args', (), {'file': str(source), 'directory': str(directory),
                                 'book_script': str(script)})(), directory / 'book.pdf')

    def test_authentication_overlaps_book_rendering(self):
        with tempfile.TemporaryDirectory() as tmp:
            args, output = self.args_for(Path(tmp))
            started, released, overlaps = threading.Event(), threading.Event(), []
            class FakeDevice:
                def upload(self, path):
                    return {'ok': True, 'message': 'ok'}
            def fake_connect():
                started.set()
                overlaps.append(released.wait(5))
                return FakeDevice()
            def fake_run(cmd, **kwargs):
                overlaps.append(started.wait(5))
                output.write_bytes(b'%PDF-book')
                released.set()
                return type('Result', (), {'returncode': 0, 'stdout': b'', 'stderr': b''})()
            with patch.object(direct, 'connect_device', fake_connect), \
                 patch.object(direct, 'load_clipboard_layout', lambda: (None, 'factory')), \
                 patch.object(direct.subprocess, 'run', side_effect=fake_run):
                result = direct.book_upload(args)
            self.assertTrue(result['ok'])
            self.assertEqual(len(overlaps), 2)
            self.assertTrue(all(overlaps), 'authentication and rendering must overlap')
            self.assertFalse(output.exists(), 'a delivered staging PDF is removed')

    def test_failed_upload_keeps_the_rendered_pdf_and_records_detail(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            args, output = self.args_for(Path(tmp))
            class FailingDevice:
                def upload(self, path):
                    raise direct.DirectError('device refused the document')
            def fake_run(cmd, **kwargs):
                output.write_bytes(b'%PDF-book')
                return type('Result', (), {'returncode': 0, 'stdout': b'', 'stderr': b''})()
            with patch.object(direct, 'connect_device', FailingDevice), \
                 patch.object(direct, 'load_clipboard_layout', lambda: (None, 'factory')), \
                 patch.object(direct.subprocess, 'run', side_effect=fake_run):
                with self.assertRaises(direct.DirectError):
                    direct.book_upload(args)
            self.assertTrue(output.exists(), 'Retry needs the PDF to remain on disk')
            history = json.loads((direct.ROOT / 'history.jsonl').read_text().splitlines()[-1])
            self.assertEqual(history['status'], 'failed')
            self.assertEqual(Path(history['kept']), output.resolve())
            self.assertIn('Traceback', history['detail'])


class ClipboardNormalizationTests(unittest.TestCase):
    """L1: only structural evidence may rewrite the clipboard; prose is byte-identical."""

    def setUp(self):
        direct._PENDING_META.clear()

    @staticmethod
    def glyphs(value):
        return ''.join(value.split())

    def test_plain_text_and_formula_delimiters_are_byte_identical(self):
        text = ('普通段落，**加粗** 与 `inline code`。\n\n---\n\n## 小标题\n\n'
                '公式 \\(\\text{Li}^+\\) 与 \\[\\Delta_{net}\\] 以及 '
                '\\\\(\\\\text{Na}^+\\\\) 和 $PATH @mention。\n')
        out, info = direct.normalize_clipboard(text)
        self.assertEqual(out, text)
        self.assertEqual(info['flavor'], 'plain')
        self.assertFalse(info['applied'])

    def test_existing_gfm_table_passes_through_with_structural_stats(self):
        text = '| 指标 | 实测值 | 后果 |\n|:---|:---|:---|\n| 镜头构成 | 53 段 | 高重复 |\n'
        out, info = direct.normalize_clipboard(text)
        self.assertEqual(out, text)
        self.assertEqual(info['flavor'], 'markdown')
        self.assertEqual((info['table_count'], info['max_cols'], info['row_count']), (1, 3, 1))

    def test_tsv_becomes_headerless_table_without_inventing_a_header(self):
        text = ('术语 / 词汇 (Term)\t国际音标 (IPA)\t核心含义\n'
                '阿赖耶识\t/aː.la.ja/\t含藏诸法种子\n'
                '末那识\t/ma.na/\t恒审思量\n')
        out, info = direct.normalize_clipboard(text)
        self.assertEqual(info['flavor'], 'tsv')
        self.assertTrue(info['applied'])
        self.assertEqual((info['max_cols'], info['row_count']), (3, 3))
        self.assertEqual(self.glyphs(out.replace('|', '').replace('---', '')),
                         self.glyphs(text))
        # The first row stays data; an empty header row is not a fabricated header.
        self.assertTrue(out.lstrip().startswith('|  |  |  |'))

    def test_tsv_inside_fenced_code_block_is_preserved(self):
        text = ('示例脚本：\n\n```python\n'
                'def f(a, b):\n\treturn a\t+ b\n\tprint(a)\tprint(b)\n'
                '```\n\n正文结束。\n')
        out, info = direct.normalize_clipboard(text)
        self.assertEqual(out, text)
        self.assertFalse(info['applied'])
        self.assertEqual(info['table_count'], 0)

    def test_html_replacement_skips_fenced_code_lines(self):
        html = ('<table><tr><th>指标</th><th>值</th></tr>'
                '<tr><td>镜头</td><td>53 段</td></tr></table>')
        text = ('```text\n指标 值\n镜头 53 段\n```\n\n正文。\n')
        out, info = direct.normalize_clipboard(text, html)
        self.assertEqual(out, text)
        self.assertFalse(info['applied'])
        self.assertTrue(info['unmapped'])

    def test_inconsistent_tsv_column_counts_are_left_as_prose(self):
        text = 'A\tB\nC\tD\tE\nF\tG\n'
        out, info = direct.normalize_clipboard(text)
        self.assertEqual(out, text)
        self.assertFalse(info['applied'])

    def test_html_table_replaces_only_the_collapsed_line_range(self):
        html = ('<html><body><p>导言</p><table><thead><tr><th>指标</th><th>实测值</th>'
                '</tr></thead><tbody><tr><td>镜头构成</td><td>53 段：media 30</td></tr>'
                '<tr><td>素材池</td><td>22 项中 13 项</td></tr></tbody></table>'
                '<script>SCRIPT_SHOULD_NOT_EXECUTE</script><p>尾注</p></body></html>')
        text = '导言\n\n指标 实测值\n镜头构成 53 段：media 30\n素材池 22 项中 13 项\n\n尾注\n'
        out, info = direct.normalize_clipboard(text, html)
        self.assertEqual(info['flavor'], 'html')
        self.assertTrue(info['applied'])
        self.assertIn('导言', out)
        self.assertIn('尾注', out)
        self.assertNotIn('SCRIPT_SHOULD_NOT_EXECUTE', out)
        self.assertIn('| 指标 | 实测值 |', out)
        self.assertIn('| 镜头构成 | 53 段：media 30 |', out)
        self.assertEqual(info['row_count'], 2)

    def test_colspan_expands_without_duplicating_visible_text(self):
        html = ('<table><tr><th>A|B</th><th>C</th></tr>'
                '<tr><td colspan="2">合并值</td></tr></table>')
        out, info = direct.normalize_clipboard('A|B C\n合并值\n', html)
        self.assertEqual(info['flavor'], 'html')
        self.assertEqual(info['span_expanded'], 1)
        self.assertIn(r'A\|B', out)
        self.assertEqual(out.count('合并值'), 1)
        self.assertEqual(info['max_cols'], 2)   # escaped pipe is not a column

    def test_rowspan_is_registered_as_unmapped_instead_of_being_merged(self):
        html = ('<table><tr><th>A</th><th>B</th></tr>'
                '<tr><td rowspan="2">跨行</td><td>x</td></tr><tr><td>y</td></tr></table>')
        text = 'A B\n跨行 x\ny\n'
        out, info = direct.normalize_clipboard(text, html)
        self.assertEqual(out, text)
        self.assertFalse(info['applied'])
        self.assertTrue(any('rowspan' in item for item in info['unmapped']))

    def test_unlocatable_html_table_falls_back_to_plain_text(self):
        html = '<table><tr><th>完全不存在的锚点</th></tr><tr><td>x</td></tr></table>'
        text = '一段与表格无关的正文。\n'
        out, info = direct.normalize_clipboard(text, html)
        self.assertEqual(out, text)
        self.assertFalse(info['applied'])
        self.assertTrue(info['unmapped'])

    def test_clean_title_keeps_tab_separators_as_spaces(self):
        header = '术语 / 词汇 (Term)\t国际音标 (IPA)\t核心含义与佛教语境解析'
        title = direct.clean_title(header)
        self.assertIn('国际音标', title)
        # History #19 concatenated the cells because tabs were deleted as control chars.
        self.assertNotIn('(Term)国际音标', title)

    def test_geometry_helpers(self):
        self.assertEqual(direct._millimetres('157.1mm'), 157.1)
        self.assertEqual(direct._points('10.5pt'), 10.5)
        self.assertIsNone(direct._millimetres('letter'))

    def test_render_command_attaches_the_layout_filter_and_geometry(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            root = Path(tmp)
            directory = root / 'work'
            directory.mkdir()
            (directory / 'table-layout.lua').write_text('-- filter\n', encoding='utf-8')
            (directory / 'deliver.typ').write_text('$body$\n', encoding='utf-8')
            source = root / 'input.md'
            source.write_text('普通正文。\n', encoding='utf-8')
            html = root / 'input.html'
            html.write_text('<table><tr><th>A</th><th>B</th></tr>'
                            '<tr><td>x</td><td>y</td></tr></table>', encoding='utf-8')
            args = type('Args', (), {
                'directory': str(directory), 'input': str(source), 'clipboard_html': str(html),
                'pandoc': 'pandoc', 'typst': 'typst', 'template': str(directory / 'deliver.typ'),
                'format': 'markdown', 'print_time': False, 'doc_lang': 'zh',
                'font': ['Times New Roman', 'Songti SC'], 'page_width': '157.1mm',
                'page_height': '209.5mm', 'margin': '14mm', 'size': '10.5pt',
                'leading': '0.85em', 'font_directory': None, 'title': ''})()
            captured = {}

            class FakeDevice:
                def upload(self, path):
                    return {'ok': True, 'message': 'ok'}

            def fake_run(cmd, **kwargs):
                captured['cmd'] = cmd
                (directory / 'render.pdf').write_bytes(b'%PDF')
                named = Path(cmd[cmd.index('-o') + 1])
                named.write_bytes(b'%PDF')
                return type('Result', (), {'returncode': 0, 'stdout': b'', 'stderr': b''})()

            with patch.object(direct, 'connect_device', FakeDevice), \
                 patch.object(direct, 'load_clipboard_layout', lambda: (None, 'factory')), \
                 patch.object(direct.subprocess, 'run', side_effect=fake_run):
                direct.render_and_upload(args)
            cmd = captured['cmd']
            self.assertTrue(any(item.startswith('--lua-filter=') for item in cmd))
            self.assertIn('-M', cmd)
            self.assertIn('typarea_mm=129.10', cmd)
            self.assertIn('body_size_pt=10.50', cmd)
            self.assertEqual(direct._PENDING_META['flavor'], 'plain')

    def test_delivery_record_carries_structural_metadata_only(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(direct, 'ROOT', Path(tmp) / 'Direct'):
            direct._PENDING_META.update({'flavor': 'tsv', 'table_count': 1,
                                         'max_cols': 3, 'row_count': 3, 'applied': True,
                                         'unmapped': [], 'span_expanded': 0})
            direct.record_delivery('sample.pdf', True, document_id='id-1')
            entry = json.loads((direct.ROOT / 'history.jsonl').read_text().splitlines()[-1])
            self.assertEqual(entry['normalization']['flavor'], 'tsv')
            self.assertEqual(entry['normalization']['max_cols'], 3)
            self.assertNotIn('input', entry)
            self.assertNotIn('text', entry)


class LiveProgressTests(unittest.TestCase):
    def test_curl_percentage_is_parsed_from_transfer_meter(self):
        self.assertIsNone(direct.curl_upload_fraction('% Total % Received % Xferd'))
        self.assertIsNone(direct.curl_upload_fraction('connection failed'))
        self.assertEqual(direct.curl_upload_fraction('42 1000 0 0 42 420 12 34'), .42)
        self.assertEqual(direct.curl_upload_fraction('100 1000 0 0 100 1000 12 34'), 1)

    def test_download_progress_observes_written_bytes_and_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            body = Path(tmp) / 'body'
            meter = Path(tmp) / 'meter'
            payload = b'a' * 131072
            def fake_run(args, **kwargs):
                with body.open('wb') as stream:
                    stream.write(payload[:65536])
                    stream.flush()
                    time.sleep(.25)
                    stream.write(payload[65536:])
                return subprocess.CompletedProcess(args, 0, b'200')
            output = io.StringIO()
            with patch.dict(os.environ, {'QUADERNO_PROGRESS': '1'}), contextlib.redirect_stderr(output), \
                 patch.object(direct.subprocess, 'run', side_effect=fake_run):
                result = direct.run_transfer_with_progress([], 'PRIVATE_CONFIG', 1,
                    phase='readback', size=len(payload), body=body, meter=meter)
                digest = direct.file_sha256(body, progress=True)
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(result.returncode, 0)
            self.assertEqual(digest, hashlib.sha256(payload).hexdigest())
            self.assertTrue(any(event.get('completed') == 65536 for event in events))
            self.assertTrue(any(event.get('fraction') == .5 for event in events))
            self.assertEqual(events[-1]['phase'], 'verify')
            self.assertEqual(events[-1]['completed'], len(payload))
            self.assertNotIn('PRIVATE_CONFIG', output.getvalue())

    def test_upload_progress_uses_curl_percent_not_elapsed_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            meter = Path(tmp) / 'meter'
            def fake_run(args, **kwargs):
                kwargs['stderr'].write(b' 40 1000 0 0 40 400 0 0\r')
                kwargs['stderr'].flush()
                time.sleep(.25)
                kwargs['stderr'].write(b'100 1000 0 0 100 1000 0 0\n')
                kwargs['stderr'].flush()
                return subprocess.CompletedProcess(args, 0, b'200')
            output = io.StringIO()
            with patch.dict(os.environ, {'QUADERNO_PROGRESS': '1'}), contextlib.redirect_stderr(output), \
                 patch.object(direct.subprocess, 'run', side_effect=fake_run):
                direct.run_transfer_with_progress([], '', 1, phase='upload', size=1000,
                    body=Path(tmp) / 'body', meter=meter)
            fractions = [json.loads(line)['fraction'] for line in output.getvalue().splitlines()]
            self.assertIn(.4, fractions)
            self.assertEqual(fractions[-1], 1)

if __name__ == '__main__':
    unittest.main()
