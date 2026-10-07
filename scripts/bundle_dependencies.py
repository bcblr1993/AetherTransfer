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
