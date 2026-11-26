import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import build_altstore_source as generator


def ipa(minimum="18.0"):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("Payload/EhViewer.app/Info.plist", plistlib.dumps(
            {"MinimumOSVersion": minimum}
        ))
    return buffer.getvalue()


def release(version):
    return {
        "tag_name": "v" + version,
        "published_at": "2026-11-26T00:00:00Z",
        "assets": [{
            "name": f"EhViewer-{version}.ipa",
            "browser_download_url": f"https://github.com/felixchaos/EhViewer-Apple/releases/download/v{version}/EhViewer-{version}.ipa",
            "size": 123,
        }],
    }


class AltStoreSourceTests(unittest.TestCase):
    def test_each_ipa_supplies_its_own_minimum(self):
        with patch.object(generator.urllib.request, "urlopen",
                          side_effect=[io.BytesIO(ipa("18.0")), io.BytesIO(ipa("26.2"))]):
            versions = generator.build_versions([release("1.3.7"), release("1.3.1")])
        self.assertEqual([row["minOSVersion"] for row in versions], ["18.0", "26.2"])

    def test_error_does_not_overwrite_the_existing_manifest(self):
        for failure in (OSError("network error"), io.BytesIO(b"invalid archive"),
                        io.BytesIO(ipa("invalid version"))):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                old = json.dumps({"apps": []})
                previous_directory = Path.cwd()
                try:
                    os.chdir(directory)
                    source = Path("source.json")
                    source.write_text(old, encoding="utf-8")
                    with (
                        patch.object(generator, "fetch_releases",
                                     return_value=[release("1.3.7"), release("1.3.1")]),
                        patch.object(generator.urllib.request, "urlopen",
                                     side_effect=[io.BytesIO(ipa()), failure]),
                        contextlib.redirect_stderr(io.StringIO()),
                    ):
                        self.assertEqual(generator.main(), 1)
                    self.assertEqual(source.read_text(encoding="utf-8"), old)
                finally:
                    os.chdir(previous_directory)


if __name__ == "__main__":
    unittest.main()
