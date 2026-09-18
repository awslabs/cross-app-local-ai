#!/bin/bash
#
# Builds a distribution .pkg for FastLang and opens the installer.
#
# Layout: one required app component, two optional model components
# (E2B and E4B) the user picks between on the Customize screen. The
# chosen model's postinstall writes a marker file; on first launch the
# app reads the marker, switches localModelId to match, and triggers
# the in-app download (with progress bar in Settings).
#
# Usage:
#   ./Tools/packaging/build_pkg.sh              # default: full cycle
#   ./Tools/packaging/build_pkg.sh --build-only # just build; don't uninstall or open
#   ./Tools/packaging/build_pkg.sh --sign       # sign + notarize using CI credentials
#   ./Tools/packaging/build_pkg.sh --sign-local # sign + notarize using local Keychain
#   ./Tools/packaging/build_pkg.sh --yes        # no prompts
#
# Env:
#   VERSION=1.2.3 ./Tools/packaging/build_pkg.sh     # override version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PKG_ROOT="Tools/packaging"

# Source project configuration (can be overridden by env vars)
# shellcheck source=/dev/null
source "${REPO_ROOT}/${PKG_ROOT}/build.env"

BUILD_DIR="build"
DIST_DIR="${BUILD_DIR}/pkg"
OUTPUT_PKG="${BUILD_DIR}/${APP_NAME}-${VERSION}.pkg"

BUILD_ONLY=0
SIGN_MODE="none"
for arg in "$@"; do
    case "${arg}" in
        --build-only)  BUILD_ONLY=1 ;;
        --sign)        SIGN_MODE="ci" ;;
        --sign-local)  SIGN_MODE="local" ;;
        --yes|-y)      : ;;  # Reserved for future interactive prompts
        *)             echo "Unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

# ── Uninstall previous copy (skipped with --build-only) ─────────────────────
#
# Scope: removes the installed app bundle and forgets pkgutil receipts.
# Never touches user data under ~/Library/Application Support/com.aws.fastlang;
# that's preserved across rebuilds so you don't have to re-pick settings
# each cycle. Wipe it manually if you want a true first-run experience.

if [ "${BUILD_ONLY}" -eq 0 ]; then
    echo "==> Uninstalling previous copy"
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    pkill -f "/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

    if [ -d "/Applications/${APP_NAME}.app" ]; then
        sudo rm -rf "/Applications/${APP_NAME}.app"
        echo "    removed /Applications/${APP_NAME}.app"
    fi

    for pkg in "${BUNDLE_ID}.app" \
               "${BUNDLE_ID}.gemma" \
               "${BUNDLE_ID}.model_e2b" \
               "${BUNDLE_ID}.model_e4b"; do
        if pkgutil --pkg-info "${pkg}" >/dev/null 2>&1; then
            sudo pkgutil --forget "${pkg}" 2>/dev/null && echo "    forgot ${pkg}"
        fi
    done
fi

# ── Build the app ───────────────────────────────────────────────────────────
#
# Matches Xcode UI's Run action: Release, arm64 only.
# ONLY_ACTIVE_ARCH=YES avoids a broken x86_64 slice on Apple Silicon.
#
# We split SwiftPM resolve and the app build into two steps so the
# LocalLLMClient patch can land in between. See patch_llm_client.sh for
# the full story; the short version is the package's `stb_image.swift`
# is missing `public` on three functions, which only matters in Release
# because of whole-module optimization.

echo ""
echo "==> Generating Xcode project from project.yml"
#
# project.yml is the source of truth; FastLang.xcodeproj is generated and
# gitignored, so it must be (re)generated before any xcodebuild step.
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "    xcodegen not found; installing via Homebrew"
    brew install xcodegen
fi
#
# XcodeGen's `generate` reads $USER directly and aborts with "Couldn't find
# current username" if it's unset. CI runs this via SSM send-command in a
# non-login shell where $USER is empty, so set it explicitly. Harmless
# locally, where $USER is already populated.
export USER="${USER:-$(id -un 2>/dev/null || echo ci)}"
xcodegen generate

echo ""
echo "==> Resolving package dependencies"
xcodebuild \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${BUILD_DIR}/derived" \
    -skipMacroValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    -resolvePackageDependencies

echo ""
echo "==> Patching LocalLLMClient for Release linkage"
"${REPO_ROOT}/Tools/patch_llm_client.sh"

# ── Register telemetry token (CI only) ────────────────────────────────────────
#
# In CI, a per-build token is generated and must be registered in the
# DynamoDB tokens table so the telemetry API accepts it. Requires
# TELEMETRY_API_TOKEN, TELEMETRY_TOKENS_TABLE, and TELEMETRY_TOKENS_REGION.
# Skipped for local/OSS builds where these are empty.

if [ -n "${TELEMETRY_API_TOKEN:-}" ] && [ -n "${TELEMETRY_TOKENS_TABLE:-}" ]; then
    echo ""
    echo "==> Registering telemetry token in DynamoDB"
    aws dynamodb put-item \
        --table-name "${TELEMETRY_TOKENS_TABLE}" \
        --item "{\"token\":{\"S\":\"${TELEMETRY_API_TOKEN}\"},\"active\":{\"BOOL\":true},\"pipeline_id\":{\"S\":\"${CI_PIPELINE_ID:-local}\"},\"created_at\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" \
        --region "${TELEMETRY_TOKENS_REGION:-us-east-1}"
fi

echo ""
echo "==> Building ${APP_NAME} ${VERSION}"

VERSION_OVERRIDES=()
if [ -n "${MARKETING_VERSION}" ]; then
    VERSION_OVERRIDES+=("MARKETING_VERSION=${MARKETING_VERSION}")
    echo "    MARKETING_VERSION=${MARKETING_VERSION}"
fi
if [ -n "${BUILD_NUMBER}" ]; then
    VERSION_OVERRIDES+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
    echo "    CURRENT_PROJECT_VERSION=${BUILD_NUMBER}"
fi

xcodebuild \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${BUILD_DIR}/derived" \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    ONLY_ACTIVE_ARCH=YES \
    TELEMETRY_API_DOMAIN="${TELEMETRY_API_DOMAIN}" \
    TELEMETRY_API_TOKEN="${TELEMETRY_API_TOKEN}" \
    "${VERSION_OVERRIDES[@]}" \
    clean build

APP_PATH="${BUILD_DIR}/derived/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
test -d "${APP_PATH}" || { echo "Build failed; app not found at ${APP_PATH}" >&2; exit 1; }

# ── CI Keychain (single lifecycle for both app and pkg signing) ───────────────
#
# When signing in CI mode, we create ONE keychain here and pass it to both
# sign_and_notarize.sh invocations. This avoids the Security daemon caching
# issue that causes set-key-partition-list to fail when a second keychain
# imports the same identity within the same session.

CI_KEYCHAIN=""
CI_KEYCHAIN_PASS=""

cleanup_ci_keychain() {
    if [[ -n "${CI_KEYCHAIN}" ]]; then
        echo "==> Cleaning up CI keychain"
        security delete-keychain "${CI_KEYCHAIN}" 2>/dev/null || true
    fi
}

if [ "${SIGN_MODE}" = "ci" ]; then
    trap cleanup_ci_keychain EXIT

    # Use CI_PIPELINE_ID to guarantee uniqueness when concurrent pipelines
    # land on the same Mac instance (date +%s can collide within the same second).
    CI_KEYCHAIN="${HOME}/Library/Keychains/signing-${CI_PIPELINE_ID:-$$}-$(date +%s).keychain-db"
    CI_KEYCHAIN_PASS="$(openssl rand -hex 16)"

    echo ""
    echo "==> Setting up CI signing keychain"

    # Remove any orphaned keychains from prior interrupted builds.
    for stale in "${HOME}"/Library/Keychains/signing-*.keychain-db; do
        if [ -e "$stale" ]; then
            security delete-keychain "$stale" 2>/dev/null || true
        fi
    done

    security create-keychain -p "${CI_KEYCHAIN_PASS}" "${CI_KEYCHAIN}"
    security set-keychain-settings -lut 3600 "${CI_KEYCHAIN}"
    security unlock-keychain -p "${CI_KEYCHAIN_PASS}" "${CI_KEYCHAIN}"

    # Pull secrets from AWS Secrets Manager
    P12_B64="$(aws secretsmanager get-secret-value \
        --region "${AWS_REGION:-eu-west-1}" \
        --secret-id "${SIGNING_SECRET_PREFIX:-quickgen/signing}/p12" \
        --query SecretString --output text)"

    P12_PASSWORD="$(aws secretsmanager get-secret-value \
        --region "${AWS_REGION:-eu-west-1}" \
        --secret-id "${SIGNING_SECRET_PREFIX:-quickgen/signing}/p12-password" \
        --query SecretString --output text)"

    INSTALLER_CER_B64="$(aws secretsmanager get-secret-value \
        --region "${AWS_REGION:-eu-west-1}" \
        --secret-id "${SIGNING_SECRET_PREFIX:-quickgen/signing}/cer-installer" \
        --query SecretString --output text)"

    # Import .p12 (private key + Developer ID Application cert)
    P12_FILE="$(mktemp).p12"
    printf '%s' "${P12_B64}" | base64 --decode > "${P12_FILE}"
    security import "${P12_FILE}" -k "${CI_KEYCHAIN}" -P "${P12_PASSWORD}" -T /usr/bin/codesign -T /usr/bin/productsign
    rm -f "${P12_FILE}"

    # Import Developer ID Installer cert
    INSTALLER_CER_FILE="$(mktemp).cer"
    printf '%s' "${INSTALLER_CER_B64}" | base64 --decode > "${INSTALLER_CER_FILE}"
    security import "${INSTALLER_CER_FILE}" -k "${CI_KEYCHAIN}" -T /usr/bin/codesign -T /usr/bin/productsign
    rm -f "${INSTALLER_CER_FILE}"

    # Import Apple Developer ID intermediate cert (chain validation)
    APPLE_CA_FILE="$(mktemp).cer"
    curl -sL "https://www.apple.com/certificateauthority/DeveloperIDCA.cer" -o "${APPLE_CA_FILE}"
    security import "${APPLE_CA_FILE}" -k "${CI_KEYCHAIN}" -T /usr/bin/codesign -T /usr/bin/productsign
    rm -f "${APPLE_CA_FILE}"

    # Allow codesign/productsign to access without prompt
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${CI_KEYCHAIN_PASS}" "${CI_KEYCHAIN}"

    # Add to search list
    EXISTING_KEYCHAINS="$(security list-keychains | tr -d '"' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    security list-keychains -s "${CI_KEYCHAIN}" ${EXISTING_KEYCHAINS}

    echo "    Keychain ready: ${CI_KEYCHAIN}"
fi

# ── Sign the .app (when --sign or --sign-local) ─────────────────────────────
#
# Must happen before pkgbuild so the signed binary ends up inside the .pkg.

if [ "${SIGN_MODE}" != "none" ]; then
    SIGN_SCRIPT="${PKG_ROOT}/sign_and_notarize.sh"

    SIGN_APP_ARGS=(--app-path "${APP_PATH}" --sign-app-only)
    if [ "${SIGN_MODE}" = "local" ]; then
        SIGN_APP_ARGS+=(--local)
    elif [ "${SIGN_MODE}" = "ci" ]; then
        SIGN_APP_ARGS+=(--keychain "${CI_KEYCHAIN}" --keychain-pass "${CI_KEYCHAIN_PASS}")
    fi

    echo ""
    echo "==> Signing .app (mode: ${SIGN_MODE})"
    "${SIGN_SCRIPT}" "${SIGN_APP_ARGS[@]}"
fi

# ── Stage component roots ───────────────────────────────────────────────────

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}/app-root/Applications"
mkdir -p "${DIST_DIR}/components"
mkdir -p "${DIST_DIR}/resources"

cp -R "${APP_PATH}" "${DIST_DIR}/app-root/Applications/"
cp "${PKG_ROOT}/resources/welcome.html"    "${DIST_DIR}/resources/welcome.html"
cp "${PKG_ROOT}/resources/conclusion.html" "${DIST_DIR}/resources/conclusion.html"

# ── App component ───────────────────────────────────────────────────────────
#
# Bundle Relocation: macOS Installer "smart-updates" an existing bundle
# anywhere on disk (including our repo's build/derived/ copy) instead
# of writing fresh to /Applications. We disable that by overriding
# BundleIsRelocatable=false in the component plist.
#
# Symptom if this is missing: install completes, receipt is written,
# but /Applications/FastLang.app doesn't exist. /var/log/install.log
# will show "Applications/FastLang.app relocated to ...".

COMPONENT_PLIST="${DIST_DIR}/app-component.plist"
pkgbuild --analyze --root "${DIST_DIR}/app-root" "${COMPONENT_PLIST}" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "${COMPONENT_PLIST}"

echo "==> Building app component"
chmod +x "${PKG_ROOT}/scripts/app/postinstall"
pkgbuild \
    --root "${DIST_DIR}/app-root" \
    --component-plist "${COMPONENT_PLIST}" \
    --scripts "${PKG_ROOT}/scripts/app" \
    --identifier "${BUNDLE_ID}.app" \
    --version "${VERSION}" \
    --install-location "/" \
    "${DIST_DIR}/components/app.pkg"

# ── Model components (marker-only, no payload) ──────────────────────────────

for model in model_e2b model_e4b; do
    echo "==> Building ${model} component"
    script_dir="${PKG_ROOT}/scripts/${model}"
    chmod +x "${script_dir}/postinstall"

    pkgbuild \
        --nopayload \
        --identifier "${BUNDLE_ID}.${model}" \
        --version "${VERSION}" \
        --scripts "${script_dir}" \
        "${DIST_DIR}/components/${model}.pkg"
done

# ── Distribution pkg ────────────────────────────────────────────────────────

echo "==> Building distribution package"
productbuild \
    --distribution "${PKG_ROOT}/Distribution.xml" \
    --package-path "${DIST_DIR}/components" \
    --resources "${DIST_DIR}/resources" \
    "${OUTPUT_PKG}"

echo ""
echo "Built: ${OUTPUT_PKG}"
ls -lh "${OUTPUT_PKG}"

# ── Sign .pkg and notarize (when --sign or --sign-local) ─────────────────────

if [ "${SIGN_MODE}" != "none" ]; then
    SIGN_SCRIPT="${PKG_ROOT}/sign_and_notarize.sh"

    SIGN_PKG_ARGS=(--app-path "${APP_PATH}" --pkg-path "${OUTPUT_PKG}" --sign-pkg-only)
    if [ "${SIGN_MODE}" = "local" ]; then
        SIGN_PKG_ARGS+=(--local)
    elif [ "${SIGN_MODE}" = "ci" ]; then
        SIGN_PKG_ARGS+=(--keychain "${CI_KEYCHAIN}" --keychain-pass "${CI_KEYCHAIN_PASS}")
    fi

    echo ""
    echo "==> Signing .pkg and notarizing (mode: ${SIGN_MODE})"
    "${SIGN_SCRIPT}" "${SIGN_PKG_ARGS[@]}"
fi

# ── Register release in DynamoDB (CI only) ────────────────────────────────────
#
# After a successful signed build, register the version in the releases
# table so the in-app update checker can discover it. Requires RELEASES_TABLE
# and MARKETING_VERSION. Skipped for local/OSS builds and unsigned builds.

if [ "${SIGN_MODE}" != "none" ] && [ -n "${RELEASES_TABLE:-}" ] && [ -n "${MARKETING_VERSION:-}" ]; then
    RELEASE_URL="${CI_PROJECT_URL:-}/-/releases/v${MARKETING_VERSION}/downloads/FastLang.pkg"
    echo ""
    echo "==> Registering release ${MARKETING_VERSION} in DynamoDB (${RELEASES_TABLE})"
    aws dynamodb put-item \
        --table-name "${RELEASES_TABLE}" \
        --item "{\"pk\":{\"S\":\"PLATFORM#macos\"},\"sk\":{\"S\":\"VERSION#${MARKETING_VERSION}\"},\"version\":{\"S\":\"${MARKETING_VERSION}\"},\"download_url\":{\"S\":\"${RELEASE_URL}\"},\"release_notes\":{\"S\":\"Release ${MARKETING_VERSION}\"},\"severity\":{\"S\":\"optional\"},\"created_at\":{\"S\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" \
        --region "${TELEMETRY_TOKENS_REGION:-us-east-1}"
fi

# ── Open installer (skipped with --build-only) ──────────────────────────────

if [ "${BUILD_ONLY}" -eq 0 ]; then
    echo ""
    echo "==> Opening installer"
    open "${OUTPUT_PKG}"
    echo ""
    echo "After install:"
    echo "  ls -la /Applications/${APP_NAME}.app"
    echo "  open /Applications/${APP_NAME}.app"
    echo ""
    echo "Troubleshooting: Tools/packaging/TROUBLESHOOTING.md"
    echo "Install log:     tail -50 /var/log/install.log"
fi
