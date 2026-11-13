# Testing QuietGlass without interrupting the work desktop

The default suite exercises rules, persistence, validation, rendering calculations,
and controls without activating an application or showing a window. Real desktop
interaction is a separate, explicit operation on the current Mac.

## Default regression

```sh
scripts/test.sh
```

Plain `swift test --build-system native` also excludes desktop tests. The optional
`QuietGlassDesktopTests` target is not in the package unless
`QUIETGLASS_DESKTOP_TESTS=1` is set. The wrapper unsets desktop flags and keeps its
build products separate from normal application builds.

`RuleInterfaceTests` renders `NSHostingView` components without attaching them to
an `NSWindow`. It checks enabled-switch color, English/Chinese control rendering,
permission controls, and pure region geometry. It also asserts that rendering
neither presents windows nor activates its process. These checks need AppKit but
do not simulate user input. For inspectable rendering artifacts:

```sh
QUIETGLASS_RENDER_ARTIFACTS=/tmp/quietglass-renders scripts/test.sh --filter RuleInterfaceTests
```

The PNGs are visual inspection artifacts, not an established golden-image baseline.
Performance profiling and real preference-copy migration remain optional tests:
`QUIETGLASS_PROFILE=1` and `QUIETGLASS_MIGRATION_PREFS_PATH` enable them.

## Compile UI automation without running it

```sh
scripts/test-desktop.sh --prepare-ui
```

This prepares an Xcode project and runs `build-for-testing`. It does not launch
an application or execute UI tests. No XcodeGen, VM, or third-party automation
app is required. Xcode and the installed Swift toolchain are sufficient.

The generated project links current SwiftPM debug objects into a test-only host,
excluding `QuietGlassApp.swift.o`. Its bundle ID is `local.quietglass.tests.host`,
its preferences use a disposable suite, and capture, camera access, permission
requests, and owner-template storage are faked. The production app and its
installed preference domain are not launched or edited.

The host contains the actual workspace/editor/notch views plus a test-only status
footer. XCUITest queries accessibility identifiers and elements for navigation,
preset identity, editing, region confirmation, and notch actions. Screenshot OCR
and text-derived click coordinates are no longer the interaction driver.

## Explicit desktop execution on this Mac

Run these when the desktop can be used by the tests:

```sh
# Low-level panels, system hotkeys, capture/surface integration, and isolated keychain.
scripts/test-desktop.sh --integration --interactive

# Native accessibility-based UI automation.
scripts/test-desktop.sh --ui --interactive

# Both groups.
scripts/test-desktop.sh --all --interactive
```

These tests **can activate windows, change focus, show selection/blur panels, and
reserve global keys while they run**. They cannot run unobtrusively on the same
active desktop. The explicit `--interactive` flag is required even if `CI=true`.
`--isolated` is available if a dedicated desktop is introduced later; it is an
operator declaration, not detection or proof of VM isolation.

The XCTest classes and UI host reject execution without a matching desktop-mode
flag, so accidentally discovering the optional target cannot show its windows.
UI tests run serially, have execution timeouts, and produce an `.xcresult` bundle.
The low-level integration group retains panel geometry, click-through/sharing
properties, source lifecycle, and native hotkey registration coverage. Mocked
screen streams still create real overlay panels, so those checks belong here.

The app's real screen/camera permissions, physical camera, AirPods, and multiple
connected displays need separate manual acceptance. Fixture success cannot prove
those hardware paths work.

## Build and result locations

Default checks use `.build/background-tests`; desktop compilation uses
`.build/desktop-tests`. Override them with `QUIETGLASS_TEST_BUILD_DIR` and
`QUIETGLASS_DESKTOP_BUILD_DIR`. Generated Xcode projects, fixture apps, and result
bundles stay in these ignored directories. The test fixture is never delivered as
`~/Downloads/QuietGlass.app` or used to replace the production application.

## Verification of the split (2026-11-12)

The background suite passed 241 tests with zero failures. Three opt-in checks
(profiling and private preference-copy migration) were skipped. Its render checks
produced seven component PNGs without presenting windows or activating the test
process. The 47 desktop integration checks compiled, and a selected region test
without desktop opt-in was rejected in setup before creating its panel. The
native test host and six accessibility-driven XCUITest cases passed
`build-for-testing`; runner environment propagation was checked in `.xctestrun`.
Real XCUITest interactions were not executed as part of this verification.
