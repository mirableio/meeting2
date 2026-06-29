#!/usr/bin/env python3
"""Move redundant retained Meeting2 track files to Trash.

Meeting2's durable playback/transcription artifact is `audio.m4a`. The retained
`mic.m4a`/`system.m4a` files are intentionally useful while debugging capture and
echo decisions, but once a folder has `audio.m4a` they are no longer required for
normal use. This script applies that conservative rule only:

  - scope is one recordings root;
  - a folder must already contain `audio.m4a`;
  - only `mic.m4a`, `system.m4a`, `mic.caf`, and `system.caf` are moved;
  - files are moved into a timestamped Trash subfolder, preserving the meeting
    folder name, so recovery is a Finder move away.

It deliberately does not update `meeting.json`: current app state is derived from
`audio.m4a`/`transcript.json`, and rewriting metadata during cleanup would turn a
space-reclaim operation into a data migration.
"""

from __future__ import annotations

import argparse
import shutil
from datetime import datetime
from pathlib import Path


RETAINED_TRACK_NAMES = ("mic.m4a", "system.m4a", "mic.caf", "system.caf")


def retained_tracks(root: Path) -> list[Path]:
    """Return retained track files that are safe to remove from the live library."""
    if not root.exists():
        return []

    tracks: list[Path] = []
    for folder in sorted(path for path in root.iterdir() if path.is_dir()):
        if not (folder / "audio.m4a").exists():
            continue
        for name in RETAINED_TRACK_NAMES:
            candidate = folder / name
            if candidate.exists():
                tracks.append(candidate)
    return tracks


def unique_destination(path: Path) -> Path:
    """Avoid overwriting anything already in Trash from an earlier cleanup."""
    if not path.exists():
        return path

    counter = 1
    while True:
        candidate = path.with_name(f"{path.stem}-{counter}{path.suffix}")
        if not candidate.exists():
            return candidate
        counter += 1


def move_to_trash(paths: list[Path], trash_root: Path) -> Path | None:
    """Move files to a timestamped Trash folder and return that folder."""
    if not paths:
        return None

    destination_root = trash_root / f"meeting2-mic-system-cleanup-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    destination_root.mkdir(parents=True, exist_ok=False)

    for source in paths:
        destination_dir = destination_root / source.parent.name
        destination_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(unique_destination(destination_dir / source.name)))

    return destination_root


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Move retained mic/system files from Meeting2 folders with audio.m4a into Trash."
    )
    parser.add_argument("--root", type=Path, default=Path.home() / "Recordings" / "Meetings")
    parser.add_argument("--trash-root", type=Path, default=Path.home() / ".Trash")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    tracks = retained_tracks(args.root.expanduser())
    folders = {track.parent for track in tracks}
    print(f"affected_folders={len(folders)}")
    print(f"files_to_trash={len(tracks)}")

    if args.dry_run:
        for track in tracks:
            print(track)
        return 0

    destination_root = move_to_trash(tracks, args.trash_root.expanduser())
    if destination_root is None:
        print("trash_root=none")
        print("moved_files=0")
        return 0

    print(f"trash_root={destination_root}")
    print(f"moved_files={len(tracks)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
