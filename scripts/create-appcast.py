#!/usr/bin/env python3
"""Sign a release ZIP and write Sparkle's update feed beside it."""
import datetime
from email.utils import format_datetime
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

if len(sys.argv) != 3:
    raise SystemExit("Usage: create-appcast.py APP ZIP")
app, archive = map(Path, sys.argv[1:])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
build = info["CFBundleVersion"]
signer = Path(__file__).resolve().parents[1] / ".build/swift-packages/artifacts/sparkle/Sparkle/bin/sign_update"
signature = subprocess.check_output([str(signer), "--account", "com.notchharbor.app", "-p", str(archive)], text=True).strip()
subprocess.run([str(signer), "--account", "com.notchharbor.app", "--verify", str(archive), signature], check=True)
ET.register_namespace("sparkle", "http://www.andymatuschak.org/xml-namespaces/sparkle")
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Notch Harbor"
ET.SubElement(channel, "link").text = "https://github.com/RUIAN12138/NotchHarbor/releases"
ET.SubElement(channel, "description").text = "Notch Harbor updates"
ET.SubElement(channel, "language").text = "zh-CN"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Notch Harbor {version}"
ET.SubElement(item, ns + "version").text = str(build)
ET.SubElement(item, ns + "shortVersionString").text = version
ET.SubElement(item, ns + "minimumSystemVersion").text = "14.0.0"
ET.SubElement(item, "pubDate").text = format_datetime(datetime.datetime.now(datetime.timezone.utc))
ET.SubElement(item, "link").text = f"https://github.com/RUIAN12138/NotchHarbor/releases/tag/v{version}"
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/RUIAN12138/NotchHarbor/releases/download/v{version}/{archive.name}",
    ns + "edSignature": signature,
    "length": str(archive.stat().st_size),
    "type": "application/octet-stream",
})
ET.indent(rss)
ET.ElementTree(rss).write(archive.parent / "appcast.xml", encoding="utf-8", xml_declaration=True)
