# Fonts installed by other apps

Notes for a future change: rootshell doesn't list monospace fonts that a font provider app (Typecask, Font
Case, etc) installed, even though Word and Keynote show them. This records what was found on 2026-10-26
against `main` at `20e1f770`, and what the fix probably looks like. Line numbers are from that commit.

## The problem

On an iPad, GNU Unifont installed through Typecask appeared in Word and Keynote but not in rootshell's
font settings. Typecask registers fonts system-wide with
`CTFontManagerRegisterFontsWithAssetNames(..., .persistent, ...)` and the `system-installation`
entitlement; the install was fine.

iOS hides an installed font from an app until that app asks for it. An app with the
`com.apple.developer.user-fonts` = `app-usage` entitlement (rootshell has it in all three entitlements
files) gets access to an installed font only when it:

- calls `CTFontManagerRequestFonts` with a descriptor naming the font, or
- lets the user pick it in `UIFontPickerViewController` (Apple's documented path; not tested here).

Until then the font doesn't exist as far as the app can tell: no descriptor matching, no
`UIFont.familyNames`, no `UIFont(name:)`. Access, once granted, is remembered across launches.

None of the three discovery passes in `FontCatalogLoader.loadSystemFonts()` can find a font the app
hasn't been given access to, so rootshell never lists it.

## Evidence

A probe app with rootshell's `app-usage` entitlement ran the same calls in the iOS 27.2 simulator (iPad Pro
11-inch (M5)), after Typecask installed Unifont through its real On-Demand Resources install path:

| Call | Before requesting | After `CTFontManagerRequestFonts(["Unifont"])` |
| --- | --- | --- |
| Monospace trait matching (`FontCatalogLoader.swift:209`) | not found | not found (see below) |
| `UIFont.familyNames` | not found (86 families) | found (87) |
| `CTFontManagerCopyAvailableFontFamilyNames()` | not found | found |
| Match all descriptors / match by family name | not found | found |
| `CTFontManagerCopyRegisteredFontDescriptors(.persistent, true)` | 0 descriptors | 0 descriptors |
| `CTFontCreateWithName("Unifont")` | falls back to Helvetica | Unifont, served from `Library/UserFonts/FontFiles/...` |
| `UIFont(name: "Unifont")` | nil | Unifont |

The request returned 0 unresolved descriptors and showed no dialog. On a relaunch, Unifont was visible
from the start without asking again.

Unifont never matches the monospace trait, even with access: Core Text reports
`traitMonoSpace == false` although its `post.isFixedPitch` is 1. Its OS/2 PANOSE `bProportion` is 6
rather than 9 ("monospaced"), which I'm guessing is why. The glyph-advance check in
`FontCatalogLoader.monospaceFaceName(forFamily:)` does catch it once it's in `UIFont.familyNames`: the
advances of M, i, W and `.` are all 32 units.

## What's wrong in the current code

- `FontCatalogLoader.swift:205-207`: the comment says descriptor matching finds user-installed fonts
  "when the com.apple.developer.user-fonts entitlement is present". It only finds the ones the app has
  been given access to. If Font Case fonts showed up in testing, rootshell had probably requested them, or
  they came from a configuration profile.
- `FontCatalogLoader.swift:259-289`: the `.user` scope pass can't find another app's fonts.
  `.user` is the deprecated name for `.persistent`, which on iOS lists only fonts the calling app
  registered itself. Typecask relies on the same behavior to tell its own fonts from iOS's.
- There's no way for a user to grant access, so the list of system fonts can never grow past what iOS
  ships plus whatever happens to have been requested.

## Probable fix

1. Add a "Choose an installed font..." row to the System Fonts section of `FontSettingsView`
   (`FontSettingsView.swift:92`) that presents `UIFontPickerViewController`.
   - Leave `filteredTraits` empty. Filtering on `.traitMonoSpace` would hide Unifont, per the above.
   - When the user picks a font, rerun `FontManager.loadSystemFonts()` (with
     `FontCatalogLoader.invalidateMonospaceCache()`) and select the family. Don't count on
     `kCTFontManagerRegisteredFontsChangedNotification` (`FontManager.swift:723`) to fire when access
     is granted; that wasn't checked.
   - If the picked font fails the glyph-advance check, say so rather than silently not listing it, or
     allow it anyway with a warning.
2. On launch, call `CTFontManagerRequestFonts` for the saved font family if it isn't resolvable, so a
   selection survives whatever state iOS loses (Typecask notes that on iOS 27.0, registered fonts can
   vanish after a reboot while still registered).
3. Delete the `.user` scope pass and fix the comment.
4. Mac Catalyst (`rootshell-Standalone`) wasn't tested. macOS fonts are global, so the picker should be
   harmless there, but check that the existing discovery still lists Font Book fonts.

Things to verify before sending upstream: that picking a font in `UIFontPickerViewController` grants
access the way `CTFontManagerRequestFonts` does, and the behavior on a device as well as the simulator.

## Reproducing

You need a font installed by a provider app in the simulator. With a Typecask checkout
(`dave-atx/ios-fonts`): copy the project with a `Typecask/Fonts.xcassets` holding only the root
`Contents.json` and the `font-gnu-unifont` group, then run its install UI test against a booted simulator:

```sh
TEST_RUNNER_TYPECASK_CASK=font-gnu-unifont xcodebuild test -project Typecask.xcodeproj \
  -scheme Typecask -destination 'id=<simulator-udid>' \
  -only-testing:TypecaskUITests/InstallTests/testInstalledCaskStaysInstalledAfterRelaunch
```

Then build and run the probe below. Two things it took a while to learn:

- iOS 27 refuses to launch an app without a scene manifest (`UIScene life cycle is required`), and
  `didFinishLaunching` never runs.
- Signing the entitlements into an ad-hoc signature (`codesign --entitlements`) makes the simulator refuse
  to launch the app. Embed them the way Xcode does for the simulator instead: an `__entitlements` section
  with the plist and an `__ents_der` section with the DER form.

To repeat the "before" case, reset access by erasing the simulator (or reinstalling the probe under a new
bundle identifier).

<details>
<summary>Probe sources and build commands</summary>

`main.swift`:

```swift
import UIKit
import CoreText

func report(_ header: String) {
    let target = "Unifont"
    var out = header + "\n"
    func fam(_ d: CTFontDescriptor) -> String? { CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String }
    let mono = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]] as CFDictionary)
    let matched = CTFontDescriptorCreateMatchingFontDescriptors(mono, nil) as? [CTFontDescriptor] ?? []
    out += "mono trait matches: \(matched.count), families: \(Set(matched.compactMap(fam)).sorted())\n"
    out += "familyNames has target: \(UIFont.familyNames.contains(target)) (of \(UIFont.familyNames.count))\n"
    let avail = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
    out += "CopyAvailableFontFamilyNames has target: \(avail.contains(target)) (of \(avail.count))\n"
    let all = CTFontDescriptorCreateMatchingFontDescriptors(CTFontDescriptorCreateWithAttributes([:] as CFDictionary), nil) as? [CTFontDescriptor] ?? []
    out += "all-descriptor match has target: \(all.contains { fam($0) == target }) (of \(all.count))\n"
    let byFamily = CTFontDescriptorCreateMatchingFontDescriptors(CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: target] as CFDictionary), nil) as? [CTFontDescriptor] ?? []
    out += "family-name match: \(byFamily.count)\n"
    let reg = CTFontManagerCopyRegisteredFontDescriptors(.persistent, true) as? [CTFontDescriptor] ?? []
    out += "persistent-registered descriptors: \(reg.count)\n"
    let f = CTFontCreateWithName(target as CFString, 16, nil)
    let url = CTFontCopyAttribute(f, kCTFontURLAttribute) as? URL
    out += "CTFontCreateWithName -> \(CTFontCopyPostScriptName(f)) mono=\(CTFontGetSymbolicTraits(f).contains(.traitMonoSpace)) url=\(url?.path ?? "nil")\n"
    out += "UIFont(name:) -> \(UIFont(name: target, size: 16)?.fontName ?? "nil")\n"
    try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Documents", withIntermediateDirectories: true)
    try? out.write(toFile: NSHomeDirectory() + "/Documents/probe-\(header).txt", atomically: true, encoding: .utf8)
}

@objc(SceneDelegate) class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}

@objc(AppDelegate) class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        report("before")
        let wanted = [CTFontDescriptorCreateWithNameAndSize("Unifont" as CFString, 0)] as CFArray
        CTFontManagerRequestFonts(wanted) { unresolved in
            let n = CFArrayGetCount(unresolved)
            DispatchQueue.main.async { report("after-request-unresolved-\(n)") }
        }
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
```

`Probe.app/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.marquard.FontProbe</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundleName</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>27.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
  <key>UIApplicationSupportsMultipleScenes</key><false/>
  <key>UISceneConfigurations</key><dict>
    <key>UIWindowSceneSessionRoleApplication</key><array><dict>
      <key>UISceneConfigurationName</key><string>Default</string>
      <key>UISceneDelegateClassName</key><string>SceneDelegate</string>
    </dict></array>
  </dict>
</dict>
</dict></plist>
```

`app-usage.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>5WM6947328.org.marquard.FontProbe</string>
<key>com.apple.developer.user-fonts</key><array><string>app-usage</string></array>
</dict></plist>
```

`make-ents-der.py` writes the same entitlements in the DER form Xcode embeds (keys sorted):

```python
def tlv(tag, body):
    n = len(body)
    ln = bytes([n]) if n < 128 else bytes([0x81, n]) if n < 256 else bytes([0x82, n >> 8, n & 255])
    return bytes([tag]) + ln + body

s = lambda x: tlv(0x0C, x.encode())
kv = [("application-identifier", s("5WM6947328.org.marquard.FontProbe")),
      ("com.apple.developer.user-fonts", tlv(0x30, s("app-usage")))]
d = tlv(0xB0, b"".join(tlv(0x30, s(k) + v) for k, v in sorted(kv)))
open("ents.der", "wb").write(tlv(0x70, b"\x02\x01\x01" + d))
```

Build, install, run and read the results:

```sh
python3 make-ents-der.py
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator main.swift -o Probe.app/Probe \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker app-usage.entitlements \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __ents_der -Xlinker ents.der
codesign -f -s - Probe.app
xcrun simctl install booted Probe.app
xcrun simctl launch booted org.marquard.FontProbe
sleep 6
cat "$(xcrun simctl get_app_container booted org.marquard.FontProbe data)"/Documents/probe-*.txt
```

`simctl launch --console` printed nothing useful here, hence writing results to the app's Documents
directory.

</details>
