#!/usr/bin/env bash
set -euo pipefail

# Build the artifact we actually want to feed to multimodal models: one compressed
# stereo file where channel identity carries product meaning. Keeping this as a
# separate step makes model experiments reproducible; prompt/model changes should
# never require recapturing or re-aligning the meeting audio.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORDING="${RECORDING:-$ROOT/.capture/zoom-fixture}"
OUTPUT="${STEREO_OUTPUT:-$ROOT/.gemini-fixture/combined-stereo.mp3}"
BITRATE="${STEREO_BITRATE:-128k}"

MIC="$RECORDING/mic.caf"
SYSTEM="$RECORDING/system.caf"
STATS="$RECORDING/stats.json"

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "Missing required file: $path" >&2
        exit 1
    fi
}

require_file "$MIC"
require_file "$SYSTEM"
require_file "$STATS"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is required for dev-combine-stereo" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for dev-combine-stereo" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

# Positive delta means mic started after system, so pad the mic channel. Negative
# means the system track started later. Rounding to milliseconds matches ffmpeg's
# adelay unit and is well below the product tolerance we measured in smoke-align.
DELTA_MS="$(jq -r '.micMinusSystemStartDeltaMS // 0' "$STATS")"
DELAY_MS="$(awk -v delta="$DELTA_MS" 'BEGIN { if (delta < 0) delta = -delta; printf "%d", delta + 0.5 }')"

if awk -v delta="$DELTA_MS" 'BEGIN { exit !(delta >= 0) }'; then
    FILTER="[0:a]adelay=${DELAY_MS}|${DELAY_MS}[mic];[mic][1:a]amerge=inputs=2[a]"
else
    FILTER="[1:a]adelay=${DELAY_MS}|${DELAY_MS}[system];[0:a][system]amerge=inputs=2[a]"
fi

ffmpeg -y -hide_banner -loglevel error \
    -i "$MIC" \
    -i "$SYSTEM" \
    -filter_complex "$FILTER" \
    -map "[a]" \
    -ac 2 \
    -c:a libmp3lame \
    -b:a "$BITRATE" \
    "$OUTPUT"

echo "$OUTPUT"
