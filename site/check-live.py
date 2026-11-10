#!/usr/bin/env python3
"""Verify that the deployed, crawlable site matches the locally validated build.

This checks publication and crawl access, not search-engine indexing or rankings.
Run after a successful GitHub Pages deployment: python3 site/check-live.py
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import runpy
import time
import urllib.error
import urllib.request
import urllib.robotparser


def main() -> None:
    site = Path(__file__).resolve().parent
    build = runpy.run_path(str(site / "build.py"))
    build["validate"]()
    outputs = build["outputs"]()
    build["validate_markup"](outputs)
    base = build["SITE_URL"]
    stamp = str(int(time.time()))

    def download(url: str):
        request = urllib.request.Request(url, headers={"User-Agent": "TrueScale-PublicationCheck/1.0"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if "noindex" in response.headers.get("X-Robots-Tag", "").lower():
                raise RuntimeError("Indexing blocked by response header: " + url)
            return response.read(), response.headers

    expected = {}
    for lang, info in build["LANGS"].items():
        expected[info["dir"]] = outputs[site / info["dir"] / "index.html"].encode()
    expected["sitemap.xml"] = outputs[site / "sitemap.xml"].encode()
    for name in ("site.css", "og-card.png", "icon-192.webp", "icon-384.webp",
                 "reading-coffee-8715935-bright.webp",
                 "reading-coffee-8715935-bright-640.webp"):
        expected["assets/" + name] = (site / "assets" / name).read_bytes()

    def check(item):
        relative, content = item
        received, headers = download(base + relative + "?verify=" + stamp)
        if hashlib.sha256(received).digest() != hashlib.sha256(content).digest():
            raise RuntimeError("Deployed content differs from validated local output: " + relative)
        if relative.endswith(".webp") and "image/webp" not in headers.get("Content-Type", ""):
            raise RuntimeError("Incorrect WebP Content-Type: " + relative)
        return relative or "/"

    with ThreadPoolExecutor(max_workers=4) as executor:
        for relative in executor.map(check, expected.items()):
            print("OK", relative)

    root = "https://leekaomin380.github.io/robots.txt"
    try:
        data, _ = download(root)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        print("INFO domain-root robots.txt: 404; no root rules to block crawling.")
    else:
        parser = urllib.robotparser.RobotFileParser(root)
        parser.parse(data.decode().splitlines())
        for info in build["LANGS"].values():
            if not parser.can_fetch("Googlebot", base + info["dir"]):
                raise RuntimeError("Domain-root robots.txt blocks Googlebot")
        print("OK domain-root robots.txt permits Googlebot")
    print("Publication verified. Search Console verification and index status are separate.")


if __name__ == "__main__":
    main()
