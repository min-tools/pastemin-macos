#!/usr/bin/env python3
"""Validate Pastemin localization coverage and format arguments."""
from pathlib import Path
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCES = sorted((ROOT / 'Sources/PasteminApp').glob('*.swift'))
EXPECTED_LANGUAGES = {
    'cs', 'da', 'de', 'el', 'en', 'es', 'fi', 'fr', 'hi', 'hr', 'hu', 'id',
    'it', 'ja', 'ko', 'nb', 'nl', 'pl', 'pt', 'ro', 'ru', 'sk', 'sr',
    'sr-Latn', 'sv', 'th', 'tr', 'uk', 'vi', 'zh-Hans', 'zh-Hant',
}
CALL = re.compile(
    r'localized(?:Format)?\(\s*"([a-z0-9_]+)",\s*"((?:[^"\\]|\\.)*)"'
)
FORMAT = re.compile(
    r'%%|%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|ll|h|l|q|z|t|j)?([@diuoxXfFeEgGaAcCsSp])'
)


def format_arguments(text):
    """Map printf argument positions to types, allowing translated reordering."""
    arguments = {}
    numbered = set()
    next_position = 1
    for match in FORMAT.finditer(text):
        if match[0] == '%%':
            continue
        numbered.add(match[1] is not None)
        position = int(match[1]) if match[1] else next_position
        kind = (match[2] or '') + match[3]
        if position < 1 or (position in arguments and arguments[position] != kind):
            raise ValueError('conflicting format arguments')
        arguments[position] = kind
        next_position += 1
    if len(numbered) > 1:
        raise ValueError('mixed numbered and unnumbered arguments')
    return arguments


def source_keys():
    """Collect stable keys and reject conflicting English fallbacks."""
    values = {}
    conflicts = set()
    for source in SOURCES:
        for match in CALL.finditer(source.read_text()):
            key, english = match.groups()
            if key in values and values[key] != english:
                conflicts.add(key)
            values[key] = english
    return values, conflicts


def strings_values(path):
    """Read .strings through Apple's plist parser to enforce valid syntax."""
    result = subprocess.run(
        ['plutil', '-convert', 'json', '-o', '-', str(path)],
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


def localization_issues():
    """Return all catalog, coverage, and placeholder errors."""
    issues = []
    source, conflicts = source_keys()
    if conflicts:
        issues.append(f'conflicting English fallbacks: {sorted(conflicts)}')
    folders = sorted((ROOT / 'Resources').glob('*.lproj'))
    languages = {folder.stem for folder in folders}
    if languages != EXPECTED_LANGUAGES:
        missing = sorted(EXPECTED_LANGUAGES - languages)
        extra = sorted(languages - EXPECTED_LANGUAGES)
        if missing:
            issues.append(f'missing language bundles: {missing}')
        if extra:
            issues.append(f'unexpected language bundles: {extra}')

    expected_keys = set(source)
    for folder in folders:
        language = folder.stem
        strings = folder / 'Localizable.strings'
        if not strings.is_file():
            issues.append(f'{language}: Localizable.strings is missing')
            continue
        try:
            values = strings_values(strings)
        except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
            issues.append(f'{language}: invalid strings file ({error})')
            continue
        keys = set(values)
        missing = sorted(expected_keys - keys)
        extra = sorted(keys - expected_keys)
        if missing:
            issues.append(f'{language}: missing keys: {missing}')
        if extra:
            issues.append(f'{language}: unused keys: {extra}')
        if language == 'en':
            mismatched = sorted(key for key in expected_keys & keys if values[key] != source[key])
            if mismatched:
                issues.append(f'en: values differ from source fallbacks: {mismatched}')
        for key in sorted(expected_keys & keys):
            try:
                compatible = format_arguments(source[key]) == format_arguments(values[key])
            except ValueError:
                compatible = False
            if not compatible:
                issues.append(f'{language}: incompatible format arguments for {key}')
    return source, issues


def main():
    source, issues = localization_issues()
    if issues:
        print('Localization validation failed:')
        for issue in issues:
            print(f'- {issue}')
        sys.exit(1)
    print(f'Pastemin localizations: {len(EXPECTED_LANGUAGES)} languages, {len(source)} keys passed')


if __name__ == '__main__':
    main()
