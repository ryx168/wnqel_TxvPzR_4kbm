"""Refuse to publish an export whose pages point at assets that are not there.

This exists because of a real failure: wget's --adjust-extension saves
"main.css?ver=9" on disk as "main.css?ver=9.css" and --convert-links rewrites
the pages that reference it to the percent-encoded "main.css%3Fver=9.css".
The first page crawled keeps absolute URLs, so the homepage rendered perfectly
while every recovered inner page loaded no CSS at all.

Page counts, a text diff and even counting stylesheet <link> tags all reported
that export as healthy - the links were present, they simply pointed nowhere.
The only invariant that catches it is that every referenced file must exist.
"""
import os
import posixpath
import re
import sys
import urllib.parse

REF = re.compile(r"""(?:href|src)\s*=\s*["']([^"']+)["']""")
SKIP = ("data:", "mailto:", "tel:", "javascript:", "//")
LOCAL = ("/wp-content/", "/wp-includes/")


def referenced_path(page_dir, out, url):
    """Site-absolute path for a reference, or None if it is not ours to check."""
    url = url.split("#")[0]
    if not url or url.startswith(SKIP):
        return None
    if url.startswith("http"):
        parts = urllib.parse.urlparse(url)
        # The bare apex is this site too. Missing that meant a stylesheet linked
        # as https://<apex>/... was written off as somebody else's URL and never
        # checked - which is how one file slipped through onto the live site.
        if parts.netloc not in (HOST, APEX):
            return None
        return parts.path
    if url.startswith("/"):
        return url.split("?")[0]
    rel = os.path.relpath(page_dir, out).replace(os.sep, "/")
    base = "/" if rel == "." else "/" + rel + "/"
    return posixpath.normpath(base + url.split("?")[0])


out, HOST = sys.argv[1], sys.argv[2]
APEX = HOST[4:] if HOST.startswith("www.") else HOST
LIST_ONLY = "--list" in sys.argv[3:]
bad = {}
missing_paths = set()
for root, _, files in os.walk(out):
    for name in files:
        if not name.endswith(".html"):
            continue
        page = os.path.join(root, name)
        with open(page, encoding="utf-8", errors="replace") as fh:
            html = fh.read()
        for raw in REF.findall(html):
            path = referenced_path(root, out, raw)
            if path is None or not path.startswith(LOCAL):
                continue
            # A surviving %3F means the reference points at a query-mangled
            # filename - the exact bug this check exists to catch.
            target = os.path.join(out, urllib.parse.unquote(path).lstrip("/"))
            if "%3F" in path or not os.path.isfile(target):
                bad.setdefault(os.path.relpath(page, out), []).append(raw)
                missing_paths.add(urllib.parse.unquote(path))

if LIST_ONLY:
    # Just name the missing site-absolute paths, one per line, and exit 0 so a
    # recovery step can act on them before the real check runs.
    for path in sorted(missing_paths):
        print(path)
    sys.exit(0)

if bad:
    print("REFUSING to publish: pages reference assets that are not in the export")
    for page, refs in sorted(bad.items())[:6]:
        print("    %s -> %d missing, e.g. %s" % (page, len(refs), refs[0][:88]))
    sys.exit(1)
print("  asset check: every local asset reference resolves to an exported file")
