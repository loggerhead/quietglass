# Privacy boundary audit

The capture, camera, Vision, owner embedding, and AirPods algorithms remain local.
Only ScreenCaptureAdapter constructs DisplayCapture, and ScreenBlurExecutor owns
its per-display streams. Raw samples feed in-memory render/OCR workers; ProtectionEvent
and ProtectionPlan contain coverage, geometry, rule IDs, and detection/verification
state. They contain neither camera frames nor recognized text. No source in the
new engine/coordinator/adapters writes frames or recognized text to disk or logs.
Synthetic UI snapshots and profiling fixtures are test artifacts under /tmp.

Window-title matching uses RuleEventSources.titleDigest (SHA-256). Remembered rule
references contain bundle identifiers and digests, with normalized region coordinates;
raw window titles are transient selection/geometry input. ProtectionStore retains
legacy preference backups as required and stores user-authored custom phrases.
It does not persist recognized text. The original preference copy used in migration
tests remains unchanged and is not part of the repository.

OwnerTemplateStore retains the original Keychain service/account, authenticated
read/write/delete operations, and template encoding. Enrollment and deletion no
longer write ownerRecognitionEnabled. Rule verification guards remain intact when
a template is deleted or unavailable. Camera permission loss cannot authorize an
owner-guarded scope to become visible; Screen Recording permission and Escape still
gate actual output. Existing authentication, camera-denial, stale-callback, failed
replacement, and actual isolated-Keychain tests exercise these boundaries.

A comparison of literal network URLs in current application source against HEAD
found no added endpoint. AppUpdates keeps the existing ephemeral GitHub release
request, origin validation, headers and optional automatic checks. Its bookkeeping
now writes the versioned document rather than retained legacy keys. Update tests
inject the request transport and check origins/authorization headers. Protection
sources introduce no URLSession, socket, upload, or model-download calls. Pricing,
license, bundled models and permission entitlements have not changed.
