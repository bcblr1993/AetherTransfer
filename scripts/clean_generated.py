"""Remove only disposable Swift build products belonging to this checkout."""
from pathlib import Path
import shutil
import sys

if sys.argv[1:] != ["swift"]:
    raise SystemExit("Usage: python3 scripts/clean_generated.py swift")
root = Path(__file__).resolve().parent.parent
build = root / ".build"
if build.is_symlink():
    raise SystemExit("Refusing to clean a symlinked build directory")
for name in ("arm64-apple-macosx", "debug", "release", "build.db", "debug.yaml", "release.yaml", "workspace-state.json"):
    path = build / name
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)
print("Cleaned this checkout's disposable Swift products; fixtures and release artifacts retained.")
