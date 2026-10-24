#!/usr/bin/env bash
#
# Builds, signs, notarizes and packages Dev Mail for release.
#
# Run from anywhere; paths are resolved relative to the repo root. Used by
# `make release-local` and .github/workflows/release.yml.
#
# Environment:
#   VERSION                  Required. Marketing version, MAJOR.MINOR.PATCH.
#   BUILD_NUMBER             Optional. CFBundleVersion, digits only. Default: 1.
#
#   Developer ID signing (both or neither; ad-hoc signing otherwise):
#   DEVELOPER_ID_IDENTITY    e.g. "Developer ID Application: Name (TEAMID1234)"
#   DEVELOPMENT_TEAM         10-character Apple team ID.
#
#   Notarization (requires Developer ID signing; skipped when unset). Either
#   an App Store Connect API key (all three):
#   NOTARY_KEY_ID            API key ID.
#   NOTARY_ISSUER_ID         API key issuer ID.
#   NOTARY_KEY_PATH          Path to the AuthKey_<id>.p8 file.
#   or, for local use, a profile saved with `xcrun notarytool store-credentials`:
#   NOTARY_KEYCHAIN_PROFILE  Keychain profile name.
#
#   REQUIRE_NOTARIZATION     Optional. "true" fails instead of falling back to
#                            an unsigned or un-notarized build (set in CI).
#
# Output: build/release/DevMail-<version>.zip and DevMail-<version>.zip.sha256

set -euo pipefail

readonly APP_NAME="Dev Mail"
readonly SCHEME="DevMail"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
readonly out_dir="$root/build/release"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Values that only matter together must all be set or all be unset.
all_or_none() {
  local group="$1"
  shift
  local set=0 name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] && set=$((set + 1))
  done
  if ((set != 0 && set != $#)); then
    die "$group needs all of: $* (got $set of $#)"
  fi
  ((set == $#))
}

# --- Inputs -----------------------------------------------------------------

version="${VERSION:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "VERSION must be MAJOR.MINOR.PATCH (got '${version}')"

build_number="${BUILD_NUMBER:-1}"
[[ "$build_number" =~ ^[0-9]+$ ]] ||
  die "BUILD_NUMBER must be digits only (got '${build_number}')"

require_notarization=false
case "${REQUIRE_NOTARIZATION:-false}" in
  true | 1) require_notarization=true ;;
  false | 0 | "") ;;
  *) die "REQUIRE_NOTARIZATION must be true or false" ;;
esac

signed=false
if all_or_none "Developer ID signing" DEVELOPER_ID_IDENTITY DEVELOPMENT_TEAM; then
  [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] ||
    die "DEVELOPMENT_TEAM must be a 10-character team ID"
  [[ "$DEVELOPER_ID_IDENTITY" == "Developer ID Application:"* ]] ||
    die "DEVELOPER_ID_IDENTITY must be a 'Developer ID Application: ...' identity"
  signed=true
fi

notary_args=()
if all_or_none "Notarization" NOTARY_KEY_ID NOTARY_ISSUER_ID NOTARY_KEY_PATH; then
  [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]] ||
    die "set either the NOTARY_KEY_* variables or NOTARY_KEYCHAIN_PROFILE, not both"
  [[ -f "$NOTARY_KEY_PATH" ]] || die "NOTARY_KEY_PATH does not exist"
  notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
fi

if ((${#notary_args[@]} > 0)) && [[ "$signed" != true ]]; then
  die "notarization credentials are set but Developer ID signing is not; ad-hoc builds cannot be notarized"
fi

if [[ "$require_notarization" == true ]] && ((${#notary_args[@]} == 0)); then
  die "REQUIRE_NOTARIZATION is set but Developer ID signing and/or notarization credentials are missing"
fi

for tool in xcodegen xcodebuild ditto shasum codesign plutil; do
  command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

# --- Build ------------------------------------------------------------------

readonly archive="$out_dir/$SCHEME.xcarchive"
readonly export_dir="$out_dir/export"
readonly app="$export_dir/$APP_NAME.app"
readonly zip="$out_dir/DevMail-$version.zip"

work_dir="$(mktemp -d)"
readonly work_dir
trap 'rm -rf "$work_dir"' EXIT

log "Building $APP_NAME $version ($build_number)"
rm -rf "$out_dir"
mkdir -p "$out_dir"

cd "$root"
xcodegen generate --quiet

sign_settings=(CODE_SIGN_STYLE=Manual)
if [[ "$signed" == true ]]; then
  log "Signing with $DEVELOPER_ID_IDENTITY"
  sign_settings+=(
    "CODE_SIGN_IDENTITY=$DEVELOPER_ID_IDENTITY"
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
else
  warn "DEVELOPER_ID_IDENTITY/DEVELOPMENT_TEAM not set: building an UNSIGNED (ad-hoc) app."
  warn "Gatekeeper will block it on other Macs. Do not publish this build."
  sign_settings+=("CODE_SIGN_IDENTITY=-" "DEVELOPMENT_TEAM=")
fi

xcodebuild archive \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$archive" \
  -derivedDataPath "$out_dir/DerivedData" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  "MARKETING_VERSION=$version" \
  "CURRENT_PROJECT_VERSION=$build_number" \
  "${sign_settings[@]}"

if [[ "$signed" == true ]]; then
  # Let Xcode re-sign for distribution; it applies the hardened runtime and a
  # secure timestamp to every nested binary.
  export_options="$work_dir/ExportOptions.plist"
  plutil -create xml1 "$export_options"
  plutil -insert method -string developer-id "$export_options"
  plutil -insert signingStyle -string manual "$export_options"
  plutil -insert signingCertificate -string "$DEVELOPER_ID_IDENTITY" "$export_options"
  plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$export_options"

  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options"
else
  mkdir -p "$export_dir"
  ditto "$archive/Products/Applications/$APP_NAME.app" "$app"
fi

[[ -d "$app" ]] || die "expected $app after export"

# --- Verify -----------------------------------------------------------------

log "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$app"

signature="$(codesign --display --verbose=4 "$app" 2>&1)"
grep -q 'flags=.*runtime' <<<"$signature" || die "hardened runtime is not enabled"
if [[ "$signed" == true ]]; then
  grep -q "^TeamIdentifier=$DEVELOPMENT_TEAM\$" <<<"$signature" || die "unexpected team identifier"
  grep -q '^Timestamp=' <<<"$signature" || die "signature has no secure timestamp"
fi

plist="$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw "$plist")" == "$version" ]] ||
  die "CFBundleShortVersionString does not match $version"
[[ "$(plutil -extract CFBundleVersion raw "$plist")" == "$build_number" ]] ||
  die "CFBundleVersion does not match $build_number"

# --- Notarize ---------------------------------------------------------------

if ((${#notary_args[@]} > 0)); then
  log "Submitting for notarization"
  submission="$work_dir/notarize.zip"
  ditto -c -k --keepParent "$app" "$submission"

  result="$work_dir/notarize.json"
  xcrun notarytool submit "$submission" "${notary_args[@]}" \
    --wait --timeout 30m --output-format json >"$result"
  status="$(plutil -extract status raw "$result")"
  submission_id="$(plutil -extract id raw "$result")"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
    die "notarization finished with status '$status' (submission $submission_id)"
  fi
  log "Notarization accepted (submission $submission_id)"

  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  spctl --assess --type execute -vv "$app"
else
  warn "notarization credentials not set: skipping notarization and stapling."
fi

# --- Package ----------------------------------------------------------------

log "Packaging $(basename "$zip")"
ditto -c -k --keepParent "$app" "$zip"
(cd "$out_dir" && shasum -a 256 "$(basename "$zip")" >"$(basename "$zip").sha256")

log "Done"
cat "$zip.sha256"
if [[ "$signed" != true ]]; then
  warn "this build is UNSIGNED (ad-hoc) and not notarized."
elif ((${#notary_args[@]} == 0)); then
  warn "this build is signed but NOT notarized."
fi
