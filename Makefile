# FastLang — project.yml (XcodeGen) is the single source of truth.
# FastLang.xcodeproj is generated and gitignored; never hand-edit it.
# Run `make generate` after editing project.yml or a fresh checkout.

PROJECT      := FastLang.xcodeproj
SCHEME       := FastLang
DESTINATION  := platform=macOS

.PHONY: generate build release pkg test open clean export check-xcodegen

## Regenerate FastLang.xcodeproj from project.yml
generate: check-xcodegen
	xcodegen generate

## Regenerate, then build the app
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build

## Regenerate, then run the full test suite
test: generate
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'

## Regenerate, then open the project in Xcode
open: generate
	open $(PROJECT)

## Build a Release .app (no signing, no .pkg installer)
release: generate
	Tools/packaging/build_pkg.sh --build-only

## Build unsigned .pkg installer (uninstalls previous, opens installer)
pkg: generate
	Tools/packaging/build_pkg.sh

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

check-xcodegen:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install with: brew install xcodegen"; exit 1; }
