#!/usr/bin/env python3
"""Validate the distributable bundle and feed before publishing or after download."""
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
config = json.loads((root / "release.json").read_text())
directory = pathlib.Path(sys.argv[1]).resolve()
archive = directory / f"XNotch-{config['version']}.zip"
disk_image = directory / f"XNotch-{config['version']}.dmg"
feed = ET.parse(directory / "appcast.xml")
item = feed.find("channel/item")
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
assert item is not None, "Missing appcast item"
assert item.findtext("sparkle:version", namespaces=ns) == config["build"]
assert item.findtext("sparkle:shortVersionString", namespaces=ns) == config["version"]
assert item.findtext("sparkle:minimumSystemVersion", namespaces=ns) == "14.0"
enclosure = item.find("enclosure")
assert enclosure is not None, "Missing archive"
assert enclosure.attrib["url"] == f"https://github.com/{config['repository']}/releases/download/v{config['version']}/{archive.name}"
assert int(enclosure.attrib["length"]) == archive.stat().st_size, "Archive length mismatch"
assert enclosure.attrib[f"{{{ns['sparkle']}}}edSignature"], "Missing signature"
with zipfile.ZipFile(archive) as bundle:
    assert all(name.startswith(("XNotch.app/", "__MACOSX/")) for name in bundle.namelist())
    info = plistlib.loads(bundle.read("XNotch.app/Contents/Info.plist"))
assert info["CFBundleIdentifier"] == "dev.levi.XNotch"
assert info["CFBundleShortVersionString"] == config["version"]
assert info["CFBundleVersion"] == config["build"]
assert info["CFBundleIconFile"] == "AppIcon"
assert info["SUPublicEDKey"] == config["sparklePublicKey"]
assert info["SUFeedURL"] == f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml"
for option in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate"):
    assert info[option] is True, f"Missing {option}"
with tempfile.TemporaryDirectory(prefix="xnotch-release-check-") as temporary:
    subprocess.run(["ditto", "-x", "-k", str(archive), temporary], check=True)
    app = pathlib.Path(temporary) / "XNotch.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    binaries = [app / "Contents/MacOS/XNotch", app / "Contents/Frameworks/libXNotchKit.dylib"]
    binaries += list((app / "Contents/PlugIns").glob("*.xnext/Contents/MacOS/*"))
    for binary in binaries:
        architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
        assert {"arm64", "x86_64"} <= set(architectures), f"Not universal: {binary}"
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "Licenses/Sparkle.txt", "Licenses/mediaremote-adapter.txt"):
        assert (app / "Contents/Resources" / name).is_file(), f"Missing license: {name}"
    assert (app / "Contents/Resources/AppIcon.icns").is_file(), "Missing app icon"
with tempfile.TemporaryDirectory(prefix="xnotch-dmg-check-") as mount:
    subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, str(disk_image)], check=True, stdout=subprocess.DEVNULL)
    try:
        volume = pathlib.Path(mount)
        assert (volume / "Applications").resolve() == pathlib.Path("/Applications"), "Missing Applications link"
        with open(volume / "XNotch.app/Contents/Info.plist", "rb") as plist:
            assert plistlib.load(plist)["CFBundleVersion"] == config["build"], "DMG holds a different build"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(volume / "XNotch.app")], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", mount], check=True, stdout=subprocess.DEVNULL)
tools = root / ".build/artifacts/sparkle/Sparkle/bin"
subprocess.run([str(tools / "sign_update"), "--account", config["sparkleKeyAccount"], "--verify", str(archive), enclosure.attrib[f"{{{ns['sparkle']}}}edSignature"]], check=True)
subprocess.run([str(tools / "sign_update"), "--account", config["sparkleKeyAccount"], "--verify", str(directory / "appcast.xml")], check=True)
print("Verified universal app, icon, DMG, nested code signatures, feed, update signature and licenses.")
