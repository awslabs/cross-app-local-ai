# FastLang — project.yml (XcodeGen) is the single source of truth.
# FastLang.xcodeproj is generated and gitignored; never hand-edit it.
# Run `make generate` after editing project.yml or a fresh checkout.

PROJECT      := FastLang.xcodeproj
SCHEME       := FastLang
DESTINATION  := platform=macOS

.PHONY: generate build release pkg test test-unit test-integration test-filter \
	open clean clean-derived export check-xcodegen lint format precommit check

## Regenerate FastLang.xcodeproj from project.yml
generate: check-xcodegen
	xcodegen generate

## Regenerate, then build the app
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build

## Regenerate, then run the full test suite (UnitTests + IntegrationTests + UITests)
test: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'

## Regenerate, then run only UnitTests (fast loop, no model-gated integration tests)
test-unit: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-only-testing:UnitTests

## Regenerate, then run only IntegrationTests
test-integration: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-only-testing:IntegrationTests

## Regenerate, then run a single test/suite (usage: make test-filter TEST=UnitTests/KokoroPhonemizerSpecialTokenTests)
test-filter: generate
	@test -n "$(TEST)" || { echo "Usage: make test-filter TEST=<Target/Suite/testMethod>"; exit 1; }
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-only-testing:$(TEST)

## Run SwiftLint in strict mode (same check pre-commit runs)
lint:
	swiftlint --strict

## Run SwiftFormat in place (same formatter pre-commit runs, configured via .swiftformat)
## Scoped to real source dirs, NOT "." -- .swiftformat's --exclude list covers
## .build/scratch/DerivedData/Tools but not this project's build/ directory,
## which holds vendored SPM checkout sources (e.g. build/derived/SourcePackages/
## checkouts/swift-transformers) that must never be reformatted.
format:
	swiftformat Sources Tests FastLang Views

## Run the full pre-commit hook suite against all files
precommit:
	pre-commit run --all-files

## Feature-completion gate: pre-commit, then the full test suite. Uses
## recipe-sequenced $(MAKE) calls (not prerequisite ordering) so this stays
## correct even when invoked as `make -j check`.
check:
	$(MAKE) precommit
	$(MAKE) test

## Regenerate, then open the project in Xcode
open: generate
	open $(PROJECT)

SIGN ?=
SIGN_FLAG := $(if $(filter local,$(SIGN)),--sign-local,$(if $(filter ci,$(SIGN)),--sign,))

## Build a Release .app (usage: make release [SIGN=local|ci])
release: generate
	Tools/packaging/build_pkg.sh --build-only $(SIGN_FLAG)

## Build .pkg installer; uninstalls previous, opens installer (usage: make pkg [SIGN=local|ci])
pkg: generate
	Tools/packaging/build_pkg.sh $(SIGN_FLAG)

## Export an OSS-clean copy to DEST (usage: make export DEST=/path/to/repo)
export:
	@test -n "$(DEST)" || { echo "Usage: make export DEST=/path/to/public-repo"; exit 1; }
	@test -d "$(DEST)" || { echo "Error: $(DEST) does not exist"; exit 1; }
	rsync -av --delete \
		--exclude-from=.oss-exclude \
		--exclude=.git/ \
		./ $(DEST)/
	@echo ""
	@echo "Exported to $(DEST)"
	@echo "  Source commit: $$(git rev-parse --short HEAD)"
	@echo "  Branch:        $$(git branch --show-current)"

## Remove build artifacts (does NOT touch the committed Package.resolved)
clean:
	rm -rf build/

## Remove this project's Xcode DerivedData (fixes stale-signature/duplicate-class build issues)
clean-derived:
	rm -rf "$$HOME/Library/Developer/Xcode/DerivedData/$(SCHEME)-"*

check-xcodegen:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install with: brew install xcodegen"; exit 1; }
