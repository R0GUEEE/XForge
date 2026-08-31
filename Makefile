.PHONY: gen build test ipa sdk

XCODE := xcodebuild
SCHEME := XForge

## Generate the Xcode project from project.yml
gen:
	xcodegen generate --spec project.yml

## Resolve SPM deps and build for the simulator
build: gen
	$(XCODE) -project XForge.xcodeproj -scheme $(SCHEME) \
		-configuration Debug -destination 'generic/platform=iOS Simulator' build

## Run unit tests on the simulator
test: gen
	$(XCODE) -project XForge.xcodeproj -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 16' test

## Build the unsigned IPA for sideloading
ipa: gen
	@bash .github/workflows/_local_ipa.sh || \
	echo "Use the 'unsigned-ipa.yml' GitHub Actions workflow to build the IPA."

## (macOS only) Build the darwin Swift SDK from local Xcode
sdk:
	xtool sdk build "$$(dirname $$(dirname $$(xcrun -f swiftc)))" darwin-sdk-out
