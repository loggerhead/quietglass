# Rule refactor: behavior baseline and acceptance evidence

The goal is the complete rule-driven product described in the task specification,
including deletion of the old product state and UI. Adding core types alone does
not satisfy that goal. This matrix tracks the current implementation separately
from the required final behavior.

## Feature parity

| Existing behavior / configuration | Rule representation | Baseline source / tests | Integration gate |
| --- | --- | --- | --- |
| Manual screen blur, `privacyShortcut*` | manual → allDisplays → blur | AppModel.toggleInstantShield, PrivacyController.toggleInstant | Shortcut creates/activates a rule; one plan covers every display |
| Hold to peek, `peekShortcut*` | blur.peek.hold | PrivacyController.setPeeking, PrivacySurfaceTests | Clears only held manual rule; nearby/automatic protection remains |
| Area selection, `areaShortcut*` | manual → region(session) → blur | ProtectedAreaTests, PrivacyController.protectArea | Selection writes normalized geometry into a rule |
| Selected/front window | manual → window → blur | FrontWindowTests, CaptureVisibilityTests | Closed window removes session activation; occluded pixels stay clear |
| Focus | manual → allDisplaysExceptActiveWindow → blur | FocusWindowTests | Carve active window out of full-screen coverage; suspend head rules |
| AirPods / camera head tracking, `headTrackingSource`, comfort/transition/blur | headTurn → allDisplays/display → blur; calibration/permission guards | ShieldResponseTests, DisplayHeadTrackingTests, CameraHeadTrackingTests | Preserve calibration, directional feathering, fail-closed motion loss |
| Nearby, `nearbyEnabled/Response/Detection` | extraFace → allDisplays/window → blur/warnThenBlur/warnOnly | NearbyPeopleTests, NearbyPresenceTests, CameraTrackingTests | Sensors feed bus; engine owns warning/coverage state |
| Warning delay/sound, `nearbyWarningDelay/Sound` | action parameters | NearbyWarningPolicyTests, NearbyNoticeSoundTests | Escalate once; sound only when warning begins |
| Blur now in warning | global escalation of warning's rule | NearbyPeople.blurNow | No extra persistent rule; original scope retained |
| Owner recognition, `ownerRecognitionEnabled` | ownerVerification guard | OwnerRecognitionTests, OwnerRecognitionPolicyTests | Unknown/unavailable identity must not uncover; template stays in Keychain |
| OCR, `privacyScanEnabled/Options/CustomPhrases` | sensitiveText → detectedText → blur | SensitiveTextTests, LocalTextAnalyzerTests | One shared capture feeds OCR; no recognized text persisted |
| App windows, `privacyAppRules.protectWindows` | appEvent(windowOpened) → window → blur | PrivacyPolicyTests, ProtectedAreaTests | All matching visible windows, with occlusion |
| App stronger settings | higher-priority headTurn + appCondition + blur parameters | PrivacyPolicyTests.testStrongerRuleNeverWeakensExistingSettings | Adapter chooses applicable rule parameters before sensor policy evaluation |
| App pause head tracking | appEvent(activated) → pauseOtherProtection(target: headTurn) | FocusWindowTests, PrivacyPolicyTests | Pause only head rules; manual/OCR/nearby stay active |
| Saved areas, `privacySavedAreas` | windowTitle → region(rememberWindowTitle) → blur | PrivacyPolicyTests, ProtectedAreaTests | Digest-only matching survives restart without storing title |
| Home/Office/Public/Focus | preset rule packages + default blur parameters | NearbyPresenceTests, AppModel.applyProfile | Presets write rules/defaults; no separate runtime profile branch |
| Escape | global clear | ShieldResponseTests, NearbyPeopleTests | Clear immediately; AirPods rearm after center, camera/OCR/app rules need explicit resume |
| Pause/resume, `nearbyPauseUntil` | coordinator commands/deadline | NearbyPeopleTests | Pause dominates all rules; timed resume works across sleep |
| Recenter, `shortcut*`; display calibration | permissions/calibration tooling | HeadSetupPanelTests, HeadSetupProgressTests | Calibration infrastructure cannot render directly |
| Permission denial / unavailable Escape | guards + coordinator startup check | NearbyPeopleTests, ProtectionCheckTests | Do not claim active coverage if renderer cannot start safely |
| Sleep/session/display/Space changes | coordinator suspend/wake + geometry events | CameraHeadTrackingTests, ShieldSurfaceTests, NotchDockingTests | Preserve sensor fail-closed semantics and display surface pixels |
| Camera coverage check / 5-second preview | ephemeral manual rule + sensor test tooling | ProtectionCheckTests, ShieldSurfaceTests | Demonstration output also consumes ProtectionPlan |
| Appearance, capture sharing, notch position | versioned presentation/adapter preferences | NotchDockingTests, CaptureVisibilityTests | No protection decisions in presentation preferences |
| Login, about, updates, camera selection | Settings infrastructure | AppUpdatesTests, HeadSetupPanelTests | Existing network/privacy/permission behavior unchanged |

## Baseline and current verification

The original baseline had 183 tests (one profiling skip). The native Swift build
system is required here for the existing Core ML resource; plain swift test fails
planning SFace.mlmodel. The final complete debug run passed 272 tests with zero
failures/skips using QUIETGLASS_PROFILE=1 and the real preference copy. This includes
resume/wake/pause-expiry ordering, remembered regions, calibrated camera permission
loss, five rendered UI tests, and suspended-command/Escape precedence tests.
Existing dirty shortcut/UI work was carried into the rule recorder and registry.

## Acceptance audit

| Gate | Current authoritative evidence | Status |
| --- | --- | --- |
| AC-1 | RuleApplicationIntegrationTests; nearby/owner fixtures use NearbyRuleAdapter; core geometry/head/guard/sensitive-text tests | Passed mapped behavior and fresh resume/wake/pause-expiry context |
| AC-2 | No legacy-mode flag; old feature pages/profile popover/static shortcuts removed; only ScreenCaptureAdapter constructs DisplayCapture; nearby has no standalone state/preferences/timers | Source audit passed |
| AC-3 | ProtectionRuleTests enumerates all 168 primary combinations and modifier/guard constraints | Passed |
| AC-4 | ProtectionEngineTests and regional pixel/mask tests cover global commands, full-screen, focus, priority/creation order, unions and text/window overlap | Passed |
| AC-5 | ProtectionStoreTests covers empty/full/corrupt/repeated migration, rollback, real preference copy, and older v1 optional defaults; migration-error integration preserves data and starts no sensors | Passed |
| AC-6 | Five rendered RuleInterfaceTests exercise exactly Protection / Rules / Settings and navigate with mouse events | Passed |
| AC-7 | RuleEditingTests filters legal combinations and rejects invalid saves; native UI test saves through rendered button; presets share validator | Passed |
| AC-8 | Home/notch popover render active names, IDs, reasons and warning actions; rendered quick-action activation test checks the manual reason | Passed native rendered notch ID/name/reason test |
| AC-9 | New workspace/editor/preset/reason keys have zh-Hans entries; strings syntax/duplicates/placeholders audited; offline Help includes Chinese rule flow | Passed strings and packaged native Bundle lookup |
| AC-10 | privacy.md documents unchanged network/Keychain boundaries and no frame/OCR persistence; request/template/privacy tests pass | Source and behavior audit passed |
| AC-11 | One stream per display shared by all consumers; lifecycle mocks prove no duplicate starts; exact pixel parity; 100-rule evaluation 0.432 ms; 100 local crops 20.491 ms; four crops 4.174 ms vs four full frames 19.467 ms | Passed measured fixtures |
| AC-12 | Final debug suite passed 272 tests without skips/failures; release app/ZIP build and strict signature verification passed | Passed |

The capture benchmark uses a 1512×982 synthetic fixture, and the evaluator uses 100
active rules/two displays. Tests inject sensors/capture for lifecycle cases and use
actual Vision, native hosted UI/mouse events, rendering surfaces and an isolated
Keychain for relevant integration checks. This evidence does not claim live camera
accuracy or physically connected AirPods calibration beyond the reused algorithms.

## Final verification (2026-11-12)

All twelve gates above passed. Explicit resume, wake, and both pause-expiry clocks
prepend fresh display/window/permission/sensor context and submit only the final
plan. Expiry during suspension updates the queued user state without waking sources;
resume/pause/clear while suspended also wait for lifecycle wake. Escape wins over
ordinary activations within a batch. Calibrated camera rules retain coverage when
camera permission is lost or calibration restarts.

The full suite command was:

```sh
QUIETGLASS_PROFILE=1 \
QUIETGLASS_MIGRATION_PREFS_PATH=/tmp/quietglass-real-preferences-copy.plist \
  swift test --build-system native
```

Evidence: `/tmp/quietglass-final-full-tests.log` (272 tests, zero failures/skips),
`/tmp/quietglass-final-production-build.log`, and the native UI snapshots described
in RuleInterfaceTests. `bash build.sh /tmp/QuietGlass-rule-refactor.app` produced the
release app and ZIP. Localization checks cover unique keys, matching format
arguments, direct QG lookups, and native packaged zh-Hans strings.

The local build uses an ad-hoc identity, so the build script omits AppIntents
metadata requiring an Apple developer Team ID. The Pause intent source and its
rule-engine behavior passed integration tests. This is the existing build/signing
constraint; release signing and physical camera/AirPods use were not exercised.


## Notch follow-up (2026-11-12)

The expanded notch now has three controls: Automatic detection (a toggle using
head-turn rules and the existing start/stop/calibration flow), Settings, and Blur
an Area. The area control opens secondary options for area selection, window
protection, full-screen blur, and focus. The prior preview/direct full-screen
button is removed from this compact bar; full-screen blur remains a scope option.
Settings opens the existing Settings destination.

The follow-up full regression passed 275 tests with zero failures/skips in
`/tmp/quietglass-notch-final-tests.log`. Native mouse tests exercise the three
compact hit targets, Settings, opening the submenu without activating protection,
and choosing full-screen blur. A camera lifecycle fixture verifies toggling head
detection leaves manually activated protection intact. UI artifacts are
`/tmp/quietglass-rule-ui-notch-bar.png` and
`/tmp/quietglass-rule-ui-notch-area-options.png`.

## Region editor follow-up (2026-11-12)

The requested Select region option is available to manual and nearby-face rules,
including the nearby rule shown in the scope-step screenshot. Selection works on
any display and the editor shows its actual available global shortcut at the
right. The new additive display-region scope is validated and persisted through
the existing v1 document; existing window scopes and old documents still load.
The trigger/scope/action matrix now checks 168 combinations.

The full regression passed 281 tests with no failures/skips in
`/tmp/quietglass-region-final-tests.log`. Native panel events verify reverse
dragging on a second display, first-click selection, and Escape cancellation.
Carbon tests verify shortcut borrowing, occupied-chord fallback and release.
Rendered editor mouse tests select a nearby rule's region without changing the
document, then Save rule commits it. Engine tests cover warning escalation,
display-relative geometry changes, disconnected displays and JSON roundtrip.
Updated UI snapshots: `/tmp/quietglass-rule-ui-editor-select-region.png` and
`/tmp/quietglass-rule-ui-editor-selected-region.png`.

## Presentation-only follow-up (2026-11-12)

The three workspace pages, rule editor and notch panels now share restrained
dark cards, a soft pink accent, aligned settings rows, descriptive action tiles
and natural When / Where / Response labels. Advanced matching, coordinates and
rule IDs remain available through expandable details. Existing operation
callbacks, values, validation and the complete runtime path are preserved.

A pre-edit SHA-256 manifest verifies 59 protected source sections unchanged,
including the engine/store/coordinator, AppModel, event/capture/sensor sources,
notch controller and editor save/selection/application-picker handlers. The
full regression passed 281 tests with zero failures/skips in
`/tmp/quietglass-ui-polish-full-tests.log`; eight native rendered/click-driven
UI tests pass with the new layout and accessible rule details. The release
app/ZIP build passed (`/tmp/quietglass-ui-polish-production-build.log`).

943 localization keys have unique names and matching format arguments; every
direct QG call has a translation. An isolated preview application linked the
current debug objects with a Chinese bundle and no capture executor, producing
actual Chinese rendered previews without using the real preference domain:
`/tmp/quietglass-ui-zh-protection.png`, `/tmp/quietglass-ui-zh-rules.png`,
`/tmp/quietglass-ui-zh-settings.png`, and `/tmp/quietglass-ui-zh-editor.png`.

## Navigation and feature clarity follow-up

The same three destinations are presented as Screen controls (手动遮挡与状态),
Auto & shortcuts (自动检测与快捷键), and Settings. Internal page identifiers and
all actions remain unchanged. Sidebar rows use fixed 24-point icon frames,
56-point row heights, identical typography and a common text start; the selected
marker is an overlay and does not shift content. Native rendered tests check
left-edge alignment and equal vertical spacing.

Screen controls describes each manual scope and the difference between clearing,
pausing and resuming. Saved setups explain when they respond and what they do;
the switch allows a setup to work, while manual actions have a separate Use now
button. The editor distinguishes immediate warning from delayed blur and makes
clear that a warn-only countdown never turns on blur. Existing calibration and
connection hints are retained.

The full regression passed 281 tests without failures or skips in
`/tmp/quietglass-clarity-full-tests.log`. The final UI checks additionally cover
new labels, selection, saved rule identity, accessible IDs and aligned navigation.
Protected source sections remain unchanged; only the two display captions in
the app/context menu were normalized when comparing their file hashes.

## Rule interaction and usability corrections (2026-11-12)

The notch automatic switch now disables only IDs in the current automatic plan
and restores that same group; unrelated automatic and manual setups retain their
flags. With no command target, the workspace opens with an explanatory notice.
The original image/video blur-strength preview is back in Settings.

All configurable shortcuts default to empty. Older documents clear prior manual,
peek, recenter, and region-selection bindings once, then preserve new assignments.
Escape remains the emergency clear route. Native Carbon registration removes old
recenter bindings when cleared and releases selection leases during recording.

Settings shows missing screen/camera permissions with red dots and grant actions.
Enabling dependent rules invokes permission guidance; warning-only upgrades also
request screen access when needed. Preset clicks show feedback, highlight and
scroll to the enabled setup, and reuse persisted identities across launches.
Editing uses an atomic sheet session and keeps the original name, ID, timestamps,
action, and conditions. Extra requirements explain app restrictions, allowed hours,
and priority; permission and pause checks are grouped under advanced options.

Display-region selection draws a dashed accent border, corner marks, and caption
while editing. Its panel is non-key, click-through and excluded from recordings,
and closes on editor dismissal. Custom switches keep their enabled accent when
the application loses focus.

The full native regression passed **294 tests, zero failures or skips**, including
real-sheet editing, repeated preset activation, inactive-window pixel color,
permission guidance, current-automatic-only toggling, region geometry/cleanup,
one-time shortcut reset, and the isolated real preference-copy migration:
`/tmp/quietglass-nine-full-tests.log`. Rule evaluation averaged 0.393 ms/frame for
100 active rules across two displays in that run. Localization has 1063 unique
keys, matching format arguments, and no missing direct QG calls. Actual Chinese
rendered fixtures are `/tmp/quietglass-ui-zh-settings.png` and
`/tmp/quietglass-ui-zh-blur-preview.png`, alongside workspace/editor snapshots.
The signed release bundle built and passed strict codesign verification via
`/tmp/quietglass-nine-production-build.log`; delivery is `~/Downloads/QuietGlass.app`.

## Visual layout refinement (2026-11-12)

The workspace now uses cool charcoal surfaces and a restrained lavender accent,
with larger explanation text, consistent section headings, and aligned sidebar
rows. Manual actions and preset templates sit directly in two-column grids without
an enclosing card; global commands use smaller tiles. Settings separates screen/
camera access from device calibration and face setup, bringing the original blur
preview closer to the top. The editor has a unified step strip. Preview captions
use dark backplates to remain readable over bright sample content.

The full regression passed 294 tests with no failures or skips in
`/tmp/quietglass-design-full-tests.log`. A source/handler manifest confirms 71
runtime source and operation-handler sections unchanged from before this visual
pass. Localized renders are `/tmp/quietglass-ui-zh-protection.png`,
`/tmp/quietglass-ui-zh-rules.png`, `/tmp/quietglass-ui-zh-settings.png`, and
`/tmp/quietglass-ui-zh-blur-preview.png`. The isolated preview fixture uses the
existing still-image branch for NSView snapshots, which cannot capture AVPlayer
layers; the production video preview is preserved. The final preview-caption
adjustment is covered by `/tmp/quietglass-design-final-ui-tests.log`.

## Compact unified saved-setup list (2026-11-12)

Saved setups now appear in document order in a single list without trigger-group
cards. Inline badges distinguish manual actions from automatic trigger types.
Each item uses two primary rows: name/type/access/switch, then scope/action and
commands. The repeated response paragraph is available as a hover explanation
and accessibility hint. Extra conditions move to an accessible compact menu in
the header; grant access, Use now/Stop, Edit, Delete and remembered-area actions
retain their callbacks. Preset scroll/highlight and original edit identities stay
intact. The existing rendered UI checks pass in
`/tmp/quietglass-compact-list-ui-tests.log`. Production bundle builds through
`/tmp/quietglass-compact-list-build.log` and is delivered to the fixed Downloads
path. Chinese list snapshot: `/tmp/quietglass-ui-zh-compact-list.png`.

## Permission refresh and truthful access status (2026-11-13)

System authorization is now distinct from a rejected capture session. A newly
observed screen grant clears the stale denial and retries capture; returning to
the app explicitly retries a rejected authorized session. Ordinary polling never
repeatedly retries the same rejected session. Screen and camera authorization are
published together, so changing camera access outside QuietGlass refreshes rows.
A rejected session still blocks screen output in the rule engine until retried.

Saved rows name the missing access. Their readable requirements popover shows
Granted/Not granted for each required permission and Running/Not running for the
pause check. An authorized but rejected screen session has an amber restart hint
and restart action, separate from the red missing-permission prompt. Settings
shows a granted checkmark instead of asking for Screen Recording access again.

The ordinary regression executed 246 tests with no failures; 3 opt-in performance
or real-preference-copy tests were skipped. Five RulePermissionStateTests cover
stale denial recovery, independent camera/screen changes, retry idempotency,
motion access, and engine gating during failed capture. Log:
`/tmp/quietglass-permission-refresh-tests.log`. No desktop integration tests or
system permission changes were performed on the user's active desktop. Release
build log: `/tmp/quietglass-permission-refresh-build.log`.

## Fresh access verification on every launch (2026-11-13)

Every production AppModel starts a fresh ScreenCaptureKit shareable-content query
before configuring enabled rules, alongside fresh Core Graphics and camera
preflights. The query enumerates metadata; it captures no images, creates no
additional stream, and stores no window or application information. Startup
permission guidance waits for the query, rather than treating an unfinished
preflight as a denial.

A successful ScreenCaptureKit query can confirm access when the Core Graphics
preflight reports false. That evidence remains valid through repeated false
preflight polling, belongs only to the current process, and is invalidated by an
actual capture rejection or observed preflight revocation. Returning to the app
checks again. A check has a 10-second deadline; unavailable service results are
shown as unknown with Check again, and cancellation generations reject late
results. Permission verification never grants output on unknown or denied access.

The ordinary regression executed 252 tests with zero failures, with 3 opt-in
performance/private-preference tests skipped. New checks cover fresh-launch
verification, stale false-preflight polling, revocation, cancellation, unknown
service errors, explicit denial, and duplicate-check prevention. Log:
`/tmp/quietglass-startup-permission-tests.log`. Release log:
`/tmp/quietglass-startup-permission-build.log`. Real desktop/TCC authorization is
left to the current app process; the test suite uses injected verification and
does not activate a desktop window or request real capture access.
