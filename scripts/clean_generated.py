"""Remove only known AetherTransfer-generated artifacts before another run."""
import argparse
import os
from pathlib import Path
import shutil

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("scope", choices=["swift", "app", "runtime", "s3", "fixtures", "website", "all"])
args = parser.parse_args()

def remove(relative):
    target = root / relative
    # Never follow a replaced parent into a user directory.
    if any(parent.is_symlink() for parent in target.parents if parent != root and root in parent.parents):
        raise RuntimeError(f"Refusing symlink parent: {relative}")
    if target.is_symlink() or target.is_file():
        target.unlink()
    elif target.is_dir():
        if str(relative) == ".build/s3-fixture-build":
            # Go's module cache can contain read-only directories. Only this owned
            # transient cache is made writable; no symlink targets are followed.
            for directory, children, _ in os.walk(target, followlinks=False):
                children[:] = [name for name in children if not (Path(directory) / name).is_symlink()]
                if not Path(directory).is_symlink():
                    Path(directory).chmod(0o700)
        shutil.rmtree(target)

swift_paths = [".build/out", ".build/arm64-apple-macosx", ".build/debug", ".build/release",
               ".build/build.db", ".build/debug.yaml", ".build/release.yaml", ".build/manifest.pif"]
if args.scope in ("swift", "app", "all"):
    for relative in swift_paths:
        remove(relative)
if args.scope in ("runtime", "all"):
    remove(".build/protocol-source/curl-8.22.0")
if args.scope in ("s3", "fixtures", "runtime", "all"):
    remove(".build/s3-fixture-build")
if args.scope in ("fixtures", "all"):
    remove(".build/s3-fixture")
    remove("reports/s3-ui-files")
if args.scope in ("app", "all"):
    for relative in ["outputs/AetherTransfer.app", ".build/AppIcon.iconset"]:
        remove(relative)
if args.scope in ("website", "all"):
    for relative in [".build/site-checkout/node_modules", ".build/site-checkout/dist", ".build/site-checkout/.astro",
                     ".build/site-npm-cache"]:
        remove(relative)
if args.scope == "all":
    for relative in ["reports/ui-animation.trace", "reports/performance-files", "reports/ui-source",
                     "reports/ui-download", "reports/native-ui-download", "reports/fixture.json",
                     "reports/sync-ui-left", "reports/sync-ui-right", "reports/sync-ui-large",
                     "reports/webdav-ui-source", "reports/webdav-ui-download",
                     "reports/editor-ui-files", "reports/editor-fixture-port.json",
                     "reports/resume-ui-files", "reports/editor-cancel-ui",
                     "reports/rate-ui-download", "reports/rate-ui-retry",
                     "reports/tree-ui-download", "reports/tree-ui-source.json",
                     "reports/preview-ui-files", "reports/preview-ui-source.json",
                     "reports/cache-ui-source.json",
                     "reports/icons-ui-files", "reports/icons-ui-source.json",
                     "reports/drop-ui-files", "reports/drop-ui-source.json",
                     ".build/curl-source", ".build/curl-8.22.0.tar.xz"]:
        remove(relative)
    for path in (root / ".build").glob("*.log"):
        remove(path.relative_to(root))
print(f"Cleaned previous generated artifacts ({args.scope}); source, Git and fixed dependency runtime retained.")
