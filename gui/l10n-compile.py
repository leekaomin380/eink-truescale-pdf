#!/usr/bin/env python3
"""Compile Localization/Localizable.xcstrings into <lang>.lproj/Localizable.strings.

Plain-Python stand-in for `xcstringstool compile`, so building the app needs only the
Command Line Tools. Only simple string units are used in this project (no plurals).
"""
import json
import sys
from pathlib import Path

catalog, output = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(catalog.read_text())
source = data['sourceLanguage']


def quote(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


tables = {source: {}}
for key, entry in data['strings'].items():
    if not key or entry.get('shouldTranslate') is False:
        continue
    tables[source][key] = key
    for language, localization in entry.get('localizations', {}).items():
        unit = localization.get('stringUnit')
        if unit and unit.get('state') == 'translated':
            tables.setdefault(language, {})[key] = unit['value']

for language, table in tables.items():
    folder = output / (language + '.lproj')
    folder.mkdir(parents=True, exist_ok=True)
    lines = [quote(key) + ' = ' + quote(value) + ';' for key, value in sorted(table.items())]
    (folder / 'Localizable.strings').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'    {language}: {len(table)} 条')
