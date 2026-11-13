# QuietGlass

**Privacy for what’s on your Mac.**

[Download for Mac](https://github.com/clintonimaroo/quietglass/releases/download/v0.1.2/QuietGlass-0.1.2-macOS-universal.dmg) · [Release notes](https://github.com/clintonimaroo/quietglass/releases/tag/v0.1.2)

**0.1.2 · Build 3** · macOS 14 or later · Apple silicon and Intel

QuietGlass is an open-source, native macOS app that helps keep your work private in cafés, shared offices, classrooms, and other places where people can see your screen. Choose compatible AirPods or a camera to blur your displays when you look away and clear them when you look back.

Privacy also matters while you’re looking at your screen. **Nearby people spots another face in your camera’s view and warns you or blurs the screen, even while you’re still looking.** It works without AirPods. Optional **Recognize me** checks your saved face and a short movement sequence before clearing the camera response.

For everyday control, blur every display instantly, protect a specific window or selected area, blur detected sensitive text, or use **Focus mode** to keep the active window clear while its surroundings fade away. Use Screen controls for current status and manual actions, Auto & shortcuts to configure automatic responses and shortcuts, and Settings for calibration and appearance. Screen content, camera frames, and motion data are processed on your Mac.

<p align="center">
  <img src="media/quietglass-demo.webp" alt="QuietGlass look-away blur, nearby-person alerts, window protection, Focus mode, and notch controls" width="960">
</p>

## Features

| Feature | What it does |
| --- | --- |
| Look-away protection | Uses Camera or AirPods, with calibration, brief-glance filtering in Camera mode, and smooth blur transitions. |
| Instant privacy | Blurs your displays with a keyboard shortcut or the on-screen controls. |
| Window and area protection | Covers a selected window or area; saved areas return for matching window titles after relaunch. |
| Focus mode | Keeps the active window clear while blurring surrounding content. |
| Protection profiles | Provides Home, Office, Public, and Focus presets, with adjustable blur and sensitivity. |
| App rules | Sets head-tracking sensitivity per app and can automatically blur its visible windows. |
| Sensitive text detection | Identifies supported sensitive content and custom phrases using local text recognition. |
| Nearby people | Tracks additional faces and their estimated head direction; offers Facing screen or Any extra face detection. |
| Recognize me | Adds optional owner face enrollment and matching to camera-based protection. |
| Camera coverage check | Choose a camera, preview visible faces, check both sides, and try your response. |
| Warning actions | Open the notch rule controls to upgrade a warning, pause, or resume. |
| Everyday use | Optional launch at login and in-app checks for newer public releases. |

## Getting started

### Requirements

- macOS 14 or later
- Compatible AirPods or a camera for head tracking
- A camera for Nearby people and Recognize me

Manual screen blur, window protection, area protection, and Focus mode work without AirPods or a camera.

### Installation

1. Download the DMG above, open it, and drag **QuietGlass** into **Applications**. A [ZIP](https://github.com/clintonimaroo/quietglass/releases/download/v0.1.2/QuietGlass-0.1.2-macOS-universal.zip) is also available. Quit an older copy before replacing it.
2. Open QuietGlass from Applications, then eject the installer.
3. Grant **Screen Recording** access when prompted. Allow Camera or Motion & Fitness only for the features you enable.
4. Use the QuietGlass menu bar icon or hover over the floating control bar to open controls and Settings.

The current download is locally signed and not Apple-notarized. If macOS blocks the first launch, follow the **Open Anyway** instructions included in the download.

Choose **QuietGlass Help** from the menu for an offline setup and troubleshooting guide. Closing Settings keeps QuietGlass running; choose **Quit QuietGlass** to stop it. Enable **Launch at login** in **Settings → General and appearance** if desired. Use **Check for Updates…** to check for a newer public release, then download it, quit the app, and replace it in Applications. Automatic checks are optional; installation is manual. Your preferences stay on your Mac.

### Protect with rules

The notch automatic-detection switch changes only currently active automatic setups and can restore those same setups; other switches stay as configured.

The workspace has three destinations: **Screen controls**, **Auto & shortcuts**, and **Settings**.

For manual and nearby-face rules, **Scope → Select region** opens screenshot-style selection on every display. Set its global shortcut to the right of the button to select while working on another display. A dashed border and caption mark the chosen region while editing. Selection updates the rule draft; **Save rule** commits it. Display regions stay relative to their selected display, while window regions continue to follow their matching windows.
Closing it keeps protection running.

- **Screen controls** shows active rule names, IDs, reasons, display coverage, and warnings. Use **Blur screen now**, **Select an area**, **Protect a window**, or **Focus** to activate or create manual rules. **Pause**, **Resume**, and **Clear all · Escape** apply globally.
- **Auto & shortcuts** offers **Someone nearby**, **Look away**, **Sensitive information**, and **Focus** presets. Click a preset to enable and highlight its saved setup. Repeated clicks reuse the same identity and preserve edits. Then use **Edit…** to adjust its trigger, scope, action, and extra requirements. App restrictions, allowed hours, and priority include explanations; access and pause checks are under advanced options. All saved setups share one compact list. Badges show manual actions or the automatic trigger; switches and actions stay on each row.
- **Settings** contains appearance and profile defaults, shortcuts, permissions and calibration, saved-face setup, and updates. Edit manual shortcuts with their rules; recenter remains a calibration shortcut. The default blur strength retains its live sample preview. Missing Screen Recording or Camera access has a red indicator; enabling a setup that needs it opens the grant flow.

For **Look away**, select Camera or AirPods as the rule's trigger source and calibrate in **Settings → Permissions and calibration**. Camera mode uses a steady single face and estimates head direction. Each rule can have its own start angle, transition angle, blur strength, and display scope.

For **Someone nearby**, choose **Facing screen** or **Any extra face** in the rule editor. **Warn, then blur** uses the configured delay; **Warn only** stays a warning until **Blur now** upgrades it. **Blur** covers the selected scope as soon as detection is confirmed. Multiple detection rules share the camera feed.

For **Sensitive information**, choose supported text types and custom phrases. The scope is detected text. For repeatable app protection, create an **Application event** rule targeting matching windows. For saved areas, enable **Remember matching window titles**; matching uses a local title digest.

**Hold to peek** is a modifier on a continuous manual blur rule. It temporarily removes that rule's coverage while other rules remain effective. **Focus** carves out the active window and pauses head-turn rules while active.

Set up a face in Settings, authenticate with Touch ID or your Mac password, then add **Owner verification** to the nearby rules that require it. A missing or unverified template keeps those rules protected. Deleting a template preserves the rules' verification conditions.

Existing preferences migrate automatically to the versioned `protectionRules.v1` document. Original keys and a backup remain on this Mac. Migration is idempotent; a load failure preserves saved preferences and reports an error for retry. See [architecture](docs/refactor/architecture.md), [migration](docs/refactor/migration.md), and the [capability acceptance matrix](docs/refactor/parity-matrix.md) for implementation status.

## Permissions

QuietGlass requests permissions for the features you choose to use.

| Permission or authentication | Purpose |
| --- | --- |
| Screen Recording | Captures screen content for blur rendering and local text analysis. |
| Motion & Fitness | Reads supported AirPods motion for head tracking. |
| Camera | Supports camera head tracking, nearby-person detection, coverage checks, and optional owner enrollment. |
| Touch ID or Mac password | Authorizes owner enrollment and access to saved face data. |

## Keyboard shortcuts

All configurable shortcuts start empty, including shortcuts saved by previous versions. The first launch of this update clears those bindings once; shortcuts you set afterward remain saved. Set manual and hold-to-peek shortcuts in the setup editor, recenter in Settings, and region selection beside **Select region**. Escape remains the fixed clear command.

| Key | Action |
| --- | --- |
| Escape | Clear protection and stop camera monitoring |
| ⌘S | Toggle the settings sidebar |

## Privacy

QuietGlass processes screen content, recognized text, camera frames, and motion data on your Mac.

- Screen images, camera frames, recognized text, and motion history are processed without being saved or uploaded by QuietGlass.
- Preferences, app rules, saved area coordinates, and custom phrases are stored locally. Saved areas match a one-way digest of the window title; the title itself is not stored.
- Optional owner enrollment stores a face template in the encrypted macOS Keychain. Saved face data can be deleted in Settings.
- Camera access is limited to enabled camera head tracking, enrollment, Nearby people monitoring, and an explicitly started coverage check. Your Nearby people setting is remembered across app launches. Monitoring pauses while your Mac is inactive and resumes when you return. Turning detection off or pressing Escape keeps it off until you enable it again. Enabled head-turn rules start their configured sources after the required permissions and calibration.
- Update checks contact GitHub for public release metadata. They do not include screen content, camera data, face templates, or custom phrases, and automatic checks are off by default.
- QuietGlass does not record microphone audio.
- Core protection features do not require a hosted backend or cloud inference.

QuietGlass complements macOS screen locking with control over everyday screen visibility.

## Development

QuietGlass uses Swift Package Manager and native Apple frameworks.

### Prerequisites

- Xcode 26 or later, with its command-line tools selected
- Access to the project repository

### Build and run

```sh
git clone https://github.com/clintonimaroo/quietglass.git
cd quietglass

swift test --build-system native
bash build.sh

open ../Build.noindex/QuietGlass.app
```

The build script produces:

```text
../Build.noindex/QuietGlass.app
../QuietGlass.zip
```

The app is built for the current Mac’s architecture. Standard builds use the bundled recognition model and require no API keys or additional model downloads.

For universal DMG and ZIP packaging, see the [release guide](RELEASING.md).

### Project structure

```text
QuietGlass/
├── Sources/
│   ├── QuietGlass/          # Application, UI, capture, and platform integrations
│   └── ShieldCore/          # Protection policies and shared decision logic
├── Tests/
│   ├── QuietGlassTests/     # Application and integration tests
│   └── ShieldCoreTests/     # Policy and behavior tests
├── Resources/              # App metadata, icons, preview assets, and licenses
├── scripts/                # Signing, model conversion, and build utilities
├── Package.swift           # Package and target configuration
└── build.sh                # Application packaging and signing
```

### Architecture

The application layer manages windows, controls, permissions, and system integrations. ShieldCore contains the protection rules and state transitions that determine how the app responds.

| Area | Technology |
| --- | --- |
| Interface and desktop integration | SwiftUI, AppKit |
| Screen capture and blur | ScreenCaptureKit, Core Image |
| AirPods head tracking | Core Motion |
| Camera input and head direction | AVFoundation, Vision |
| Text and face detection | Vision |
| Owner face matching | Core ML with the bundled SFace model |
| Authentication and template storage | LocalAuthentication, macOS Keychain |

### Testing

```sh
scripts/test.sh
```

Automated tests cover protection policies, calibration, screen geometry, text matching, camera state handling, owner enrollment, and template storage.

The default suite does not activate windows or execute desktop interaction tests.
Compile native UI automation with `scripts/test-desktop.sh --prepare-ui`.
Run it explicitly on this Mac with `scripts/test-desktop.sh --ui --interactive`;
that command uses the desktop and can change keyboard focus. Panel, hotkey, and
system integration checks use `--integration --interactive`. See
[testing without desktop interruptions](docs/testing.md) for the test groups,
rendering artifacts, execution guards, and result locations.

Hardware and interaction checks are recorded in the [validation notes](VALIDATION.md).

## Product direction

QuietGlass is being built as an open-source macOS product with a simple goal: make screen privacy a natural part of daily work. Its source is available to inspect, build, modify, and contribute to under the MIT license.

Development follows four principles:

1. **Native experience:** controls, motion, and settings that feel at home on macOS.
2. **Local processing:** keep sensitive screen and camera data on the device.
3. **User control:** make protection easy to start, adjust, pause, and clear.
4. **Focused scope:** prioritize useful privacy workflows over unnecessary features.

## Product roadmap

The following phases describe the planned direction.

| Phase | Focus |
| --- | --- |
| Everyday experience | Refine onboarding, calibration, camera setup, accessibility, display handling, and power efficiency. |
| Public releases | Establish signed and notarized distribution, automatic updates, release documentation, and a clear feedback process. |
| Smarter workflows | Expand application rules, profile automation, shortcut integrations, and protection preferences for different work environments. |
| Teams and professional use | Explore managed deployment, shared configuration, and optional paid support for organizations. |

Open-source development can be supported through optional paid distribution, support, and professional services. The project’s source remains available under its open-source license.

## Contributing

Bug reports, documentation improvements, and focused pull requests are welcome. Open an issue before starting a substantial feature or architectural change so the approach can be discussed.

See [Contributing](CONTRIBUTING.md) for setup, verification, and pull request guidance.

## Security

Please report vulnerabilities privately using the [Security Policy](SECURITY.md).

## Ownership and licensing

QuietGlass is developed by Clinton Imaro and released under the [MIT License](LICENSE).

Third-party models, icons, and audio retain their respective rights and attribution requirements. See the [icon license](Resources/Icons/LICENSE.md), [SFace model license](Resources/Models/SFace-LICENSE.txt), and [warning sound source notice](Resources/Sounds/NOTICE.txt).
