"""Owned, case-sensitive storage for the test-only S3 server; never a user volume."""
from contextlib import contextmanager
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys


def is_case_sensitive(directory: Path) -> bool:
    lower, upper = directory / '.case-probe', directory / '.CASE-PROBE'
    try:
        lower.write_bytes(b'lower'); upper.write_bytes(b'upper')
        return lower.stat().st_ino != upper.stat().st_ino
    finally:
        lower.unlink(missing_ok=True); upper.unlink(missing_ok=True)


@contextmanager
def case_sensitive_storage(root: Path):
    data = root / 'data'; data.mkdir()
    if is_case_sensitive(data):
        yield data
        return
    if sys.platform != 'darwin':
        raise RuntimeError('The real S3 fixture requires case-sensitive storage')
    # S3 keys are case-sensitive. A normal macOS temp volume can alias two keys.
    # Use one bounded sparse image in the existing owned TemporaryDirectory.
    image = root / 's3-storage.sparseimage'
    mount = root / 's3-volume'; mount.mkdir()
    subprocess.run(['hdiutil', 'create', '-size', '512m', '-type', 'SPARSE', '-fs', 'Case-sensitive APFS', '-nospotlight',
                    '-volname', 'AetherS3Fixture-' + secrets.token_hex(4), str(image)],
                   check=True, capture_output=True, timeout=60)
    attachment = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-nobrowse', '-noautoopen',
        '-mountpoint', str(mount), '-plist', str(image)], timeout=60))
    entities = attachment['system-entities']
    # hdiutil canonicalizes /var to /private/var on macOS. Keep a detach handle
    # even if a mount-path validation fails after the image was attached.
    device = next(entry['dev-entry'] for entry in entities if entry.get('dev-entry'))
    try:
        if not any(entry.get('mount-point') and Path(entry['mount-point']).resolve() == mount.resolve() for entry in entities):
            raise RuntimeError('The isolated S3 image mounted at an unexpected location')
        (mount / '.metadata_never_index').touch()
        private_data = mount / 'data'; private_data.mkdir()
        if not is_case_sensitive(private_data):
            raise RuntimeError('The isolated S3 image did not provide case-sensitive storage')
        print('S3 fixture uses one private case-sensitive sparse volume (512 MiB maximum).', flush=True)
        yield private_data
    finally:
        try:
            result = subprocess.run(['hdiutil', 'detach', device], capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            result = None
        if result is None or result.returncode != 0:
            # Only the device returned by attaching our own image may be forced.
            subprocess.run(['hdiutil', 'detach', '-force', device], check=True, capture_output=True, timeout=30)
        print('Owned S3 fixture volume detached; its backing file is removed by TemporaryDirectory.', flush=True)
