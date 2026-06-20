#!/usr/bin/env python3
"""Build (or extend) the Sparkle appcast for Engram.

Sparkle needs a single feed (appcast.xml) that lists every shippable build. We host that feed as an
asset on each GitHub Release, and the app's SUFeedURL points at
`releases/latest/download/appcast.xml`, so the newest release always serves the newest feed.

To keep history without storing any state in the repo, this script takes the PREVIOUS appcast
(downloaded from the latest release at build time) and prepends the new release's <item>. Every item
uses the PERMANENT per-tag download URL (`.../releases/download/v<x.y.z>/Engram-<x.y.z>.zip`), so old
versions keep resolving even after newer releases exist.

The EdDSA signature + byte length come from Sparkle's `sign_update` (run in the workflow); this script
never touches the private key.

Usage:
  make-appcast.py --version 0.1.0 --build 3 --min-os 14.0 \
                  --url https://github.com/.../releases/download/v0.1.0/Engram-0.1.0.zip \
                  --signature 'BASE64ED' --length 1234567 \
                  --pub-date 'Fri, 20 Jun 2026 12:00:00 +0000' \
                  [--notes '<p>What changed…</p>'] [--prev prev-appcast.xml] --out appcast.xml
"""

import argparse
import sys
from email.utils import formatdate
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
TITLE = "Engram"
LINK = "https://github.com/albertofettucini/Engram"


def parse_prev_items(path):
    """Return a list of item dicts from a previous appcast, or [] if absent/unreadable."""
    if not path:
        return []
    try:
        tree = ET.parse(path)
    except (ET.ParseError, FileNotFoundError, OSError) as e:
        print(f"make-appcast: no usable previous appcast ({e}); starting fresh", file=sys.stderr)
        return []
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        return []
    items = []
    for item in channel.findall("item"):
        enc = item.find("enclosure")
        if enc is None:
            continue
        version = enc.get(f"{{{SPARKLE_NS}}}shortVersionString") \
            or _text(item.find(f"{{{SPARKLE_NS}}}shortVersionString"))
        build = enc.get(f"{{{SPARKLE_NS}}}version") \
            or _text(item.find(f"{{{SPARKLE_NS}}}version"))
        min_os = enc.get(f"{{{SPARKLE_NS}}}minimumSystemVersion") \
            or _text(item.find(f"{{{SPARKLE_NS}}}minimumSystemVersion"))
        items.append({
            "title": _text(item.find("title")) or f"Version {version}",
            "pub_date": _text(item.find("pubDate")) or "",
            "version": version or "",
            "build": build or "",
            "min_os": min_os or "",
            "url": enc.get("url") or "",
            "signature": enc.get(f"{{{SPARKLE_NS}}}edSignature") or "",
            "length": enc.get("length") or "0",
            "notes": _inner_html(item.find("description")),
        })
    return items


def _text(el):
    return el.text.strip() if el is not None and el.text else ""


def _inner_html(el):
    """Preserve a <description> body (often CDATA HTML), or '' if none."""
    if el is None or not (el.text and el.text.strip()):
        return ""
    return el.text.strip()


def render_item(it):
    lines = ["  <item>"]
    lines.append(f"    <title>{escape(it['title'])}</title>")
    if it["pub_date"]:
        lines.append(f"    <pubDate>{escape(it['pub_date'])}</pubDate>")
    if it["notes"]:
        lines.append(f"    <description><![CDATA[{it['notes']}]]></description>")
    enc = (
        '    <enclosure '
        f'url={quoteattr(it["url"])} '
        f'sparkle:version={quoteattr(str(it["build"]))} '
        f'sparkle:shortVersionString={quoteattr(str(it["version"]))} '
    )
    if it["min_os"]:
        enc += f'sparkle:minimumSystemVersion={quoteattr(str(it["min_os"]))} '
    enc += (
        f'sparkle:edSignature={quoteattr(it["signature"])} '
        f'length={quoteattr(str(it["length"]))} '
        'type="application/octet-stream"/>'
    )
    lines.append(enc)
    lines.append("  </item>")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--min-os", default="")
    ap.add_argument("--url", required=True)
    ap.add_argument("--signature", required=True)
    ap.add_argument("--length", required=True)
    ap.add_argument("--pub-date", default=formatdate(localtime=False))  # RFC 822 / UTC
    ap.add_argument("--notes", default="")
    ap.add_argument("--prev", default="")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    new_item = {
        "title": f"Version {a.version}",
        "pub_date": a.pub_date,
        "version": a.version,
        "build": a.build,
        "min_os": a.min_os,
        "url": a.url,
        "signature": a.signature,
        "length": a.length,
        "notes": a.notes,
    }

    # Keep history; drop any prior item for the SAME short version so re-running a tag is idempotent.
    prev = [it for it in parse_prev_items(a.prev) if it["version"] != a.version]
    items = [new_item] + prev

    body = "\n".join(render_item(it) for it in items)
    doc = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        "  <channel>\n"
        f"    <title>{escape(TITLE)}</title>\n"
        f"    <link>{escape(LINK)}</link>\n"
        "    <description>Updates for Engram.</description>\n"
        "    <language>en</language>\n"
        f"{body}\n"
        "  </channel>\n"
        "</rss>\n"
    )

    with open(a.out, "w", encoding="utf-8") as f:
        f.write(doc)
    print(f"make-appcast: wrote {a.out} with {len(items)} item(s) (newest: {a.version} build {a.build})",
          file=sys.stderr)


if __name__ == "__main__":
    main()
