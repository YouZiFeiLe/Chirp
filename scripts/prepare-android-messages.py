"""Build Android resources from the shared, bilingual client message catalogs."""
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ENTRY = re.compile(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");')
FORMAT = re.compile(r'%(?:([0-9]+)\$)?(lld|ld|d|@|%)')
ANDROID_ARGUMENT = re.compile(r'%(?:([1-9][0-9]*)\$)?[-#+ 0,(]*[0-9]*(?:\.[0-9]+)?([dDfeEgGaAcCsSbBhHxXo%])')
LANGUAGES = [("en", "values"), ("zh-Hans", "values-zh-rCN")]

def read_table(path):
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.lstrip().startswith('"'):
            continue
        match = ENTRY.fullmatch(line.strip())
        if not match:
            raise ValueError(f"Invalid entry in {path}: {line}")
        key, value = map(json.loads, match.groups())
        if key in result:
            raise ValueError(f"Duplicate key in {path}: {key}")
        result[key] = value
    return result

def android_text(text):
    index = 0
    def arg(match):
        nonlocal index
        if match[2] == "%":
            return "%%"
        index += 1
        return "%" + (match[1] or str(index)) + "$" + ("s" if match[2] == "@" else "d")
    value = FORMAT.sub(arg, text)
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

def format_arguments(text):
    arguments = []
    implicit = 0
    for position, conversion in ANDROID_ARGUMENT.findall(text):
        if conversion == "%":
            continue
        if not position:
            implicit += 1
        arguments.append((int(position) if position else implicit, conversion.lower()))
    return sorted(arguments)


def check_message(name, default, localized):
    if not default.strip() or not localized.strip():
        raise ValueError(f"Empty localized message: {name}")
    if format_arguments(default) != format_arguments(localized):
        raise ValueError(f"Different English and Simplified Chinese format arguments: {name}")


def read_native_messages(folder):
    messages = {}
    for path in sorted(folder.glob("*.xml")):
        for entry in ET.parse(path).getroot():
            if entry.tag not in {"string", "plurals", "string-array"} or entry.get("translatable") == "false":
                continue
            key = entry.tag, entry.attrib["name"]
            if key in messages:
                raise ValueError(f"Duplicate Android message {key} in {path}")
            if entry.tag == "string":
                messages[key] = "".join(entry.itertext())
            elif entry.tag == "plurals":
                messages[key] = {item.attrib["quantity"]: "".join(item.itertext()) for item in entry}
            else:
                messages[key] = ["".join(item.itertext()) for item in entry]
    return messages


def check_native_resources(native, shared_keys):
    en, zh = (read_native_messages(native / folder) for _, folder in LANGUAGES)
    if en.keys() != zh.keys():
        raise ValueError(f"Missing English messages: {sorted(zh.keys() - en.keys())}."
                         f" Missing Simplified Chinese messages: {sorted(en.keys() - zh.keys())}.")
    for (kind, name), default in en.items():
        localized = zh[kind, name]
        if kind == "string":
            if name in shared_keys:
                raise ValueError(f"Android message already supplied by the shared catalog: {name}")
            check_message(name, default, localized)
        elif kind == "plurals":
            for quantity in default.keys() | localized.keys():
                check_message(f"{name}/{quantity}", default.get(quantity, default["other"]),
                              localized.get(quantity, localized["other"]))
        else:
            if len(default) != len(localized):
                raise ValueError(f"Different localized array lengths: {name}")
            for index, (left, right) in enumerate(zip(default, localized)):
                check_message(f"{name}[{index}]", left, right)


def write_resources(apple, keys, output):
    all_errors = None
    default_messages = None
    for language, folder in LANGUAGES:
        source = apple / (language + ".lproj")
        errors = read_table(source / "Errors.strings")
        if all_errors is not None and all_errors != errors.keys():
            raise ValueError("The two error catalogs have different keys")
        all_errors = errors.keys()
        ui = read_table(source / "Localizable.strings") | read_table(source / "InfoPlist.strings")
        messages = {}
        for name, key in keys.items():
            if key not in ui:
                raise ValueError(f"Missing {language} shared Android message: {name} ({key})")
            messages[name] = ui[key]
        if default_messages is None:
            default_messages = (errors, messages)
        default_errors, default_ui = default_messages
        for code, value in errors.items():
            check_message(code, android_text(default_errors[code])[1:-1], android_text(value)[1:-1])
        for name, value in messages.items():
            check_message(name, android_text(default_ui[name])[1:-1], android_text(value)[1:-1])
        root = ET.Element("resources")
        array = ET.SubElement(root, "string-array", name="client_error_messages")
        for code, message in sorted(errors.items()):
            ET.SubElement(array, "item").text = android_text(code + "=" + message)
        for name, value in sorted(messages.items()):
            ET.SubElement(root, "string", name=name).text = android_text(value)
        ET.indent(root, space="    ")
        dest = output / folder / "client_messages.xml"
        dest.parent.mkdir(parents=True, exist_ok=True)
        ET.ElementTree(root).write(dest, encoding="utf-8", xml_declaration=True)

if __name__ == "__main__":
    catalog, mapping, output, native_resources = map(Path, sys.argv[1:])
    keys = json.loads(mapping.read_text(encoding="utf-8"))
    check_native_resources(native_resources, keys)
    write_resources(catalog, keys, output)
