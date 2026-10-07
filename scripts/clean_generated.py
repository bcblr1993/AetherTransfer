"""Remove only known AetherTransfer-generated artifacts before another run."""
import argparse
from pathlib import Path
import shutil

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("scope", choices=["swift", "app", "runtime", "all"])
args = parser.parse_args()

def remove(relative):
    target = root / relative
    # Never follow a replaced parent into a user directory.
    if any(parent.is_symlink() for parent in target.parents if parent != root and root in parent.parents):
        raise RuntimeError(f"Refusing symlink parent: {relative}")
    if target.is_symlink() or target.is_file():
        target.unlink()
    elif target.is_dir():
        shutil.rmtree(target)

swift_paths = [".build/out", ".build/arm64-apple-macosx", ".build/debug", ".build/release",
               ".build/build.db", ".build/debug.yaml", ".build/release.yaml", ".build/manifest.pif"]
if args.scope != "runtime":
    for relative in swift_paths:
        remove(relative)
if args.scope in ("runtime", "all"):
    remove(".build/protocol-source/curl-8.22.0")
if args.scope in ("app", "all"):
    for relative in ["outputs/AetherTransfer.app", ".build/AppIcon.iconset"]:
        remove(relative)
if args.scope == "all":
    for relative in ["reports/ui-animation.trace", "reports/performance-files", "reports/ui-source",
                     "reports/ui-download", "reports/native-ui-download", "reports/fixture.json",
                     "reports/sync-ui-left", "reports/sync-ui-right", "reports/sync-ui-large",
                     "reports/webdav-ui-source", "reports/webdav-ui-download",
                     ".build/curl-source", ".build/curl-8.22.0.tar.xz",
                     ".build/site-checkout/node_modules", ".build/site-checkout/dist", ".build/site-checkout/.astro"]:
        remove(relative)
    for path in (root / ".build").glob("*.log"):
        remove(path.relative_to(root))
print(f"Cleaned previous generated artifacts ({args.scope}); source, Git and fixed dependency runtime retained.")
