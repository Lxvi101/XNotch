#!/usr/bin/env python3
"""Create the release feed before Sparkle signs it. Never edit a signed feed."""
import datetime
import email.utils
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

archive, signature, destination = sys.argv[1:]
root = pathlib.Path(__file__).resolve().parent.parent
config = json.loads((root / "release.json").read_text())
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "XNotch Updates"
ET.SubElement(channel, "link").text = f"https://github.com/{config['repository']}"
ET.SubElement(channel, "description").text = "Signed XNotch releases for macOS."
ET.SubElement(channel, "language").text = "en"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"XNotch {config['version']}"
ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
ET.SubElement(item, f"{{{sparkle}}}version").text = config["build"]
ET.SubElement(item, f"{{{sparkle}}}shortVersionString").text = config["version"]
ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = "14.0"
notes = (root / "releases" / f"{config['version']}.md").read_text()
ET.SubElement(item, "description").text = notes
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/{config['repository']}/releases/download/v{config['version']}/{pathlib.Path(archive).name}",
    "length": str(pathlib.Path(archive).stat().st_size),
    "type": "application/octet-stream",
    f"{{{sparkle}}}edSignature": signature,
    f"{{{sparkle}}}os": "macos",
})
ET.indent(rss)
ET.ElementTree(rss).write(destination, encoding="utf-8", xml_declaration=True)
