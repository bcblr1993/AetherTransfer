"""Check source translation coverage and, optionally, a built app's resources."""
import argparse
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("app", nargs="?", type=Path)
parser.add_argument("--resource-bundle", type=Path)
args = parser.parse_args()


def table(path):
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                            check=True, capture_output=True, text=True)
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
        raise RuntimeError(f"Invalid translation table: {path.name}")
    return value


def verify(resources):
    english = table(resources / "en.lproj/Localizable.strings")
    chinese = table(resources / "zh-Hans.lproj/Localizable.strings")
    if english.keys() != chinese.keys():
        raise RuntimeError("Chinese and English translation keys differ")
    for key, value in english.items():
        if not value or chinese[key] != key or key.count("%@") != value.count("%@"):
            raise RuntimeError(f"Invalid translation or interpolation: {key}")
    return english


source = verify(root / "Sources/AetherTransferCore/Resources")
calls = 0
for path in (root / "Sources").rglob("*.swift"):
    for match in re.finditer(r'L10n\.(?:text|format)\(("(?:\\.|[^"\\])*")', path.read_text()):
        key = json.loads(match.group(1))
        if key not in source:
            raise RuntimeError(f"Missing translation in {path.name}: {key}")
        calls += 1

bundle = args.resource_bundle
if args.app:
    bundle = args.app / "Contents/Resources/AetherTransfer_AetherTransferCore.bundle"
    info = json.loads(subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(args.app / "Contents/Info.plist")],
        check=True, capture_output=True, text=True).stdout)
    if set(info.get("CFBundleLocalizations", [])) != {"en", "zh-Hans"}:
        raise RuntimeError("The app does not declare both display languages")
if bundle:
    built = verify(bundle / "Contents/Resources")
    if built != source:
        raise RuntimeError("The built English resource table differs from source")
print(f"Localization verified: {len(source)} keys per language, {calls} static calls" +
      (", built resources match" if bundle else ""))
