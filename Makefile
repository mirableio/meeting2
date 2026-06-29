SHELL := /bin/bash

# The Makefile is the executable version of the M1 gate. Keep product-safe tasks
# plain and prefix local harness/API workflows with dev- so nobody mistakes a TCC
# smoke test, route switch, or Gemini upload for a normal build step.
CONFIG ?= debug
DURATION ?= 3
CAPTURE_ROOT ?= $(CURDIR)/.capture
SMOKE_DIR ?= $(CAPTURE_ROOT)/smoke
SYSTEM_SMOKE_DIR ?= $(CAPTURE_ROOT)/system-test
CRASH_SMOKE_DIR ?= $(CAPTURE_ROOT)/crash-test
ROUTE_SMOKE_DIR ?= $(CAPTURE_ROOT)/route-test
ALIGN_SMOKE_DIR ?= $(CAPTURE_ROOT)/align-test
ALIGN_CLICK_FILE ?= $(CURDIR)/.build/alignment-clicks.caf
ALIGN_STATS_FILE ?= $(ALIGN_SMOKE_DIR)/stats.json
ALIGN_THRESHOLD_MS ?= 50
SAY_TEXT ?= system audio capture test for meeting two
RECORDING ?= $(CAPTURE_ROOT)/zoom-fixture
STEREO_OUTPUT ?= $(CURDIR)/.gemini-fixture/combined-stereo.mp3
STEREO_FILE ?= $(STEREO_OUTPUT)
GEMINI_OUTPUT_DIR ?= $(CURDIR)/.gemini-fixture
GEMINI_MODEL ?= gemini-3-flash-preview
STEREO_BITRATE ?= 128k
RECOVERY_ROOT ?= $(CRASH_SMOKE_DIR)
COMPRESSION_ROOT ?= $(RECORDING)
TRANSCRIPTION_ROOT ?= $(RECORDING)
TRANSCRIPTION_ENV ?= $(CURDIR)/.env
TRANSCRIPTION_MODEL ?= $(GEMINI_MODEL)
RECORDINGS_ROOT ?= $(HOME)/Recordings/Meetings
TRASH_ROOT ?= $(HOME)/.Trash
DRY_RUN ?= 0

APP := .build/$(CONFIG)/CaptureHarness.app
HARNESS := $(APP)/Contents/MacOS/CaptureHarness
MENU_APP := .build/$(CONFIG)/Meeting2.app
AUDIO_TOOL := .build/$(CONFIG)/AudioDeviceTool
ALIGN_TOOL := .build/$(CONFIG)/AudioAlignmentTool
RECOVERY_TOOL := .build/$(CONFIG)/MeetingRecoveryTool
COMPRESSION_TOOL := .build/$(CONFIG)/MeetingCompressionTool
TRANSCRIPTION_TOOL := .build/$(CONFIG)/MeetingTranscriptionTool

.PHONY: build dev-package dev-package-app dev-open-app dev-audio-devices dev-smoke dev-smoke-system dev-smoke-crash dev-smoke-route dev-smoke-route-auto dev-smoke-align dev-recover dev-compress dev-combine-stereo dev-transcribe dev-transcribe-fixture dev-clean-retained-tracks dev-clean

build:
	swift build --configuration $(CONFIG)

dev-package:
	CONFIG=$(CONFIG) scripts/package_capture_harness.sh

dev-package-app:
	CONFIG=$(CONFIG) scripts/package_meeting2_app.sh

dev-open-app: dev-package-app
	open "$(MENU_APP)"

dev-audio-devices: build
	"$(AUDIO_TOOL)" list-output

# Runs the already-packaged app binary. This intentionally does not depend on
# dev-package: TCC permissions attach to the signed bundle, and unnecessary rebuilds
# make permission debugging noisy.
dev-smoke:
	test -x "$(HARNESS)" || { echo "Missing $(HARNESS). Run 'make dev-package' first."; exit 1; }
	rm -rf "$(SMOKE_DIR)"
	"$(HARNESS)" --duration $(DURATION) --output "$(SMOKE_DIR)"
	afinfo "$(SMOKE_DIR)/mic.caf" >/dev/null
	afinfo "$(SMOKE_DIR)/system.caf" >/dev/null

# Plays a short macOS voice prompt during capture so the system track should be
# non-silent. This is the quickest repeatable check for the Core Audio process tap.
dev-smoke-system:
	test -x "$(HARNESS)" || { echo "Missing $(HARNESS). Run 'make dev-package' first."; exit 1; }
	rm -rf "$(SYSTEM_SMOKE_DIR)"
	"$(HARNESS)" --duration 6 --output "$(SYSTEM_SMOKE_DIR)" & pid=$$!; \
	sleep 1; \
	say "$(SAY_TEXT)"; \
	wait $$pid
	afinfo "$(SYSTEM_SMOKE_DIR)/mic.caf" >/dev/null
	afinfo "$(SYSTEM_SMOKE_DIR)/system.caf" >/dev/null

dev-smoke-crash:
	test -x "$(HARNESS)" || { echo "Missing $(HARNESS). Run 'make dev-package' first."; exit 1; }
	rm -rf "$(CRASH_SMOKE_DIR)"
	"$(HARNESS)" --duration 60 --output "$(CRASH_SMOKE_DIR)" & pid=$$!; \
	sleep 1; \
	say "$(SAY_TEXT)"; \
	kill -9 $$pid; \
	wait $$pid 2>/dev/null || true
	afinfo "$(CRASH_SMOKE_DIR)/mic.caf" >/dev/null
	afinfo "$(CRASH_SMOKE_DIR)/system.caf" >/dev/null

dev-smoke-route:
	test -x "$(HARNESS)" || { echo "Missing $(HARNESS). Run 'make dev-package' first."; exit 1; }
	rm -rf "$(ROUTE_SMOKE_DIR)"
	@echo "Switch the output route while this runs; the harness prints routeChanges on stop."
	"$(HARNESS)" --duration $(DURATION) --output "$(ROUTE_SMOKE_DIR)" & pid=$$!; \
	while kill -0 $$pid 2>/dev/null; do say "$(SAY_TEXT)"; sleep 2; done & speaker=$$!; \
	wait $$pid; \
	kill $$speaker 2>/dev/null || true
	afinfo "$(ROUTE_SMOKE_DIR)/mic.caf" >/dev/null
	afinfo "$(ROUTE_SMOKE_DIR)/system.caf" >/dev/null

dev-smoke-route-auto: build
	test -x "$(HARNESS)" || { echo "Missing $(HARNESS). Run 'make dev-package' first."; exit 1; }
	rm -rf "$(ROUTE_SMOKE_DIR)"
	original="$$("$(AUDIO_TOOL)" current-output-uid)"; \
	alternate="$$("$(AUDIO_TOOL)" first-other-output-uid "$$original")"; \
	echo "Switching output from $$original to $$alternate and back"; \
	trap '"$(AUDIO_TOOL)" set-output "$$original" >/dev/null 2>&1 || true' EXIT; \
	"$(HARNESS)" --duration 12 --output "$(ROUTE_SMOKE_DIR)" & pid=$$!; \
	sleep 2; \
	say "$(SAY_TEXT)"; \
	"$(AUDIO_TOOL)" set-output "$$alternate"; \
	sleep 3; \
	say "$(SAY_TEXT)"; \
	"$(AUDIO_TOOL)" set-output "$$original"; \
	sleep 2; \
	say "$(SAY_TEXT)"; \
	wait $$pid
	afinfo "$(ROUTE_SMOKE_DIR)/mic.caf" >/dev/null
	afinfo "$(ROUTE_SMOKE_DIR)/system.caf" >/dev/null

dev-smoke-align: build
	test -x "$(HARNESS)" || { echo "Missing $(HARNESS). Run 'make dev-package' first."; exit 1; }
	rm -rf "$(ALIGN_SMOKE_DIR)"
	"$(ALIGN_TOOL)" generate-clicks "$(ALIGN_CLICK_FILE)" 6 >/dev/null
	"$(HARNESS)" --duration 8 --output "$(ALIGN_SMOKE_DIR)" --stats "$(ALIGN_STATS_FILE)" & pid=$$!; \
	sleep 2; \
	afplay "$(ALIGN_CLICK_FILE)"; \
	wait $$pid
	delta=$$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["micMinusSystemStartDeltaMS"] or 0))' "$(ALIGN_STATS_FILE)"); \
	"$(ALIGN_TOOL)" analyze "$(ALIGN_SMOKE_DIR)/mic.caf" "$(ALIGN_SMOKE_DIR)/system.caf" "$(ALIGN_THRESHOLD_MS)" 300 "$$delta"

dev-recover: build
	"$(RECOVERY_TOOL)" --root "$(RECOVERY_ROOT)"

dev-compress: build
	"$(COMPRESSION_TOOL)" --root "$(COMPRESSION_ROOT)"

dev-transcribe: build
	"$(TRANSCRIPTION_TOOL)" --root "$(TRANSCRIPTION_ROOT)" --env "$(TRANSCRIPTION_ENV)" --model "$(TRANSCRIPTION_MODEL)"

dev-combine-stereo:
	RECORDING="$(RECORDING)" STEREO_OUTPUT="$(STEREO_OUTPUT)" STEREO_BITRATE="$(STEREO_BITRATE)" scripts/combine_stereo_fixture.sh

dev-transcribe-fixture:
	STEREO_FILE="$(STEREO_FILE)" GEMINI_OUTPUT_DIR="$(GEMINI_OUTPUT_DIR)" GEMINI_MODEL="$(GEMINI_MODEL)" scripts/transcribe_gemini_fixture.sh

# Retained mic/system tracks are useful while debugging capture, but once audio.m4a
# exists they are redundant for normal library use and can dominate disk usage. Move
# them to a timestamped Trash folder instead of deleting them so a bad cleanup can be
# reversed manually from Finder.
dev-clean-retained-tracks:
	python3 scripts/clean_retained_tracks.py --root "$(RECORDINGS_ROOT)" --trash-root "$(TRASH_ROOT)" $(if $(filter 1 true yes,$(DRY_RUN)),--dry-run)

dev-clean:
	rm -rf .build .capture .gemini-*
