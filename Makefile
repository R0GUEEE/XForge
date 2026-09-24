.PHONY: bootstrap toolchain icon gen build test ipa clean

XCODE := xcodebuild
SCHEME := XForge

## Everything needed to build locally, in order.
bootstrap: toolchain gen

## Install the native toolchain bundle into Vendor/NativeToolchain.
##
## The bundle is built by the `Native iOS Toolchain` workflow (Clang + Mach-O LLD
## for iPhoneOS, cross-built on a Mac) and attached to the run as an artifact.
## Without it the app still builds and runs: the C bridge compiles to a
## "not available" stub and the Toolchain screen says so, which is what a plain
## clone should do.
toolchain:
	@if [ -z "$(ARCHIVE)" ]; then \
		echo "usage: make toolchain ARCHIVE=XForgeNativeToolchain-arm64-ios.tar.gz"; \
		echo ""; \
		echo "Download the artifact from a successful 'Native iOS Toolchain' run:"; \
		echo "    gh run download --repo R0GUEEE/XForge --name XForgeNativeToolchain-arm64-ios"; \
		exit 64; \
	fi
	@bash NativeToolchain/install-bundle.sh "$(ARCHIVE)"

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
