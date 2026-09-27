# swift-app-intervention
#
# Verification happens here, not in CI (CI only turns tags into Releases).
# Every target prints its elapsed time next to a budget measured with warm caches; going over
# the budget is a defect to investigate, not something to live with. Cold caches take a few
# times longer.

.PHONY: all help build test build-ios sample check-metadata docs mutants qa verify clean

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

QA_SIM ?= iPhone 17e
SAMPLE_DESTINATION = 'platform=iOS Simulator,name=$(QA_SIM)'
DERIVED = .build/xcode

timed = s=$$(date +%s); trap 'echo "⏱  $@ $$(( $$(date +%s)-s ))s (budget $(1))" >&2' EXIT;

all: help

help:
	@echo "swift-app-intervention (budgets with warm caches)"
	@echo ""
	@echo "  make build           swift build (macOS host)                                   ~5s"
	@echo "  make test            bounded-await check + swift test (macOS host)              ~10s"
	@echo "  make build-ios       every target for the iOS Simulator                         ~30s"
	@echo "  make sample          Examples/InterventionSample for $(QA_SIM)                  ~30s"
	@echo "  make check-metadata  sample build + supportedModes == 9                         ~30s"
	@echo "  make docs            DocC for iOS, no warnings allowed, into ./_site             ~30s"
	@echo "  make mutants         mutation run in a git worktree (commit first)              ~6min"
	@echo "  make qa              simulator QA pass with screenshots (.build/qa-shots)       ~90s"
	@echo "  make verify          build, test, build-ios, check-metadata, docs"

build:
	@$(call timed,5s) swift build

test:
	@$(call timed,10s) scripts/check-bounded-awaits.sh && swift test

build-ios:
	@$(call timed,30s) xcodebuild -scheme AppIntervention-Package -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) build -quiet 2>&1 | { grep -v IDERunDestination || true; } && echo "✓ iOS Simulator build"

sample:
	@$(call timed,30s) cd Examples/InterventionSample && xcodegen generate --quiet && \
		xcodebuild -project InterventionSample.xcodeproj -scheme InterventionSample -destination $(SAMPLE_DESTINATION) \
		-derivedDataPath ../../.build/sample CODE_SIGNING_ALLOWED=NO build -quiet 2>&1 | { grep -v IDERunDestination || true; } && \
		echo "✓ sample app build"

check-metadata:
	@$(call timed,30s) QA_SIM="$(QA_SIM)" scripts/check-intent-metadata.sh

docs:
	@$(call timed,30s) scripts/build-docs.sh

mutants:
	@$(call timed,6min) scripts/mutants.py $(MUTANTS)

qa:
	@$(call timed,90s) QA_SIM="$(QA_SIM)" scripts/qa-sample.sh

verify: build test build-ios check-metadata docs

clean:
	@swift package clean
	@rm -rf .build _site Examples/InterventionSample/InterventionSample.xcodeproj
