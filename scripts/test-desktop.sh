#!/bin/bash
# Real interaction is explicit. --prepare-ui only compiles and never launches.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=""
desktop=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prepare-ui|--integration|--ui|--all) mode="$1" ;;
        --interactive) desktop=interactive ;;
        --isolated) desktop=isolated ;;
        *) printf '%s\n' 'Usage: scripts/test-desktop.sh --prepare-ui | (--integration|--ui|--all) (--interactive|--isolated)' >&2; exit 2 ;;
    esac
    shift
done
if [[ -z "$mode" ]]; then
    printf '%s\n' 'Select --prepare-ui, --integration, --ui, or --all.' >&2; exit 2
fi
if [[ "$mode" != --prepare-ui && -z "$desktop" ]]; then
    printf '%s\n' 'Desktop tests create windows and use keyboard focus. Add --interactive to explicitly use this Mac, or --isolated for a dedicated session.' >&2; exit 2
fi
build_dir="${QUIETGLASS_DESKTOP_BUILD_DIR:-$PWD/.build/desktop-tests}"
ui_dir="$build_dir/ui-project"
export QUIETGLASS_TEST_DESKTOP="$desktop"
if [[ "$mode" == --integration || "$mode" == --all ]]; then
    QUIETGLASS_DESKTOP_TESTS=1 swift test --build-system native --scratch-path "$build_dir/swiftpm" --filter QuietGlassDesktopTests
fi
if [[ "$mode" == --prepare-ui || "$mode" == --ui || "$mode" == --all ]]; then
    python3 scripts/prepare-ui-tests.py --output "$ui_dir" --scratch-path "$build_dir/swiftpm"
    # Remove only obsolete preview libraries from earlier fixture builds.
    # The test host deliberately disables Xcode's debug dylib packaging.
    rm -f "$build_dir/xcode/Build/Products/Debug/QuietGlassUITestHost.app/Contents/MacOS/__preview.dylib"
    xcodebuild build-for-testing -project "$ui_dir/QuietGlassUITests.xcodeproj" -scheme QuietGlassUITests \
        -destination 'platform=macOS' -derivedDataPath "$build_dir/xcode" \
        QUIETGLASS_TEST_DESKTOP="$desktop"
    if [[ "$mode" != --prepare-ui ]]; then
        results="$build_dir/Results-$(date +%Y%m%d-%H%M%S).xcresult"
        xcodebuild test-without-building -project "$ui_dir/QuietGlassUITests.xcodeproj" -scheme QuietGlassUITests \
            -destination 'platform=macOS' -derivedDataPath "$build_dir/xcode" \
            -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
            -resultBundlePath "$results" QUIETGLASS_TEST_DESKTOP="$desktop"
    fi
fi
