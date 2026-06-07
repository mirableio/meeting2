#!/usr/bin/env bash
set -euo pipefail

# Dev-only Gemini runner for the captured stereo fixture. The product code will
# eventually own retries, chunking, structured outputs, and persistence; this
# script intentionally proves the API/input-shape assumption with minimal moving
# parts and durable artifacts for inspection.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEREO_FILE="${STEREO_FILE:-$ROOT/.gemini-fixture/combined-stereo.mp3}"
OUTPUT_DIR="${GEMINI_OUTPUT_DIR:-$ROOT/.gemini-fixture}"
MODEL="${GEMINI_MODEL:-gemini-3-flash-preview}"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

API_KEY="${GOOGLE_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Set GOOGLE_API_KEY in .env or the environment before running dev-transcribe" >&2
    exit 1
fi

if [[ ! -f "$STEREO_FILE" ]]; then
    echo "Missing stereo input: $STEREO_FILE" >&2
    echo "Run 'make dev-combine-stereo RECORDING=<folder>' first, or set STEREO_FILE." >&2
    exit 1
fi

for tool in curl jq file; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required for dev-transcribe" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT_DIR"

FILE_INFO="$OUTPUT_DIR/file-info.json"
RESPONSE="$OUTPUT_DIR/gemini-response.json"
TRANSCRIPT="$OUTPUT_DIR/transcript.txt"
HEADER_FILE="$(mktemp "$OUTPUT_DIR/upload-header.XXXXXX")"
trap 'rm -f "$HEADER_FILE"' EXIT

MIME_TYPE="$(file -b --mime-type "$STEREO_FILE")"
case "$MIME_TYPE" in
    audio/mpeg) MIME_TYPE="audio/mp3" ;;
    audio/x-wav) MIME_TYPE="audio/wav" ;;
esac

PROMPT="${GEMINI_PROMPT:-}"
if [[ -z "$PROMPT" ]]; then
    PROMPT=$'The audio is stereo: left channel is the local microphone, right channel is system/Zoom audio.\n\nFirst determine whether the audio contains clearly intelligible human speech. If the audio is silent, or contains only non-speech sounds such as keyboard typing, room noise, breathing, output exactly:\n[silence]\n\nIf there is clear speech, transcribe this dialog (in the language they speak), very thoroughly. format without timestamps, by speaker:\nspeaker 1: text\nspeaker 2: text'
fi

NUM_BYTES="$(wc -c < "$STEREO_FILE")"
DISPLAY_NAME="$(basename "$STEREO_FILE")"

curl -sS "https://generativelanguage.googleapis.com/upload/v1beta/files" \
    -H "x-goog-api-key: $API_KEY" \
    -D "$HEADER_FILE" \
    -H "X-Goog-Upload-Protocol: resumable" \
    -H "X-Goog-Upload-Command: start" \
    -H "X-Goog-Upload-Header-Content-Length: $NUM_BYTES" \
    -H "X-Goog-Upload-Header-Content-Type: $MIME_TYPE" \
    -H "Content-Type: application/json" \
    -d "{\"file\": {\"display_name\": \"$DISPLAY_NAME\"}}" >/dev/null

UPLOAD_URL="$(
    awk 'BEGIN{IGNORECASE=1} /^x-goog-upload-url:/ {sub(/^[^:]+: /, ""); sub(/\r$/, ""); print; exit}' "$HEADER_FILE"
)"
if [[ -z "$UPLOAD_URL" ]]; then
    echo "Gemini did not return an upload URL" >&2
    exit 1
fi

curl -sS "$UPLOAD_URL" \
    -H "Content-Length: $NUM_BYTES" \
    -H "X-Goog-Upload-Offset: 0" \
    -H "X-Goog-Upload-Command: upload, finalize" \
    -H "Content-Type: $MIME_TYPE" \
    --data-binary "@$STEREO_FILE" > "$FILE_INFO"

FILE_URI="$(jq -r '.file.uri // empty' "$FILE_INFO")"
FILE_MIME="$(jq -r --arg fallback "$MIME_TYPE" '.file.mimeType // $fallback' "$FILE_INFO")"
if [[ -z "$FILE_URI" ]]; then
    echo "Gemini file upload failed" >&2
    cat "$FILE_INFO" >&2
    exit 1
fi

jq -n \
    --arg prompt "$PROMPT" \
    --arg uri "$FILE_URI" \
    --arg mime "$FILE_MIME" \
    '{contents:[{parts:[{text:$prompt},{file_data:{mime_type:$mime,file_uri:$uri}}]}], generationConfig:{temperature:1.0}}' |
    curl -sS "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent" \
        -H "x-goog-api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -X POST \
        -d @- > "$RESPONSE"

if jq -e '.error' "$RESPONSE" >/dev/null; then
    jq '.error' "$RESPONSE" >&2
    exit 1
fi

jq -r '[.candidates[].content.parts[]?.text] | join("\n")' "$RESPONSE" > "$TRANSCRIPT"

echo "$TRANSCRIPT"
