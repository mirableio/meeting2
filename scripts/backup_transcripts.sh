#!/usr/bin/env bash
set -euo pipefail

# Keep backup outside the capture/transcription pipeline: copying the small durable
# artifacts is independent of recording, and iCloud owns uploading them afterward.
recordings_root="$HOME/Recordings/Meetings"
icloud_root="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
destination="$icloud_root/Meeting2"
custom_destination=false
dry_run=false

usage() {
    echo "Usage: $0 [--root folder] [--destination folder] [--dry-run]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root|--destination)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "Expected a folder after $1" >&2
                exit 1
            fi
            if [[ "$1" == --root ]]; then
                recordings_root="$2"
            else
                destination="$2"
                custom_destination=true
            fi
            shift 2
            ;;
        --dry-run) dry_run=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

if [[ ! -d "$recordings_root" ]]; then
    echo "Recordings folder does not exist: $recordings_root" >&2
    exit 1
fi
if [[ "$custom_destination" == false && ! -d "$icloud_root" ]]; then
    # Do not manufacture an iCloud-looking folder when Drive is unavailable: a
    # successful local copy there would misleadingly look like a cloud backup.
    echo "iCloud Drive is unavailable: $icloud_root" >&2
    exit 1
fi

options=(-rt --checksum --omit-dir-times --itemize-changes --stats --prune-empty-dirs)
if [[ "$dry_run" == true ]]; then
    options+=(--dry-run)
else
    mkdir -p "$destination"
fi

# Anchored filters restrict the copy to one meeting-folder level, excluding audio,
# logs, nested _bak folders, and temporary writes. Never --delete: removing a local
# meeting must not remove its backup. Updates replace the current backup in place;
# this is an incremental copy, not a versioned archive.
rsync "${options[@]}" \
    --include='/*/' \
    --include='/*/transcript.md' \
    --include='/*/transcript.json' \
    --include='/*/meeting.json' \
    --exclude='*' \
    "${recordings_root%/}/" "${destination%/}/"

if [[ "$dry_run" == true ]]; then
    echo "Dry run: no backup files copied."
else
    echo "Transcript backup copied to: $destination"
    echo "For iCloud Drive destinations, macOS uploads these files asynchronously."
fi
