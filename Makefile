.PHONY: bootstrap submodule rootfs rootfs-publish ish-core icon gen build test ipa init clean

XCODE := xcodebuild
SCHEME := XForge

## Everything needed to build locally, in order.
bootstrap: submodule rootfs ish-core

## Pull the ish-arm64 engine sources (git submodule).
submodule:
	git submodule update --init --depth 1 Vendor/ish-arm64
	git -C Vendor/ish-arm64 submodule update --init --depth 1 deps/libarchive

## Build the bundled Alpine fakefs rootfs into Support/Resources.
## Needs root (it chroots into the tree) and room for the toolchain: the default
## is the *provisioned* root — xtool, Swift and the Darwin SDK installed, ~1.6 GB.
## XFORGE_PROVISION=none builds the few-MB plain one instead, where the guest
## installs the toolchain itself.
## build-ipa.yml downloads the published copy rather than rebuilding it.
rootfs:
	@bash EmbeddedLinux/build-rootfs.sh Support/Resources

## Build the rootfs and publish it as a pinned release asset for CI.
## Usage: make rootfs-publish TAG=rootfs-v5 [ALPINE=3.21] [PROVISION=none]
rootfs-publish:
	@test -n "$(TAG)" || { echo "usage: make rootfs-publish TAG=rootfs-v5"; exit 1; }
	@command -v gh >/dev/null 2>&1 || { \
		echo "GitHub CLI is required: https://cli.github.com/"; exit 1; \
	}
	gh workflow run build-rootfs.yml -f tag=$(TAG) -f alpine_version=$(or $(ALPINE),3.21) \
		-f provision=$(or $(PROVISION),all)
	@echo "Dispatched build-rootfs.yml for $(TAG); then set ROOTFS_TAG in build-ipa.yml."

## Build the embedded ish-arm64 Linux engine into Vendor/ish-arm64-build/lib.
ish-core:
	@bash EmbeddedLinux/build-ish-core.sh

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

## Install Swift + xtool into the guest, on the device. The published rootfs
## already carries them, so this is a no-op there; it is what a plain root
## (XFORGE_PROVISION=none) needs. Run it inside the XForge terminal, not the host:
##     sh /root/install-toolchain.sh all
init:
	@echo "Run this in the XForge terminal (embedded Linux), not on the host:"
	@echo "    sh /root/install-toolchain.sh all"

clean:
	rm -rf build dist XForge.xcodeproj Vendor/ish-arm64-build .rootfs-work
