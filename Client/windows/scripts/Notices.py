"""Collect redistribution notices from the exact Go and NuGet packages in this build."""
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
LICENSE_NAMES = ("license", "licence", "notice", "copying", "third-party-notices", "thirdpartynotices")


def licenses(folder):
    return sorted(p for p in folder.iterdir() if p.is_file() and p.name.lower().startswith(LICENSE_NAMES))


def go_packages(modfile):
    modules = subprocess.check_output(["go", "list", "-modfile=" + str(modfile), "-deps", "-f",
        "{{if .Module}}{{.Module.Path}}|{{.Module.Version}}|{{.Module.Dir}}{{end}}", "./Client/windows/engine"],
        cwd=ROOT, text=True)
    for row in sorted(set(modules.splitlines()) - {""}):
        name, version, directory = row.split("|")
        if version:
            yield name + " " + version, licenses(Path(directory))
    goroot = Path(subprocess.check_output(["go", "env", "GOROOT"], text=True).strip())
    yield "Go standard library", licenses(goroot)


def dotnet_packages(assets):
    data = json.loads(assets.read_text(encoding="utf-8-sig"))
    roots = [Path(p) for p in data["packageFolders"]]
    packages = {name: lib["path"] for name, lib in data["libraries"].items()
                if lib["type"] == "package" and ".BuildTools" not in name}
    for framework in data["project"]["frameworks"].values():
        for dep in framework.get("downloadDependencies", []):
            if dep["name"] == "Microsoft.NETCore.App.Runtime.win-x64":
                version = dep["version"].strip("[]").split(",")[0].strip()
                key = dep["name"] + "/" + version
                packages[key] = key.lower()
    for name, relative in sorted(packages.items()):
        folder = next(root / relative for root in roots if (root / relative).is_dir())
        files = licenses(folder)
        if name.startswith("NAudio."):
            files.append(ROOT / "Client/windows/Licenses/NAudio.txt")
        if name.startswith("ZXing.Net/"):
            files.append(ROOT / "Client/apple/MLS/Licenses/Apache-2.0.txt")
        yield name, files


def write(packages, target):
    texts, lines = {}, []
    for name, files in packages:
        lines.append(name)
        for path in files:
            data = path.read_bytes()
            encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
            content = data.decode(encoding, errors="replace").replace("\r\n", "\n").strip()
            digest = sha256(content.encode()).hexdigest()[:16]
            texts[digest] = content
            lines.append(f"  {path.name}: {digest}")
    for digest, content in sorted(texts.items()):
        lines.extend(["", "=" * 72, digest, "", content])
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    mode, source, out = sys.argv[1:]
    packages = {"go": go_packages, "dotnet": dotnet_packages}[mode]
    write(packages(Path(source)), Path(out))
