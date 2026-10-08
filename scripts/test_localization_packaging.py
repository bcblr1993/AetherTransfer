"""Regression checks for SwiftPM's two macOS resource bundle layouts."""
from pathlib import Path
import shutil
import tempfile
import unittest
from verify_localizations import resource_directory, verify

source = Path(__file__).resolve().parent.parent / "Sources/AetherTransferCore/Resources"


class LocalizationPackagingTests(unittest.TestCase):
    def test_flat_and_contents_bundles_preserve_both_languages(self):
        with tempfile.TemporaryDirectory(prefix="aethertransfer-localization-") as folder:
            for relative in ("", "Contents/Resources"):
                bundle = Path(folder) / ("flat.bundle" if not relative else "contents.bundle")
                resources = bundle / relative
                shutil.copytree(source, resources)
                self.assertEqual(resource_directory(bundle), resources)
                self.assertEqual(verify(resources)["连接服务器"], "Connect to Server")

    def test_missing_language_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="aethertransfer-localization-") as folder:
            bundle = Path(folder)
            shutil.copytree(source / "en.lproj", bundle / "en.lproj")
            with self.assertRaises(RuntimeError):
                resource_directory(bundle)

    def test_ambiguous_layout_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="aethertransfer-localization-") as folder:
            bundle = Path(folder) / "ambiguous.bundle"
            shutil.copytree(source, bundle)
            shutil.copytree(source, bundle / "Contents/Resources")
            with self.assertRaises(RuntimeError):
                resource_directory(bundle)

    def test_invalid_placeholder_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="aethertransfer-localization-") as folder:
            resources = Path(folder) / "Resources"
            shutil.copytree(source, resources)
            english = resources / "en.lproj/Localizable.strings"
            english.write_text(english.read_text().replace('"取消" = "Cancel";', '"取消" = "%@";'))
            with self.assertRaises(RuntimeError):
                verify(resources)


if __name__ == "__main__":
    unittest.main()
