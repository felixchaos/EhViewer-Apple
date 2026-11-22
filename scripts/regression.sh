#!/bin/bash
# Headless synthetic regression on macOS. Never boots a pre-existing simulator,
# signs an app, or runs live account/FileProvider tests.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
output_root=${EH_QA_OUTPUT_ROOT:-${TMPDIR:-/tmp}}
mkdir -p "$output_root"
out=$(mktemp -d "$(cd "$output_root" && pwd)/eh-regression.XXXXXX")
cache=${EH_QA_CACHE_ROOT:-$out}
mkdir -p "$cache"
cache=$(cd "$cache" && pwd)
jobs=${EH_QA_JOBS:-2}
project="ehviewer apple.xcodeproj"
scheme="ehviewer apple"
device=""
cleanup() {
    if [[ -n "$device" ]]; then xcrun simctl shutdown "$device" || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
status=0
run() {
    local check=$1
    shift
    if "$@" >"$out/$check.log" 2>&1; then
        printf 'PASS %s\n' "$check"
        return 0
    fi
    printf 'FAIL %s (%s/%s.log)\n' "$check" "$out" "$check" >&2
    status=1
    return 1
}

# Package tests can be used independently on macOS with no simulator.
printf 'Logs: %s\n' "$out"
printf 'Commit: %s\n' "$(git rev-parse HEAD)"
# Standalone SwiftPM resolves a different dependency graph than the Xcode
# workspace. Isolate its Package.resolved writes from the source checkout.
package_source="$out/package-source"
mkdir -p "$package_source"
tar --exclude .build --exclude .swiftpm -cf - Packages | tar -xf - -C "$package_source"
run EhCore swift test --package-path "$package_source/Packages/EhCore" --scratch-path "$cache/core" --jobs "$jobs" || true
run EhParser swift test --package-path "$package_source/Packages/EhParser" --scratch-path "$cache/parser" --jobs "$jobs" || true
run EhDownload swift test --package-path "$package_source/Packages/EhDownload" --scratch-path "$cache/download" --jobs "$jobs" || true
run EhNetwork swift test --package-path "$package_source/Packages/EhNetwork" --scratch-path "$cache/network" --jobs "$jobs" || true
run EhSpider swift test --package-path "$package_source/Packages/EhSpider" --scratch-path "$cache/spider" --jobs "$jobs" || true

if [[ ${1:-} == --packages-only ]]; then exit "$status"; fi
if [[ $# != 2 ]]; then
    cat >&2 <<'USAGE'
usage: scripts/regression.sh --packages-only
   or: scripts/regression.sh SIM_DEVICE_TYPE SIM_RUNTIME
Get identifiers from `xcrun simctl list devicetypes` and `xcrun simctl list runtimes`.
The runner uses one new synthetic simulator. It leaves it shut down for inspecting test failures.
USAGE
    exit 2
fi

common=(-project "$project" -configuration Release -jobs "$jobs" CODE_SIGNING_ALLOWED=NO)
if [[ -n ${EH_QA_PACKAGE_CHECKOUTS:-} ]]; then
    common+=(-clonedSourcePackagesDirPath "$EH_QA_PACKAGE_CHECKOUTS" -disableAutomaticPackageResolution)
fi
run macos-release xcodebuild build "${common[@]}" -scheme "$scheme" -destination 'platform=macOS' -derivedDataPath "$cache/mac" || true
run ios-release xcodebuild build "${common[@]}" -scheme "$scheme" -destination 'generic/platform=iOS' -derivedDataPath "$cache/ios" || true

if xcrun simctl list devices booted | grep -q '(Booted)'; then
    echo 'Simulator slot is occupied; no other device was started or stopped.' >&2
    exit 3
fi
device=$(xcrun simctl create "EhViewer Offline Regression $(date +%s)" "$1" "$2")
xcrun simctl bootstatus "$device" -b >"$out/simulator.log" 2>&1
printf 'Simulator: %s\n' "$device"
sim_build=(-destination 'generic/platform=iOS Simulator' ONLY_ACTIVE_ARCH=YES "ARCHS=$(uname -m)")
test_options=(-destination "id=$device" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1)

if run ios-unit-build xcodebuild build-for-testing "${common[@]}" -scheme "$scheme" "${sim_build[@]}" -derivedDataPath "$cache/unit" ENABLE_TESTABILITY=YES; then
    products="$cache/unit/Build/Products"
    original=$(find "$products" -maxdepth 1 -name '*.xctestrun' ! -name eh-offline.xctestrun -print -quit)
    python3 - "$original" "$products/eh-offline.xctestrun" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    config = plistlib.load(stream)
targets = [
    target for group in config["TestConfigurations"] for target in group["TestTargets"]
    if target.get("BlueprintName") == "ehviewer appleTests"
]
if len(targets) != 1:
    raise SystemExit("Could not verify the offline unit test host target")
for key in ("TestingEnvironmentVariables", "EnvironmentVariables"):
    targets[0].setdefault(key, {})["EH_OFFLINE_UNIT_TEST_HOST"] = "1"
with open(sys.argv[2], "wb") as stream:
    plistlib.dump(config, stream)
PY
    run ios-unit xcodebuild test-without-building -xctestrun "$products/eh-offline.xctestrun" "${test_options[@]}" \
        -resultBundlePath "$out/ios-unit.xcresult" '-skip-testing:ehviewer appleTests/CredentialStorageTests' || true
fi

# These UI tests opt in via their own launch environment. Do not run the default
# launch/performance UI target cases; they launch the normal app without a fixture.
if run ios-ui-build xcodebuild build-for-testing "${common[@]}" -scheme 'ehviewer offline UI' \
    "${sim_build[@]}" -derivedDataPath "$cache/ui" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) EH_OFFLINE_UI_FIXTURE'; then
    product=$(find "$cache/ui/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)
    run ios-ui xcodebuild test-without-building -xctestrun "$product" "${test_options[@]}" \
        -resultBundlePath "$out/ios-ui.xcresult" '-only-testing:ehviewer appleUITests/FavoritesOfflineUITests' || true
fi
printf '%s\n' 'Not covered: real sign-in/Keychain, system Files provider, actual servers, physical devices, macOS interactive UI.'
exit "$status"
