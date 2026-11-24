#!/usr/bin/env python3
"""Seal, verify and restore a stopped booth's copied persistent container for offline review."""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path

BUNDLE = "com.pocketpixels.PocketPixelsBooth"
PERSISTENT = ("Documents", "Library/Application Support", "Library/Preferences")


def digest(path):
    with path.open("rb") as stream:
        hashed = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hashed.update(block)
        return hashed.hexdigest()


def inventory(container):
    if not container.is_dir() or container.is_symlink():
        raise ValueError("Expected a real container directory")
    files, directories = {}, []
    for path in sorted(container.rglob("*")):
        relative = path.relative_to(container).as_posix()
        if path.is_symlink():
            raise ValueError("Snapshot contains a symbolic link")
        if relative == "Library" or any(
            relative == root or relative.startswith(root + "/") for root in PERSISTENT
        ):
            if path.is_dir():
                directories.append(relative)
            elif path.is_file():
                files[relative] = {"bytes": path.stat().st_size, "sha256": digest(path)}
            else:
                raise ValueError("Snapshot contains a special file")
        else:
            raise ValueError("Snapshot contains data outside supported persistent paths")
    if "Library/Preferences" not in directories or "Library/Application Support" not in directories:
        raise ValueError("Both preferences and Application Support directories are required")
    return {"format": 1, "bundle": BUNDLE, "directories": directories, "files": files}


def verify(backup):
    expected = json.loads((backup / "manifest.json").read_text())
    actual = inventory(backup / "container")
    if expected != actual:
        raise ValueError("Snapshot inventory or checksum differs from manifest")
    return actual


def seal(backup):
    observed = inventory(backup / "container")
    with (backup / "manifest.json").open("x") as stream:
        json.dump(observed, stream, indent=2)
        stream.write("\n")
    return verify(backup)


def restore(backup, destination):
    expected = verify(backup)
    if destination.resolve().is_relative_to(backup.resolve()):
        raise ValueError("Restore location must be outside the backup")
    destination.mkdir(mode=0o700)
    # An isolated review directory only. Never write directly into an app or simulator container.
    (destination / "OFFLINE_REVIEW_ONLY").touch(exist_ok=False)
    restored = destination / "container"
    shutil.copytree(backup / "container", restored, copy_function=shutil.copyfile)
    if inventory(restored) != expected:
        raise ValueError("Restored contents do not match the verified backup")
    return expected


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("seal", "verify", "restore-offline"))
    parser.add_argument("backup", type=Path)
    parser.add_argument("destination", nargs="?", type=Path)
    args = parser.parse_args()
    if (args.command == "restore-offline") != (args.destination is not None):
        parser.error("Provide a new destination only for restore-offline")
    try:
        if args.command == "restore-offline":
            record = restore(args.backup, args.destination)
        else:
            record = {"seal": seal, "verify": verify}[args.command](args.backup)
    except (OSError, ValueError) as error:
        # Do not dump file names, manifest contents or customer data.
        parser.exit(1, f"Backup check failed ({type(error).__name__}). Inspect the restricted folder.\n")
    print(f"Verified {len(record['files'])} persistent files in {len(record['directories'])} directories.")


if __name__ == "__main__":
    main()
