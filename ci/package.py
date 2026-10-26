#!/usr/bin/env python3
"""Create a small server bundle; never include local configuration or caches."""
import argparse
from pathlib import Path
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from naive_update import sha256, verify_artifact  # noqa: E402


def package(source, destination):
    _, info = verify_artifact(source)
    if info.get("goarch") not in ("amd64", "arm64"):
        raise ValueError("Unsupported release architecture")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    name = f"naive-server-{info['release']}-linux-{info['goarch']}.tar.gz"
    path = destination / name
    with tarfile.open(path, "w:gz") as archive:
        for item in ("caddy", "build.json", "build-info.txt", "SHA256SUMS", "LICENSES.txt"):
            source_file = Path(source) / item
            if source_file.is_symlink() or not source_file.is_file():
                raise ValueError("Missing or linked bundle member: " + item)
            record = archive.gettarinfo(str(source_file), arcname=item)
            record.uid = record.gid = 0
            record.uname = record.gname = "root"
            record.mode = 0o755 if item == "caddy" else 0o644
            with open(source_file, "rb") as stream:
                archive.addfile(record, stream)
    (destination / (name + ".sha256")).write_text(sha256(path) + "  " + name + "\n", encoding="ascii")
    print(path)
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    package(args.source, args.destination)
