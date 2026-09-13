#!/usr/bin/env python3
"""Offline source/resource contract audit. Never reads data/, dist/, or user stores."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STRING = r'"(?:[^"\\]|\\.)*"'


def catalog(language):
    source = (ROOT / f"HAENA/Localization/{language}.lproj/Localizable.strings").read_text()
    pairs = re.findall(rf'({STRING})\s*=\s*({STRING});', source)
    result = {json.loads(k): json.loads(v) for k, v in pairs}
    assert len(result) == len(pairs), "duplicate resource key"
    return result


def audit():
    ko, en = catalog("ko"), catalog("en")
    assert ko.keys() == en.keys(), "language key inventory mismatch"
    for key, value in en.items():
        assert value and not re.search('[가-힣]', value), f"missing English: {key}"
        assert key.count('%@') == value.count('%@'), f"placeholder mismatch: {key}"
    files = sorted((ROOT / 'HAENA/Views').glob('*.swift')) + sorted((ROOT / 'HAENA/Localization').glob('*.swift')) + [ROOT / 'HAENA/HAENAApp.swift']
    references = 0
    for path in files:
        for match in re.finditer(rf'L10n\.(?:text|format)\(\s*({STRING})', path.read_text()):
            key = json.loads(match[1])
            assert key in ko, f"missing catalog key: {path.name}: {key}"
            references += 1
    preference_source = (ROOT/'HAENA/Localization/AppLanguage.swift').read_text()
    for forbidden in ['ProjectRepository', 'WorkStateExtractionService', 'URLSession', 'Keychain', '.id(']:
        assert forbidden not in preference_source, f"preference crossed domain boundary: {forbidden}"
    print(json.dumps({'catalog_keys':len(ko), 'static_resource_references':references, 'missing_keys':0, 'placeholder_mismatches':0, 'scope':'UI source and resource files only'}, indent=2))


if __name__ == '__main__':
    audit()
