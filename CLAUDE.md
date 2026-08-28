# rootshell

## Building on macOS

This machine cannot sign the app the way the project is configured: it targets
upstream team `D97ZME3ET2`, and the available Apple ID is a free one that
cannot provision the app's iCloud / app-group / keychain-group / push
entitlements.

**Use `scripts/build-macos-local.sh`.** It builds, ad-hoc signs, and installs
to `~/Applications/rootshell.app`.

```bash
scripts/build-macos-local.sh --run
```

Do not try to fix a signing failure by adding `-allowProvisioningUpdates` or
by selecting a team -- there is no account configured in Xcode, and the
personal team cannot claim `com.kk2.*` or `iCloud.rootshell`. Read
`docs/macos-local-dev.md` before changing anything about signing,
entitlements, or the two runtime capability probes it describes; it records
which approaches were measured and how they failed.

## Building for the iOS simulator

Signing is not an issue here, but the configuration is:

```bash
xcodebuild -scheme rootshell-AppStore -configuration DebugAppStore \
  -destination 'platform=iOS Simulator,id=<udid>' build
```

`rootshell-Standalone` is macOS/Catalyst **only**. Plain `Debug` (rather than
`DebugAppStore`) misses `-D DISABLE_MFI_LIGHTNING` and fails on YubiKit
against the iOS 26 SDK. iPhone and iPad share one simulator binary.
