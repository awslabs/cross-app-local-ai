#!/bin/bash
#
# Patches the upstream `LocalLLMClient` SwiftPM checkout to fix a
# Release-build linker failure.
#
# ## Background
#
# `LocalLLMClient/Sources/LocalLLMClientLlama/stb_image.swift` declares
# three `@_silgen_name` functions (`stbi_load_from_memory`, `stbi_load`,
# `stbi_image_free`) that satisfy `extern` declarations in the bundled
# llama.cpp multimodal C code.
#
# Under Debug these functions are emitted with external linkage by
# default and the C side links fine. Under Release, Swift's
# whole-module optimization sees the functions have no access modifier
# and emits them with local linkage, causing:
#
#     Undefined symbols for architecture arm64:
#       _stbi_load_from_memory
#       _stbi_load
#       _stbi_image_free
#
# The fix is three `public` keywords on those declarations. This script
# applies them after any fresh SwiftPM checkout.
#
# Upstream (as of writing) has not fixed this. A PR should be sent
# upstream so this script can be retired.
#
# ## Behavior
#
# - Idempotent: re-running after the patch is applied is a no-op.
# - Fails loudly: exits non-zero if the target file is missing or the
#   file layout has changed enough that the regex can't find the
#   `func stbi_...` declarations. This is intentional — silent failure
#   would produce a mysterious linker error an hour later.
# - Only touches the CoreImage branch (line ~5-45). The `#else` branch
#   at the end of the file only compiles on non-Apple platforms and is
#   not relevant to our build.
#
# ## Usage
#
# Run after SwiftPM has resolved packages (i.e. after the `checkouts/`
# directory is populated). `build_pkg.sh` invokes this as a pre-build
# step.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"

STB_IMAGE_FILE="${REPO_ROOT}/build/derived/SourcePackages/checkouts/LocalLLMClient/Sources/LocalLLMClientLlama/stb_image.swift"

if [ ! -f "${STB_IMAGE_FILE}" ]; then
    # LocalLLMClient's checkout layout may change in future versions
    # (older swift-llama-cpp ancestry, etc.) — if the file is gone,
    # upstream has already fixed it and we can skip cleanly.
    echo "stb_image.swift: not present in checkout (upstream fixed); skipping patch"
    exit 0
fi

# If already patched, nothing to do. Detect by looking for the first
# function declaration with the `public` modifier.
if grep -q "^public func stbi_load_from_memory" "${STB_IMAGE_FILE}"; then
    echo "stb_image.swift: patch already applied"
    exit 0
fi

# Apply the patch. `sed -i ''` is the BSD/macOS in-place-edit form.
# We anchor on `^func stbi_...` (start-of-line) to match only the
# top-level declarations, not any reference inside a function body.
sed -i '' -E \
    -e 's/^func (stbi_load_from_memory)/public func \1/' \
    -e 's/^func (stbi_load)\(/public func \1(/' \
    -e 's/^func (stbi_image_free)/public func \1/' \
    "${STB_IMAGE_FILE}"

# Verify. The patch is worthless if sed matched nothing — for example
# if upstream renamed a function or reformatted the file.
declare -a REQUIRED_LINES=(
    "^public func stbi_load_from_memory"
    "^public func stbi_load\("
    "^public func stbi_image_free"
)

for pattern in "${REQUIRED_LINES[@]}"; do
    if ! grep -qE "${pattern}" "${STB_IMAGE_FILE}"; then
        echo "stb_image.swift: patch did not apply cleanly" >&2
        echo "  pattern not found after sed: ${pattern}" >&2
        echo "  upstream file layout may have changed; update this script" >&2
        exit 1
    fi
done

echo "stb_image.swift: patched (3 public declarations added)"
