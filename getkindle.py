#!/usr/bin/env python3
"""Download the Google Play build of the Kindle app (arm64-v8a) from APKMirror.

    getkindle.py OUT.apk   ->  saves the newest 8.x Play build as OUT.apk, prints its version

Amazon publishes Kindle for ordinary Android only through Google Play. APKMirror mirrors those
Play builds (and Amazon's 14.x Fire tablet builds, which ordinary Android can't install, so they
are skipped). This only fetches: the caller checks the file with `apkcert.py --kindle` (Amazon's
certificate, Play build) and Android verifies its signatures when installing it.
Exit 0 on success, 1 if nothing could be downloaded. Standard library only.
"""
import html
import http.cookiejar
import os
import re
import sys
import urllib.request

BASE = "https://www.apkmirror.com"
APP = "/apk/amazon-mobile-llc/amazon-kindle/"
LISTING = BASE + "/uploads/?appcategory=amazon-kindle"
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
TRIES = 3  # releases to try, newest first

opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def fetch(url, referer=None):
    headers = {"User-Agent": UA, "Accept-Language": "en-US,en;q=0.8"}
    if referer:
        headers["Referer"] = referer
    return opener.open(urllib.request.Request(url, headers=headers), timeout=60)


def page(url, referer=None):
    with fetch(url, referer) as r:
        return r.read().decode("utf-8", "replace")


def releases():
    """Release page paths, newest first, without the Fire builds (major version 14)."""
    found = {}
    for path, slug in re.findall(r'href="(' + re.escape(APP) + r'[^"]*?-(\d+-\d+-[0-9-]+?)-release/)"', page(LISTING)):
        version = [int(x) for x in slug.split("-") if x]
        if version[0] < 14:
            found[path] = version
    return sorted(found, key=found.get, reverse=True)


def arm64_variant(release_path):
    """(the release's version, its arm64-v8a APK variant page or None; never a split bundle)."""
    text = page(BASE + release_path)
    m = re.search(r"<h1[^>]*>(.*?)</h1>", text, re.S)
    v = re.search(r"\d+\.\d+\.\d+\.\d+", m.group(1)) if m else None
    version = v.group(0) if v else release_path.rstrip("/").rsplit("/", 1)[-1]
    links = list(re.finditer(r'href="(' + re.escape(release_path) + r'[^"]*-android-apk-download/)"', text))
    for i, m in enumerate(links):
        end = links[i + 1].start() if i + 1 < len(links) else m.end() + 3000
        row = re.sub(r"<[^>]+>", " ", text[m.end():end])
        if "arm64-v8a" in row and "BUNDLE" not in row:
            return version, m.group(1)
    return version, None


def download(variant_path, out):
    variant_url = BASE + variant_path
    m = re.search(r'href="([^"]*/download/\?key=[^"]+)"', page(variant_url))
    if not m:
        raise RuntimeError("no download page link")
    download_url = BASE + html.unescape(m.group(1))
    m = re.search(r'href="([^"]*download\.php\?id=[^"]+)"', page(download_url, variant_url))
    if not m:
        raise RuntimeError("no file link")
    part = out + ".part"
    with fetch(BASE + html.unescape(m.group(1)), download_url) as r, open(part, "wb") as f:
        kind = r.headers.get("Content-Type", "")
        if "android.package-archive" not in kind and "octet-stream" not in kind:
            raise RuntimeError(f"unexpected file type {kind!r}")
        while chunk := r.read(1 << 20):
            f.write(chunk)
    os.replace(part, out)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    try:
        candidates = releases()[:TRIES]
    except OSError as e:
        print(f"getkindle: can't reach APKMirror: {e}", file=sys.stderr)
        sys.exit(1)
    for release in candidates:
        version = release.rstrip("/").rsplit("/", 1)[-1].removesuffix("-release")
        try:
            version, variant = arm64_variant(release)
            if not variant:
                continue
            download(variant, out)
            print(version)
            return
        except (OSError, RuntimeError) as e:
            print(f"getkindle: {version}: {e}", file=sys.stderr)
    print("getkindle: no Kindle download found on APKMirror", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
