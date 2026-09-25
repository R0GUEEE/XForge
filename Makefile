.PHONY: toolchain toolchain-release icon gen build test ipa clean

XCODE := xcodebuild
SCHEME := XForge

## Install the native toolchain bundle into Vendor/NativeToolchain.
##
## The bundle is built by the `Native iOS Toolchain` workflow and published as a
## release asset whose tag names its contents, so the newest one is a well-defined
## thing to ask for. Without a bundle the app still builds and runs: the C bridge
## compiles to a "not available" stub and the Toolchain screen says so.
##
##   make toolchain-release            # newest published bundle
##   make toolchain-release TAG=...    # a specific one
##   make toolchain ARCHIVE=...        # a local tarball
toolchain:
	@if [ -z "$(ARCHIVE)" ]; then \
		echo "usage: make toolchain ARCHIVE=XForgeNativeToolchain-arm64-ios.tar.gz"; \
		echo "       make toolchain-release [TAG=...]"; \
		exit 64; \
	fi
	@bash NativeToolchain/install-bundle.sh "$(ARCHIVE)"

## Install the newest published toolchain bundle (see `toolchain` above)
toolchain-release:
	@bash NativeToolchain/install-bundle.sh --release $(TAG)

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
ipa:
	@command -v gh >/dev/null 2>&1 || { \
		echo "GitHub CLI is required: https://cli.github.com/"; exit 1; \
	}
	gh workflow run build-ipa.yml
	@echo "Dispatched build-ipa.yml; monitor it with: gh run watch"

clean:
	rm -rf build dist XForge.xcodeproj
