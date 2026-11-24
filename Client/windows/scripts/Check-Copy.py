"""Check WinUI markup, shared translations and error codes returned to the desktop client."""
import json
import re
from pathlib import Path
from xml.etree import ElementTree

WINDOWS = Path(__file__).resolve().parents[1]
ROOT = WINDOWS.parents[1]
RESOURCES = WINDOWS.parent / "apple/Shared/Resources"
QUOTED = r'"(?:[^"\\]|\\.)*"'
ENTRY = re.compile(rf"^({QUOTED}) = ({QUOTED});$")
CODE = r'"([A-Z][A-Z0-9_]+)"'


def catalog(locale, name):
    path = RESOURCES / f"{locale}.lproj" / f"{name}.strings"
    entries = {}
    for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        match = ENTRY.fullmatch(line)
        if not match:
            raise ValueError(f"{path}:{number}: unrecognized resource entry")
        key, value = map(json.loads, match.groups())
        if key in entries or not value.strip():
            raise ValueError(f"{path}:{number}: duplicate key or empty value for {key!r}")
        entries[key] = value
    return entries


def bilingual(name):
    zh, en = (catalog(locale, name) for locale in ("zh-Hans", "en"))
    if zh.keys() != en.keys():
        raise ValueError(f"{name}: language key sets differ: {zh.keys() ^ en.keys()}")
    return zh, en


def production_go(directory):
    return "\n".join(p.read_text(encoding="utf-8") for p in directory.glob("*.go")
                     if not p.name.endswith("_test.go"))


def check_markup(app):
    attributes = {
        "Text", "Header", "Title", "Message", "Label", "Content", "PlaceholderText", "PaneTitle",
        "PrimaryButtonText", "SecondaryButtonText", "CloseButtonText", "ToolTipService.ToolTip",
        "AutomationProperties.Name", "AutomationProperties.HelpText",
    }
    for path in app.glob("*.xaml"):
        for element in ElementTree.parse(path).iter():
            for attribute, value in element.attrib.items():
                label = attribute in attributes or (attribute == "Value" and element.get("Property") in attributes)
                if label and value and not value.startswith("{") and value not in ("Chirp", "chirp.example.com"):
                    raise ValueError(f"{path.name}: localize {attribute}={value!r}")


def main():
    zh, en = bilingual("Localizable")
    errors, _ = bilingual("Errors")
    app = WINDOWS / "Chirp"
    check_markup(app)
    source = "\n".join(p.read_text(encoding="utf-8-sig") for p in app.glob("*.cs"))
    shared = {json.loads(s) for s in re.findall(rf"\bL\(\s*({QUOTED})\s*\)", source)}
    invalid = {s for s in shared if s not in zh or re.search(r"%(?:\d+\$)?(?:lld|ld|d|@)", zh[s] + en[s])}
    if invalid:
        raise ValueError(f"Missing or unformatted WinUI translation: {sorted(invalid)}")

    # Only switch labels count as handlers. A code at its throw site is not a translation.
    handlers = set(re.findall(CODE, "\n".join(re.findall(
        r'^\s*((?:"[A-Z0-9_]+"(?: or )?)+)(?: when [^\n]+?)? =>', source, re.MULTILINE))))
    managed = set(re.findall(r'(?:IOException|ShowError)\(' + CODE, source))
    engine = set(re.findall(r'errors\.New\(' + CODE, production_go(WINDOWS / "engine")))
    server = set()
    for package in ("clienthttp", "httpapi", "group", "authorization", "passkeyhttp"):
        routes = production_go(ROOT / "internal" / package)
        server.update(re.findall(r'httpresponse\.Error\(\s*\w+,\s*[\w.]+,\s*' + CODE, routes))
        server.update(re.findall(r'\bcode\s*:?=\s*' + CODE, routes))
    required = managed | engine | server
    missing = [k for k in sorted(required) if k not in handlers and k not in errors and "CLIENT_" + k not in errors]
    if missing:
        raise ValueError(f"Untranslated desktop error codes: {', '.join(missing)}")
    print(f"PASS {len(shared)} WinUI shared strings, {len(errors)} bilingual error entries, "
          f"{len(required)} distinct emitted error codes")


if __name__ == "__main__":
    main()
