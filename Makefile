.PHONY: bootstrap submodule rootfs ish-core icon gen build test ipa sdk clean

XCODE := xcodebuild
SCHEME := XForge

## Everything needed to build locally, in order.
bootstrap: submodule rootfs ish-core

## Pull the iSH-AOK engine sources (git submodule).
submodule:
	git submodule update --init --depth 1 Vendor/ish-AOK

## Fetch the bundled Alpine aarch64 root filesystem into Support/Resources.
rootfs:
	@bash EmbeddedLinux/fetch-rootfs.sh

## Build the embedded iSH-AOK Linux engine into Vendor/ish-AOK-build/lib.
ish-core:
	@bash EmbeddedLinux/build-ish-aok-core.sh

## Regenerate the app icon + accent colour asset catalog (needs Pillow)
icon:
	python3 Tools/gen-appicon.py

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

clean:
	rm -rf build dist XForge.xcodeproj Vendor/ish-AOK-build
