#!/bin/bash
# Default regression: no desktop interaction or system integration target.
set -euo pipefail
cd "$(dirname "$0")/.."
unset QUIETGLASS_DESKTOP_TESTS QUIETGLASS_TEST_DESKTOP
exec swift test --build-system native --scratch-path "${QUIETGLASS_TEST_BUILD_DIR:-.build/background-tests}" "$@"
