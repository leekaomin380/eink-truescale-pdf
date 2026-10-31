"""Offline invariants: clipboard naming, source preservation, no overwrite, pinned transport."""
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

os.environ['QUADERNO_LANG'] = 'zh-Hans'  # assertions below use the source-language text
spec = importlib.util.spec_from_file_location('direct', Path(__file__).parents[1] / 'direct/quaderno_direct.py')
direct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(direct)
# Never touch the real pairing / history folder, even in tests that do not patch ROOT.
direct.ROOT = Path(tempfile.mkdtemp()) / 'Direct'


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
            self.assertIn(('GET', '/documents/new/file', {}), calls)
            self.assertFalse(any(method == 'DELETE' for method, _, _ in calls))
            self.assertTrue(source.exists())

    def test_failed_readback_does_not_report_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'test.pdf'; source.write_bytes(b'%PDF-original')
            device = direct.Device({}, b'', '')
            device.authenticate = lambda: None
            device.resolve = lambda path: {'entry_id': 'root'} if path == 'Document/Received' else None
            device.request = lambda method, endpoint, **kw: direct.Response(200, {},
                b'{"document_id":"new"}' if method == 'POST' else b'wrong bytes')
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
                 patch.object(direct, 'quaderno_on_usb', return_value=on_usb):
                self.assertEqual(direct.discover_endpoints('Android.local'), ['192.168.31.40'])

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


if __name__ == '__main__':
    unittest.main()


class MessageLanguageTests(unittest.TestCase):
    def tearDown(self):
        direct.language.cache_clear()

    def message_in(self, language, text, **values):
        direct.language.cache_clear()
        with patch.dict(os.environ, {'QUADERNO_LANG': language}):
            return direct.tr(text, **values)

    def test_app_language_selects_translation(self):
        text = '已保存至 Received：{name}（回读通过，已请求设备打开）'
        self.assertEqual(self.message_in('en', text, name='a.pdf'),
                         'Saved to Received: a.pdf (verified; asked the device to open it)')
        self.assertTrue(self.message_in('ja', text, name='a.pdf').startswith('Received に保存しました：a.pdf'))
        self.assertTrue(self.message_in('zh-Hans', text, name='a.pdf').startswith('已保存至 Received：a.pdf'))

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

