#!/usr/bin/env python3
"""Check a rendered Pages site for missing local links and search metadata."""

import json
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit


SITE_URL = "https://davelindo.github.io/videotoolbox_remote/"
BASE_PATH = urlsplit(SITE_URL).path


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []
        self.h1_count = 0
        self.title = ""
        self.description = ""
        self.canonical = ""
        self.structured_data = []
        self.in_title = False
        self.in_json = False
        self.json_text = ""
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "h1":
            self.h1_count += 1
        if tag == "title":
            self.in_title = True
        if tag == "meta" and attrs.get("name") == "description":
            self.description = attrs.get("content", "")
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonical = attrs.get("href", "")
        for attribute in ("href", "src"):
            if attrs.get(attribute):
                self.links.append(attrs[attribute])
        if tag == "script" and attrs.get("type") == "application/ld+json":
            self.in_json = True
            self.json_text = ""

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
        if tag == "script" and self.in_json:
            self.in_json = False
            self.structured_data.append(self.json_text)

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if self.in_json:
            self.json_text += data


def check_site(root):
    pages = {}
    for file in root.rglob("*.html"):
        source = file.read_text()
        if source.strip() == f"google-site-verification: {file.name}":
            continue
        pages[file.relative_to(root).as_posix()] = Page(source)
    errors = []
    if not pages:
        return ["No rendered HTML pages found"]
    for path, page in sorted(pages.items()):
        page_url = urljoin(SITE_URL, path.removesuffix("index.html"))
        if page.h1_count != 1:
            errors.append(f"{path}: expected one h1, got {page.h1_count}")
        if not page.title.strip() or not page.description.strip():
            errors.append(f"{path}: missing title or description")
        if page.canonical != page_url:
            errors.append(f"{path}: incorrect canonical URL {page.canonical!r}")
        if not page.structured_data:
            errors.append(f"{path}: missing structured data")
        for block in page.structured_data:
            try:
                json.loads(block)
            except ValueError as error:
                errors.append(f"{path}: invalid JSON-LD: {error}")
        for link in page.links:
            target = urlsplit(urljoin(page_url, link))
            if target.netloc != urlsplit(SITE_URL).netloc:
                continue
            if not target.path.startswith(BASE_PATH):
                errors.append(f"{path}: link leaves Pages base path: {link}")
                continue
            local = unquote(target.path[len(BASE_PATH):]) or "index.html"
            if local.endswith("/"):
                local += "index.html"
            if not (root / local).is_file():
                errors.append(f"{path}: missing local target: {link}")
            elif target.fragment and local in pages:
                if unquote(target.fragment) not in pages[local].ids:
                    errors.append(f"{path}: missing anchor: {link}")
    return errors


if __name__ == "__main__":
    site_root = Path(sys.argv[1] if len(sys.argv) > 1 else "_site")
    failures = check_site(site_root)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print(f"Rendered documentation links and metadata pass: {site_root}")
