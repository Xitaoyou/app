"""Register the optional Google OAuth callback in the side-load build input."""

import os
import pathlib
import plistlib
import re


def main():
    client = os.environ.get("NFB_DRIVE_IOS_CLIENT_ID", "").strip()
    if not client:
        return
    if not re.fullmatch(r"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client):
        raise SystemExit("NFB_DRIVE_IOS_CLIENT_ID must be a Google iOS OAuth client ID.")

    path = pathlib.Path("main/tmp/Payload/Twitter.app/Info.plist")
    document = plistlib.loads(path.read_bytes())
    registered_bundle = os.environ.get("NFB_DRIVE_IOS_BUNDLE_ID", "").strip()
    if registered_bundle != document["CFBundleIdentifier"]:
        raise SystemExit("NFB_DRIVE_IOS_BUNDLE_ID must match the app's installed bundle ID.")
    scheme = ".".join(reversed(client.split(".")))
    entries = document.setdefault("CFBundleURLTypes", [])
    if not any(scheme in entry.get("CFBundleURLSchemes", []) for entry in entries):
        entries.append({"CFBundleURLName": "NeoFreeBird Drive", "CFBundleURLSchemes": [scheme]})
    document["NFBDriveClientID"] = client
    document["NFBDriveBundleID"] = registered_bundle
    path.write_bytes(plistlib.dumps(document, fmt=plistlib.FMT_BINARY, sort_keys=False))


if __name__ == "__main__":
    main()
