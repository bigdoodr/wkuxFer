#!/bin/bash
#
# Build, sign, notarize and staple the WKU app (runs on a macOS runner).
#
#   dist/signed/<App>-<version>.pkg   signed with Developer ID Installer, notarized, stapled
#   dist/signed/<App>-<version>.dmg   signed, notarized, stapled
#   dist/signed/SHA256SUMS
#   dist/signed/RELEASE_TITLE, RELEASE_NOTES.md   used by the workflow to create the GitHub release
#
# The app is built unsigned by xcodebuild and then signed here with codesign. That keeps CI independent of
# the project's own signing settings (Automatic / "Apple Development"), so WKU branding in the Xcode project
# and CI signing don't interfere with each other. The .app is signed and notarized once and stapled; the
# pkg and dmg are then built from THAT app.
#
# Environment:
#   VERSION          release version without the leading "v" (taken from the tag; the name of the files)
#   KEYCHAIN         keychain holding the Developer ID Application and Installer identities (unlocked)
#   NOTARY_PROFILE   notarytool keychain profile stored in that keychain (see .github/workflows/wku-release.yml)
#   SCHEME           Xcode scheme (default: "Data Shift")
#
# Usage: VERSION=2026.11.13.1500 KEYCHAIN=... NOTARY_PROFILE=... tools/ci-build-release.sh

set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${KEYCHAIN:?KEYCHAIN is required}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE is required}"
SCHEME="${SCHEME:-Data Shift}"

repoRoot="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "${repoRoot}"

out="dist/signed"
stage="dist/stage"
products="build/Build/Products/Release"

# Use the certificates' common names ("Developer ID Application: Name (TEAMID)").
identities="$( security find-identity -v "${KEYCHAIN}" )"
APP_ID="$( sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"${identities}" | head -1 )"
PKG_ID="$( sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' <<<"${identities}" | head -1 )"
[[ -n "${APP_ID}" ]] || { echo "::error::No 'Developer ID Application' identity in ${KEYCHAIN}"; exit 1; }
[[ -n "${PKG_ID}" ]] || { echo "::error::No 'Developer ID Installer' identity in ${KEYCHAIN}"; exit 1; }
echo "Signing as: ${APP_ID}"
echo "Packaging as: ${PKG_ID}"

notarize() {  # <file>
    local file="${1}" result status id
    echo "Notarizing ${file} (this can take several minutes)..."
    result="$( xcrun notarytool submit "${file}" --keychain-profile "${NOTARY_PROFILE}" --keychain "${KEYCHAIN}" \
        --wait --output-format json )" || true
    status="$( /usr/bin/plutil -extract status raw -o - - <<<"${result}" 2>/dev/null || echo Unknown )"
    id="$( /usr/bin/plutil -extract id raw -o - - <<<"${result}" 2>/dev/null || true )"
    if [[ "${status}" != "Accepted" ]]; then
        echo "::error::Notarization of ${file} finished as '${status}'"
        if [[ -n "${id}" ]]; then
            xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" --keychain "${KEYCHAIN}" || true
        else
            echo "${result}"
        fi
        exit 1
    fi
    echo "${file}: Accepted (${id})"
}

rm -rf build "${out}" "${stage}"
mkdir -p "${out}" "${stage}"

# 1. Build unsigned
echo "Building scheme '${SCHEME}'..."
set -o pipefail
xcodebuild build \
    -project migrator.xcodeproj \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    | tail -n 60

# The app's name is whatever the project produces (WKUxFerAsst.app on the WKU branch).
shopt -s nullglob
apps=( "${products}"/*.app )
shopt -u nullglob
(( ${#apps[@]} == 1 )) || { echo "::error::Expected exactly one .app in ${products}, found ${#apps[@]}"; exit 1; }
builtApp="${apps[0]}"
appName="$( basename "${builtApp}" .app )"
app="${stage}/${appName}.app"
ditto "${builtApp}" "${app}"

plist="${app}/Contents/Info.plist"
bundleId="$( /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" )"
appVersion="$( /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" )"
appBuild="$( /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" )"
echo "Built ${appName} ${appVersion} (build ${appBuild}), ${bundleId}"

# 2. Sign: nested code first, then the app, with hardened runtime and a secure timestamp.
entitlements=()
if [[ -f migrator/migrator.entitlements ]] && [[ "$( /usr/bin/plutil -convert json -o - migrator/migrator.entitlements )" != "{}" ]]; then
    entitlements=( --entitlements migrator/migrator.entitlements )
fi
while IFS= read -r -d '' nested; do
    codesign --force --options runtime --timestamp --keychain "${KEYCHAIN}" --sign "${APP_ID}" "${nested}"
done < <( find "${app}/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.dylib' \) \
            -not -path '*/Versions/*/*' -print0 2>/dev/null | sort -z -r )
codesign --force --options runtime --timestamp --keychain "${KEYCHAIN}" --sign "${APP_ID}" \
    ${entitlements[@]+"${entitlements[@]}"} "${app}"

# 3. Notarize and staple the app
ditto -c -k --keepParent "${app}" "${stage}/notarize.zip"
notarize "${stage}/notarize.zip"
rm -f "${stage}/notarize.zip"
xcrun stapler staple "${app}"

# 4. Installer package (built from the stapled app; this is the file Mosyle deploys)
pkg="${out}/${appName}-${VERSION}.pkg"
pkgroot="$( mktemp -d )"
cp -R "${app}" "${pkgroot}/"
pkgbuild \
    --root "${pkgroot}" \
    --install-location /Applications \
    --identifier "${bundleId}.pkg" \
    --version "${appVersion}" \
    --sign "${PKG_ID}" --keychain "${KEYCHAIN}" --timestamp \
    "${pkg}"
rm -rf "${pkgroot}"
notarize "${pkg}"
xcrun stapler staple "${pkg}"

# 5. Disk image
dmg="${out}/${appName}-${VERSION}.dmg"
hdiutil create -volname "${appName}" -srcfolder "${app}" -ov -format UDZO "${dmg}"
codesign --force --sign "${APP_ID}" --keychain "${KEYCHAIN}" --timestamp "${dmg}"
notarize "${dmg}"
xcrun stapler staple "${dmg}"

# 6. Verify everything before anything is published
echo "Verifying..."
codesign --verify --deep --strict --verbose=2 "${app}"
spctl --assess --type execute -vv "${app}"
xcrun stapler validate "${app}"
pkgutil --check-signature "${pkg}"
spctl --assess --type install -vv "${pkg}"
xcrun stapler validate "${pkg}"
codesign --verify --verbose=2 "${dmg}"
xcrun stapler validate "${dmg}"

( cd "${out}" && shasum -a 256 -- *.pkg *.dmg > SHA256SUMS )

# 7. Release title and notes for the workflow
upstream="$( tr -d '[:space:]' < .github/upstream-sync.base 2>/dev/null || true )"
printf '%s %s (build %s)' "${appName}" "${appVersion}" "${appBuild}" > "${out}/RELEASE_TITLE"
{
    echo "WKU build of IBM Data Shift, ${appVersion} (build ${appBuild}), bundle identifier \`${bundleId}\`."
    echo
    [[ -n "${upstream}" ]] && echo "Based on upstream [\`IBM/mac-ibm-migration-tool@${upstream:0:7}\`](https://github.com/IBM/mac-ibm-migration-tool/commit/${upstream})."
    echo
    echo "The .pkg and .dmg are signed with Developer ID and notarized by Apple. Checksums are in \`SHA256SUMS\`."
} > "${out}/RELEASE_NOTES.md"

echo "Signed artifacts:"; ls -la "${out}"
