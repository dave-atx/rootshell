# Building rootshell on macOS without upstream signing

`scripts/build-macos-local.sh` builds, ad-hoc signs, and installs a runnable
Mac Catalyst app to `~/Applications/rootshell.app`.

```
scripts/build-macos-local.sh            # build + install
scripts/build-macos-local.sh --run      # ...and launch it
scripts/build-macos-local.sh --clean    # wipe .derivedData/mac first
```

That is the whole workflow. The rest of this file is why it is not just
`xcodebuild`, so nobody has to rediscover it.

## The constraint

The project targets upstream team `D97ZME3ET2`. A free Apple ID (personal
team, no paid membership) cannot provision four of the app's entitlements:

| Entitlement | Value |
| --- | --- |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.rootshell` |
| `com.apple.security.application-groups` | `group.com.kk2.ghostty` |
| `keychain-access-groups` | `com.kk2.ghostty-ios` |
| `aps-environment`, `com.apple.developer.associated-domains` | push, `beta.rootshell.com` |

There is no substitute for them on a free account -- they are paid
capabilities, so a local build has to run *without* them rather than with
different values.

## The two dead ends

Both were measured, not assumed:

1. **Ad-hoc signature that keeps the restricted entitlements** -> the kernel
   SIGKILLs the process at launch (exit 137, no crash report). Restricted
   entitlements require a provisioning profile to back them; ad-hoc has none.
2. **Ad-hoc signature without them, against unmodified source** -> SIGTRAP
   (exit 133) inside `CKContainer.init(identifier:)`, reached from
   `CloudKitSyncManager.shared`'s one-time initializer. `CKContainer` traps
   rather than returning nil when the entitlement is missing.

So the entitlements must be dropped *and* the code must tolerate their
absence. It does now, by probing at runtime -- see below.

## What the build script does that a plain xcodebuild does not

- **`CODE_SIGNING_ALLOWED=NO`** so xcodebuild's provisioning check never
  runs. Without it the build fails outright on `rootshell-standalone` and
  `rootshell-helper` ("requires a provisioning profile"). All signing is done
  afterwards by the script.
- **`ENABLE_DEBUG_DYLIB=NO`**. This one is easy to lose hours to. With the
  default, Xcode emits a small launcher plus a separate
  `rootshell.debug.dylib`, and the bundle ends up linker-signed with
  `Sealed Resources=none`. It looks like a successful build and is not a
  runnable app.
- **Signs inside out** -- dylibs, frameworks, plugins, `Contents/Helpers/*`,
  then the outer bundle. Nested code has to be sealed before its container.
- **Copies out of `.derivedData`** before launching. LaunchServices silently
  declines to `open` a bundle inside that dot-directory: `open` returns 0 and
  no process starts. Running the binary directly from there does work, which
  makes this confusing to diagnose.

## Runtime probes this relies on

These are committed, unconditional, and behave identically in a properly
provisioned build. They are not local-only shims.

- **`CloudKitSyncManager`** probes for the iCloud entitlement with
  `SecTaskCopyValueForEntitlement` before constructing `CKContainer`, and
  holds `container`/`database` as implicitly unwrapped optionals that stay
  nil without it. Sync then cannot be enabled: `setEnabled(_:)` throws
  `accountNotAvailable`, and the handful of entry points called
  unconditionally at launch (`logDiagnostics`, `revalidateSubscriptionsIfNeeded`,
  `handleRemoteNotification`, `syncNow`) return early.
- **`HelperPeerTrust`** (`rootshell-helper`) builds its peer code requirement
  from the helper's *own* signature instead of a hardcoded team. Signed by a
  team, it demands that same team under Apple's anchor -- the original check,
  unchanged. Ad-hoc, there is no certificate to pin, so it falls back to the
  app's identifier alone. That fallback is weaker (any ad-hoc binary can claim
  an identifier) and is only reachable when the helper is itself ad-hoc, i.e.
  a local build talking to a local build. Without it the helper rejects every
  connection and local shell panes do not work.

## What does not work in a local build

- **CloudKit sync** -- off, and Settings will report the account as
  unavailable if toggled. Nothing else depends on it.
- **Push notifications, associated domains / passkey autofill, and the
  keychain access group.** Credentials still save; they land in the app's
  default keychain group rather than the shared one.
- SSH panes, local shell panes, and the multiplexer exposé all work.

## If you get a paid membership later

Drop the script entirely and build normally. The runtime probes all take
their original branch as soon as the entitlements are really present; nothing
needs reverting.
