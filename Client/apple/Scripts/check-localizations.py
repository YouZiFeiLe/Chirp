#!/usr/bin/env python3
"""Validate shared Apple resources, error documentation and UI string coverage."""
from collections import Counter
import json
from pathlib import Path
import re

APPLE = Path(__file__).resolve().parents[1]
SHARED = APPLE / "Shared"
RESOURCES = SHARED / "Resources"
FAILURES = []
QUOTED = r'"(?:[^"\\]|\\.)*"'
ENTRY = re.compile(rf'^({QUOTED})\s*=\s*({QUOTED});\s*$', re.MULTILINE)
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(lld|ld|d|@)')


def read_table(language, table):
    source = RESOURCES / f"{language}.lproj" / f"{table}.strings"
    values = {}
    for match in ENTRY.finditer(source.read_text()):
        key, value = map(json.loads, match.groups())
        if key in values:
            FAILURES.append(f"{source}: duplicate key {key!r}")
        values[key] = value
    for line in source.read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("//") and not ENTRY.fullmatch(line):
            FAILURES.append(f"{source}: invalid entry {line!r}")
    return values


def swift_key(value):
    """Normalize literal Swift interpolations to their typed resource placeholders."""
    result = ""
    index = 0
    while index < len(value):
        if value[index:index + 2] == r"\(":
            end = index + 2
            depth = 1
            while end < len(value) and depth:
                depth += (value[end] == "(") - (value[end] == ")")
                end += 1
            expression = value[index + 2:end - 1]
            numeric = re.search(r'\b(count|unreadCount|maxParticipants|number|index|retryAfter)\b', expression)
            result += "%lld" if numeric else "%@"
            index = end
        else:
            result += value[index]
            index += 1
    return json.loads('"' + result + '"')


tables = {}
for table in ("Localizable", "Errors", "InfoPlist"):
    chinese = read_table("zh-Hans", table)
    english = read_table("en", table)
    tables[table] = chinese
    if chinese.keys() != english.keys():
        FAILURES.append(f"{table}: language keys differ: {chinese.keys() ^ english.keys()}")
    for key in chinese.keys() & english.keys():
        if Counter(PLACEHOLDER.findall(chinese[key])) != Counter(PLACEHOLDER.findall(english[key])):
            FAILURES.append(f"{table}: interpolation placeholders differ for {key!r}")
        if not chinese[key].strip() or not english[key].strip():
            FAILURES.append(f"{table}: empty translation for {key!r}")
        if re.search(r'[\u3400-\u9fff]', english[key]):
            FAILURES.append(f"{table}: untranslated English entry {key!r}")

codes = set(re.findall(r'^    case \w+ = "([A-Z0-9_]+)"', (SHARED / "ClientError.swift").read_text(), re.MULTILINE))
if codes != tables["Errors"].keys():
    FAILURES.append(f"Error code/resource mismatch: {codes ^ tables['Errors'].keys()}")
documented = set(re.findall(r'^\| `([A-Z0-9_]+)` \|', (APPLE / "ERROR_CODES.md").read_text(), re.MULTILINE))
if codes != documented:
    FAILURES.append(f"Error code/documentation mismatch: {codes ^ documented}")

for source in sorted(SHARED.rglob("*.swift")):
    for number, line in enumerate(source.read_text().splitlines(), 1):
        if line.lstrip().startswith(("//", "#Preview")):
            continue
        for match in re.finditer(QUOTED, line):
            value = match.group()[1:-1]
            if not re.search(r'[\u3400-\u9fff]', value):
                continue
            prefix = line[:match.start()]
            # These values are user content in fixtures, or native language names.
            if re.search(r'\b(name|displayName|senderName|text):\s*$', prefix):
                continue
            if source.name == "ChirpDesignReference.swift" and re.search(r'\bdescription:\s*$', prefix):
                continue
            if prefix.endswith('Text(verbatim: '):
                continue
            key = swift_key(value)
            if key not in tables["Localizable"]:
                FAILURES.append(f"{source.relative_to(APPLE)}:{number}: missing UI key {key!r}")

if FAILURES:
    raise SystemExit("\n".join(FAILURES))
print(f"Localization checks passed: {len(tables['Localizable'])} UI keys, {len(codes)} documented error codes, 2 languages.")
