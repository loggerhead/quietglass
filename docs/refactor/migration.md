# Versioned preference migration

ProtectionStore writes `protectionRules.v1` as versioned JSON. The document contains
schemaVersion, rules, and presentation/calibration preferences. Rule identities
and creation times are stable across subsequent loads. Head source and nearby
detection enums are shared by ShieldCore and platform adapters.

Before the first migration, the store backs up every recognized legacy key to
`protectionRules.legacyBackup.v1` as a binary property list. The first backup is
retained across failed attempts. Legacy values are never modified by the store.
Unknown preferences outside the migration list remain untouched in UserDefaults.
Face templates are not read or copied: the existing Keychain service/account and
authentication policy remain authoritative.

The migration constructs and validates the complete document in memory before
commit. It encodes/decodes the JSON and verifies write-through readback. A failed
new-document write removes the failed key; a failed edit restores its previous
value. Malformed legacy app/saved-area data, unknown detector options, invalid
parameters, or invalid rules throw without installing a partial document. This
avoids silently dropping protection. The live integration must surface the error
and preserve the old configuration until a successful retry. The application
displays a migration error and starts no protection sensors on failure; it does
not invoke a legacy renderer.

Loading an existing document validates its schema and every rule. It never
re-migrates or reads old protection keys for product decisions. A corrupt current
document is preserved for diagnosis rather than silently replaced by defaults.
Legacy keys must stay present and read-only for at least one release cycle after
the application switches. The old protection preference writers have been removed.

## Mapping notes

Manual shortcuts and peek become manual rules and action modifiers. Area/window
quick actions start as selection templates (`$selection`) and must resolve a real
window reference before activation. Sensor rules use explicit permissions and
calibration guards. Head rules initially stay disabled because the old app did
not automatically start tracking. Per-app stronger variants carry higher-priority
head parameters plus appCondition; starting tracking must activate the appropriate
head rule package. App-window rules and saved title-digest regions remain automatic.

Legacy warning mode becomes warnThenBlur, retaining delay/sound and optional owner
guard. App pause becomes the targeted headTurn pause action. Custom phrases are
normalized with the existing cleaner. Saved window titles remain digests. Camera
selection, calibration completion, presentation choices, and an outstanding pause
deadline are retained as local adapter/presentation preferences. Profiles were
derived from comfort/transition/blur in the old app rather than persisted as a
separate switch; those exact defaults are retained.

## Tests and real-copy verification

ProtectionStoreTests covers empty/full configuration, damaged subsets, repeated
migration, failed commits/edits, invalid schemas, legacy data retention, and a
real plist copy. No private preference values or generated JSON enter the repo.

To validate a local preference copy without touching the running app's domain:

```sh
cp ~/Library/Preferences/local.clinton.QuietGlass.plist /tmp/quietglass-real-preferences-copy.plist
QUIETGLASS_MIGRATION_PREFS_PATH=/tmp/quietglass-real-preferences-copy.plist \
  swift test --build-system native --filter ProtectionStoreTests
```

2026-11-12: this real-copy test passed on this Mac. It migrated in isolated storage,
reloaded without changing rule identity, compared all legacy values, and confirmed
the input plist bytes remained unchanged. AppModel now loads through this store by default. RuleApplicationIntegrationTests verifies real entrypoint edits,
profile defaults, shortcuts, and nearby actions against isolated legacy preferences.
The default application has switched and its legacy-mode flag is removed.
Migration-error integration verifies unchanged preferences and no old sensor startup.
Migrated first-launch rules are exercised by application integration and geometry/
rendering parity tests; the real preference copy passes isolated migration/readback
without modifying the running application domain.

Outstanding nearby pause deadlines become coordinator pause state. New timed or
indefinite pauses are retained in the versioned document, with wall time accounting
for sleep; explicit resume/clear removes them. Original legacy pause keys remain
read-only. A failure to save runtime preferences is exposed as persistenceError.

Immediate-blur configurations also retain warning delay/sound as action defaults;
changing to a warning action or creating a preset reuses them. Existing v1 documents
without the new optional default fields decode to the original 120-second/sound-on
values. New saves validate these defaults. Update bookkeeping, camera choice and
owner enrollment no longer write retained legacy keys. Manual remembered regions
can restore a matching title-digest scope after restart, while preserving manual
clear and global Escape/resume semantics.

The final 272-test regression on 2026-11-12 included this real-copy migration test
with no failures or skips. Explicit resume, clear, and timed expiry clear persisted
pause metadata; expiry during sleep leaves the engine suspended until wake. Resume
and wake refresh context before submitting a single render plan, preventing stale
window geometry from being reused at that transition.

## Empty shortcut defaults (2026-11-12)

The user explicitly requested clearing existing configurable shortcuts as well as
leaving new defaults empty. `shortcutDefaultsVersion` records this one-time policy:
older v1 documents decode a missing version as 0 and clear manual bindings, peek,
recenter, and region selection before a write-through save with version 1. Rule
IDs, names, enabled flags, action parameters, and legacy backup keys are retained.
New legacy migrations use empty bindings immediately. A subsequent user assignment
persists across reloads; the reset is not repeated. Escape remains the fixed clear
command. A failed save rolls back to the previous document.

Preset-to-rule IDs are persisted in preferences. Repeated preset activation reuses
that identity and preserves custom edits; unmapped matching presets are adopted
only when name, trigger, scope, action, and guards match the canonical definition.
