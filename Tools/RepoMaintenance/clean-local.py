#!/usr/bin/env python3
"""Preview or remove ignored local outputs; never remove Git-tracked files."""

import argparse
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
GENERATED = ("DerivedData", "build", "TestResults", ".tmp")


def git_paths(*args):
    output = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", *args, "-z"])
    return {os.fsdecode(path) for path in output.split(b"\0") if path}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Delete the previewed ignored outputs.")
    parser.add_argument("--dependencies", action="store_true", help="Also remove installed backend node_modules (restore with npm ci).")
    args = parser.parse_args()
    tracked = git_paths()
    ignored = git_paths("--others", "--ignored", "--exclude-standard")
    # Only explicit generated roots and ignored raw evidence are eligible. Leave
    # source, untracked work, secrets, .git and local Wrangler databases alone.
    candidates = []
    for relative in GENERATED:
        directory = ROOT / relative
        if directory.is_symlink():
            raise SystemExit(f"Refusing symlink output directory: {relative}")
        if directory.exists():
            candidates.append(directory)
    artifact_root = ROOT / "BuildArtifacts"
    if artifact_root.is_symlink():
        raise SystemExit("Refusing symlink artifact directory")
    for relative in sorted(ignored):
        if relative.startswith("BuildArtifacts/"):
            candidates.append(ROOT / relative)
    # These contain packaged code / account caches, never state/v3 local D1 data.
    for relative in (".wrangler/cache", "Backend/MonitoringWorker/.wrangler/cache",
                     "Backend/CloudflareGalleryProxy/.wrangler/cache",
                     "Backend/PaymentsWorker/.wrangler/dry-run-live",
                     "Backend/PaymentsWorker/.wrangler/dry-run-test",
                     "Backend/PaymentsWorker/.wrangler/pilot-activation-dry-run"):
        if (ROOT / relative).exists():
            candidates.append(ROOT / relative)
    if args.dependencies:
        directory = ROOT / "Backend/PaymentsWorker/node_modules"
        if directory.exists():
            candidates.append(directory)

    # Preflight the entire operation before deleting anything. Refuse a root if
    # someone put tracked files or non-ignored new work inside it.
    files = set()
    directories = set()
    for candidate in candidates:
        if candidate.is_symlink():
            paths = [candidate]
        elif candidate.is_dir():
            paths = []
            directories.add(candidate)
            for base, dirs, names in os.walk(candidate, followlinks=False):
                for name in dirs[:]:
                    child = Path(base) / name
                    if child.is_symlink():
                        paths.append(child)
                        dirs.remove(name)
                    else:
                        directories.add(child)
                paths.extend(Path(base) / name for name in names)
        else:
            paths = [candidate]
        for path in paths:
            if not path.parent.resolve().is_relative_to(ROOT):
                raise SystemExit(f"Refusing path outside repository: {path}")
            relative = path.relative_to(ROOT).as_posix()
            if relative in tracked or relative not in ignored:
                raise SystemExit(f"Refusing tracked or non-ignored file: {relative}")
            files.add(path)
    total = sum(path.lstat().st_size for path in files)
    action = "Remove" if args.apply else "Would remove"
    print(f"{action} {len(files):,} ignored files ({total / 1024**3:.2f} GiB logical size).")
    if not args.apply:
        print("Use --apply to delete. Save private snapshots and stage curated evidence first.")
        return
    for path in sorted(files):
        path.unlink()
    # Remove only empty directories. Preserve the curated BuildArtifacts tree.
    directories.update(path.parent for path in files)
    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        try:
            directory.rmdir()
        except OSError:
            pass
    print("Cleanup complete. Tracked files and non-ignored work were preserved.")


if __name__ == "__main__":
    main()
