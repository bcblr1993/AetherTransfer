"""Embed the actual non-system dylib closure and remove Homebrew runtime paths."""
import pathlib
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
frameworks = app / "Contents/Frameworks"
pending = [(app / "Contents/MacOS/AetherTransfer", app / "Contents/MacOS/AetherTransfer")]
visited = set()
origins = {}
licenses = app / "Contents/Resources/Licenses"
licenses.mkdir(parents=True, exist_ok=True)
shutil.copy2("LICENSE", licenses / "AetherTransfer-MIT.txt")
shutil.copy2("THIRD_PARTY_NOTICES.md", licenses / "THIRD_PARTY_NOTICES.md")
shutil.copy2("resources/licenses/librtmp-LGPL-2.1.txt", licenses / "librtmp-LGPL-2.1.txt")
shutil.copy2("resources/licenses/Mozilla-MPL-2.0.txt", licenses / "Mozilla-MPL-2.0.txt")
licensed_roots = set()
while pending:
    binary, source = pending.pop()
    if binary in visited:
        continue
    visited.add(binary)
    lines = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    changes = []
    for line in lines:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith("@rpath/"):
            candidate = source.parent / dependency.removeprefix("@rpath/")
            if candidate.exists():
                resolved_dependency = str(candidate)
            else:
                raise RuntimeError(f"Unresolved rpath dependency: {dependency} in {source}")
        elif dependency.startswith("@loader_path/"):
            resolved_dependency = str(source.parent / dependency.removeprefix("@loader_path/"))
        else:
            resolved_dependency = dependency
        if not resolved_dependency.startswith(("/opt/homebrew/", "/usr/local/")):
            continue
        original = pathlib.Path(resolved_dependency).resolve()
        if not original.is_file():
            raise RuntimeError(f"Missing dependency: {dependency}")
        # Homebrew Cellar paths identify the exact package owning each dylib.
        root = next((parent for parent in original.parents if (parent / "INSTALL_RECEIPT.json").is_file()), None)
        if root is None:
            raise RuntimeError(f"Cannot identify dependency license: {original.name}")
        if root not in licensed_roots:
            texts = [p for p in root.iterdir() if p.is_file() and p.name.upper().startswith(("COPYING", "LICENSE", "COPYRIGHT"))]
            if not texts:
                raise RuntimeError(f"Missing license text for {root.parent.name}")
            destination = licenses / root.parent.name
            destination.mkdir(exist_ok=True)
            for text in texts:
                shutil.copy2(text, destination / text.name)
            for formula in (root / ".brew").glob("*.rb"):
                shutil.copy2(formula, destination / formula.name)
            licensed_roots.add(root)
        target = frameworks / original.name
        if target.name in origins and origins[target.name] != original:
            raise RuntimeError(f"Dependency name collision: {target.name}")
        if target.name not in origins:
            origins[target.name] = original
            shutil.copy2(original, target)
            target.chmod(0o755)
            subprocess.run(["install_name_tool", "-id", f"@executable_path/../Frameworks/{target.name}", str(target)], check=True)
        pending.append((target, original))
        changes += ["-change", dependency, f"@executable_path/../Frameworks/{target.name}"]
    if changes:
        subprocess.run(["install_name_tool", *changes, str(binary)], check=True)
for dylib in frameworks.glob("*.dylib"):
    subprocess.run(["codesign", "--force", "--sign", "-", str(dylib)], check=True)
for binary in visited:
    linked = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    if "/opt/homebrew/" in linked or "/usr/local/" in linked or "@rpath/" in linked or "@loader_path/" in linked:
        raise RuntimeError(f"Unbundled dependency in {binary.name}")
