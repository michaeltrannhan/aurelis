# Orchestrates Scripts/. Canonical: make install, make build, make test
# Implementation lives in Scripts/; this file is a stable public entry point.

.PHONY: install build test verify release dmg preflight dev xcodegen

install:
	./install.sh --yes

build:
	Scripts/build-release-app.sh

test:
	swift test

verify:
	Scripts/run-verification.sh all

release:
	Scripts/package-release.sh

dmg:
	Scripts/package-dmg.sh

preflight:
	Scripts/ci-preflight.sh

dev:
	RUN_APP=YES Scripts/build-debug-app.sh

xcodegen:
	Scripts/install-xcodegen-ci.sh
