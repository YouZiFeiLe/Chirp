#!/usr/bin/env python3
"""用 macOS 自带工具将图标母版导出为 Xcode 资源与独立 ICNS。"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "Client" / "Branding"
APPLE = ROOT / "Client" / "apple"
INFO = {"author": "xcode", "version": 1}


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def catalog(platform):
    root = APPLE / platform / "Assets.xcassets"
    icon = root / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    write_json(root / "Contents.json", {"info": INFO})
    return icon


def resize(source, target, size):
    run("/usr/bin/sips", "--resampleHeightWidth", str(size), str(size),
        str(source), "--out", str(target))


def main():
    ios_master = BRANDING / "chirp-ios-master.png"
    mac_master = BRANDING / "chirp-macos-master.png"
    for source in (ios_master, mac_master):
        if not source.is_file():
            raise SystemExit(f"缺少母版：{source}")

    ios = catalog("iOS")
    resize(ios_master, ios / "AppIcon-1024.png", 1024)
    write_json(ios / "Contents.json", {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": INFO,
    })

    mac = catalog("macOS")
    images = []
    with tempfile.TemporaryDirectory(prefix="chirp-icons-") as temp:
        iconset = Path(temp) / "Chirp.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                filename = f"icon_{size}x{size}{suffix}.png"
                resize(mac_master, mac / filename, size * scale)
                shutil.copyfile(mac / filename, iconset / filename)
                images.append({"filename": filename, "idiom": "mac",
                               "scale": f"{scale}x", "size": f"{size}x{size}"})
        run("/usr/bin/iconutil", "--convert", "icns", str(iconset),
            "--output", str(BRANDING / "Chirp-macOS.icns"))
    write_json(mac / "Contents.json", {"images": images, "info": INFO})
    print("已导出 iOS 1024px 图标、macOS 10 个尺寸槽位和 Chirp-macOS.icns。")


if __name__ == "__main__":
    main()
