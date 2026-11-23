"""Verify the legacy artifact before attaching it to the draft release."""

import hashlib
import plistlib
import sys
import zipfile
from pathlib import Path


def main():
    path = Path(sys.argv[1])
    expected = {
        "CFBundleIdentifier": "com.atebits.Tweetie2",
        "CFBundleShortVersionString": "10.79.2",
        "MinimumOSVersion": "15.0",
    }
    with zipfile.ZipFile(path) as ipa:
        if ipa.testzip() is not None:
            raise SystemExit("IPA failed its ZIP integrity check")
        app = "Payload/Twitter.app/"
        info = plistlib.loads(ipa.read(app + "Info.plist"))
        for key, value in expected.items():
            if info.get(key) != value:
                raise SystemExit(f"{key}: expected {value!r}, received {info.get(key)!r}")
        for member in ("Frameworks/BHTwitter.dylib", "Frameworks/zxPluginsInject.dylib",
                       "BHTwitter.bundle/Info.plist"):
            if ipa.getinfo(app + member).file_size == 0:
                raise SystemExit(f"Empty injected member: {member}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    print(f"{digest.hexdigest()}  {path.name}")


if __name__ == "__main__":
    main()
