# swift-app-intervention
# 検証は手元で行う（CI はタグから Release を作るだけ）。テストは直列で走らせる。

.PHONY: all help build test build-ios sample check-metadata verify clean

IOS_DESTINATION = 'generic/platform=iOS Simulator'
DERIVED = .build/xcode

all: help

help:
	@echo "swift-app-intervention"
	@echo ""
	@echo "  make build           - swift build (macOS host)"
	@echo "  make test            - swift test (macOS host; core, focus, intents adapter)"
	@echo "  make build-ios       - Build every target for the iOS Simulator"
	@echo "  make sample          - Generate and build Examples/InterventionSample (iOS 26)"
	@echo "  make check-metadata  - Build the sample and assert supportedModes == 9"
	@echo "  make verify          - All of the above, in order"
	@echo "  make clean           - Remove build artifacts"

build:
	@swift build

test:
	@swift test

build-ios:
	@xcodebuild -scheme AppIntervention-Package -destination $(IOS_DESTINATION) \
		-derivedDataPath $(DERIVED) build -quiet
	@echo "✓ iOS Simulator build"

sample:
	@cd Examples/InterventionSample && xcodegen generate --quiet
	@xcodebuild -project Examples/InterventionSample/InterventionSample.xcodeproj -scheme InterventionSample \
		-destination $(IOS_DESTINATION) -derivedDataPath .build/sample CODE_SIGNING_ALLOWED=NO build -quiet
	@echo "✓ sample app build"

check-metadata:
	@scripts/check-intent-metadata.sh

verify: build test build-ios sample check-metadata

clean:
	@swift package clean
	@rm -rf .build Examples/InterventionSample/InterventionSample.xcodeproj
