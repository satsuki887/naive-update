#!/usr/bin/env python3
"""Discover a public upstream server release; skip complete existing releases."""
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from naive_update import OWN_REPOSITORY, release_tag  # noqa: E402


def main():
    upstream = release_tag(os.environ.get("REQUESTED_RELEASE", "") or "latest")
    tag = "server-" + upstream
    req = urllib.request.Request(
        f"https://api.github.com/repos/{OWN_REPOSITORY}/releases/tags/{tag}",
        headers={"User-Agent": "naive-update-ci", "Authorization": "Bearer " + os.environ["GH_TOKEN"]})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            existing = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            raise
        existing = {}
    needed = {f"naive-server-{upstream}-linux-{arch}.tar.gz" for arch in ("amd64", "arm64")}
    needed.add("SHA256SUMS")
    complete = not existing.get("draft", True) and needed <= {a["name"] for a in existing.get("assets", [])}
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"upstream={upstream}\ntag={tag}\nneeded={'false' if complete else 'true'}\n")
    print(f"Official server: {upstream}; {'already published' if complete else 'build required'}")


if __name__ == "__main__":
    main()
