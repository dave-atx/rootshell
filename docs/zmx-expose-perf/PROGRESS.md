# zmx exposé performance — working notes

**Purpose:** make "show all zmx tabs in exposé" faster, with every change proven
by benchmark + tests. This file is the resume point: it must be enough to pick
the work back up cold, without re-reading the whole codebase.

## RESUME HERE (2026-09-09)

**State:** T1 + V1 are done and verified. **V2 is blocked**, and not by T1.
Everything below is uncommitted in the working tree on branch `perf/zmx-expose`:
`docs/zmx-expose-perf/PROGRESS.md`, `docs/zmx-expose-perf/RESULTS.md`,
`rootshell.xcodeproj/project.pbxproj`,
`rootshellStandaloneUITests/rootshellStandaloneUITests.swift`, and untracked
`scripts/test-macos-ui-paid-team.sh`.

**The blocker:** on macCatalyst 26+, `File > New Tab` and `Tabs > Tab Exposé`
both post a notification with `object: nil`, which
`MainView+Notifications.swift:664-684` silently drops unless a scene id matches
or exactly one `UIWindowScene` is connected. Full write-up in the
2026-09-09 (later) status entry. It is upstream of exposé and untouched by T1.

**Next actions, in order:**
1. Establish whether the routing bug is user-facing: open two rootshell windows
   in a normal build and press Cmd-Shift-A. If exposé fails with two windows,
   it is a real bug and needs its own change (like the SSH read race did),
   separate from this perf work.
2. If it is test-environment-only, V2 needs a different whole-system
   confirmation route -- the exposé XCUITests cannot pass until the routing is
   fixed or a test-only hook exists.
3. Do **not** re-run the suite hoping for a different answer. Two clean
   attended runs already gave a consistent, well-diagnosed result.

**Run the tests like this** (attended, at the physical keyboard, never over
Screen Sharing -- see run hazard 3):

```sh
scripts/test-macos-ui-paid-team.sh --only testDetachThenTabExposeReturnsToLocal
```

Do not pipe it through `tail`: that swallows the exit status. The runner now
declares a VOID run and exits non-zero if the session locked mid-run.

## Ground rules (from the user)

- Benchmark on a **real SSH connection** to the **zmx fixture VM**
  (`Tests/ZmxFixture/zmx-fixture.sh`, rootless Podman inside the podman machine).
- zmx must be the **v0.8.1 release** (`/Users/dave/src/zmx` @ `8bab1f0`, tag `v0.8.1`).
- **Every change must be benchmarked and tested** to prove (a) it is actually
  faster and (b) nothing regressed. If that cannot be proven for a change, add
  the test/benchmark to capture the baseline *first*.
- Scope chosen: **instrumentation first**, then **Track 1 (client-only)**.
  No zmx-side changes for now.
- Benchmark shape: **script-level over real SSH is the pass/fail gate**; one
  end-to-end XCUITest run confirms whole-system effect.
- Latency sweep: **0 / 30 / 80 ms** (loopback RTT is ~0.2ms and would otherwise
  make round trips look free).
- Session scale: user runs **under 10 sessions**. This is important — see
  "Revised weighting" below.

## Revised weighting (IMPORTANT — supersedes the first exploration writeup)

The initial exploration named the 512KB response-cap truncation ramp as the
dominant cost. That conclusion assumed 20+ sessions. The user runs **under 10**,
where truncation likely never triggers. Do not optimise the `fetchCap` ramp on
faith. At <10 sessions and 30–80ms RTT the live suspects are:

1. Cold-start round trips: `detect()` then `resolveSession()` both complete
   before the first capture is even requested.
2. `detect()` re-runs on nearly every zmx exposé open, not just the first
   (`MultiplexerExposeFeed.swift:170` forces `requiresZmxValidation` for zmx).
3. Serial remote execution: `zmx history <name> --vt | tail -n 80` runs once per
   session, sequentially, inside a single exec
   (`ZmxExposeAdapter.swift:38-44`), each guarded by `timeout 2`.
4. `minInterval` of 1.5s for zmx (`ZmxExposeAdapter.swift:12`), growing to 2.5s.
5. zmx serialises the full 10,000-line scrollback per capture and `tail` throws
   it away (`/Users/dave/src/zmx/src/util.zig:913`, `src/cfg.zig:12`).
   Out of scope for Track 1 but explains remote CPU cost.

**The instrumentation exists to settle this. Let the numbers pick the fix.**

## Key code references (verified)

Client:
- `rootshell/Features/Multiplexer/Expose/MultiplexerExposeFeed.swift`
  - `:53` `fetchCap` starts `Int.max`; `:1046` halves on truncation;
    `:1051` doubles only after 5 clean ticks
  - `:64` `responseCap` 512KB, `:65` `tickTimeout` 5s (whole tick discarded)
  - `:170` forces zmx re-validation on every open
  - `:1088-1091` pane ranking, `:1109` tail-trim, `:1104` hidden panes every 3rd tick
  - `:22` logger, category `MuxExpose` — the only existing visibility
- `rootshell/Features/Multiplexer/Expose/ZmxExposeAdapter.swift`
  - `:12` `minInterval` 1.5s, `:26` `captureRows` 80, `:32-47` `tickScript`
- `rootshell/UI/Tabs/MuxTabPreviewView.swift:79` per-tile Ghostty surface

zmx (v0.8.1, reference only — no changes planned in Track 1):
- `src/util.zig:899` `serializeTerminal` (`.selection = null` = whole buffer)
- `src/util.zig:830` viewport-pinned logic that already exists (in attach path)
- `src/ipc.zig:271` 1000ms per-session probe timeout; `src/util.zig:46` serial loop
- `src/loop.zig:1129` `handleHistory` reads only `payload[0]`, ignores trailing
  bytes — so a row-limit byte would be backward compatible for free (future work)

## Fixture quick-start

```sh
cd /Users/dave/src/rootshell
Tests/ZmxFixture/zmx-fixture.sh start --env-file /tmp/zmx.env   # ~3 min first build
Tests/ZmxFixture/zmx-fixture.sh seed  "$ZMX_FIXTURE_STATE_DIR" s1 s2 s3
Tests/ZmxFixture/zmx-fixture.sh exec  "$ZMX_FIXTURE_STATE_DIR" zmx list
Tests/ZmxFixture/zmx-fixture.sh stop  "$ZMX_FIXTURE_STATE_DIR"
```
Image builds from `ZMX_REPO` (default `../zmx`). State dir lives under `$TMPDIR`
and may be reaped; re-run `start` if `exec` fails.

## Existing fork test suites (must stay green)

```sh
cd Tests/ZmxLogic       && swift test     # 11 tests
cd Tests/LoginShellLogic && swift test    # 20 tests
sh docs/zmx-expose-checks/run.sh          # "ALL CHECKS PASSED"
xcodebuild build -project rootshell.xcodeproj -scheme rootshell-Standalone \
  -destination 'platform=macOS,variant=Mac Catalyst'
```

## Task list

- [x] Rebase `fork-tests` onto upstream/main; push to origin (done, 7418703)
- [x] Confirm zmx checkout is v0.8.1 and fixture builds from it
- [x] Fixture starts and is reachable over real SSH
- [x] **B1** Build script-level benchmark harness (real SSH → fixture, runs the
      real `tickScript`, sweeps session count × latency, reports per-phase wall
      time and byte counts) — `docs/zmx-expose-perf/bench/`, see its README.
- [x] **B2** Add host-side latency injection (0/30/80ms). netem needs NET_ADMIN
      which rootless podman may deny — fall back to a host TCP delay proxy.
      Turned out netem fails for a different reason on this dev machine: the
      podman machine kernel has no `sch_netem` module at all (NET_ADMIN itself
      *is* granted). `netem/delay_proxy.py` is the fallback in actual use;
      the netem success path is implemented but unverified. See bench README.
- [x] **B3** Seed sessions with realistic coloured scrollback (empty shells
      produce unrealistically tiny captures) — `lib/gen_content.py`. Found
      along the way: a single `zmx print` over ~4089 bytes silently fails on
      zmx v0.8.1 (session stays at a bare prompt, exit 0, no error);  worked
      around by chunking, not investigated further (zmx pinned read-only).
- [x] **I1** Add instrumentation to the MuxExpose path (signposts + structured
      timing covering detect / resolveSession / each tick / parse / render)
- [x] **M1** Capture and record the BASELINE numbers in `BASELINE.md`
- [x] **T1** Implement Track 1 changes *justified by the baseline data only*
      (branch `perf/zmx-expose-coldstart`). Skips `detect()` for a cached
      zmx binding (revalidated by the first tick's own `zmx list` instead,
      same `boundSessionIsUnavailable` mechanism the steady-state loop
      already trusted for detach detection); seeds the first tick's fetch
      with the already-known session name instead of a topology-only first
      tick; only forces a second immediate tick when something is still
      unfetched. See `MuxZmxBootstrap` in `MultiplexerExposeAdapter.swift`.
      Correction found while implementing: `resolveSession()` never actually
      ran for the cached-zmx path even before this change (a zmx binding's
      `sessionName` is never nil) — the real old sequence was 3 execs, not
      4; see RESULTS.md for the full explanation. fetchCap ramp untouched.
- [x] **V1** Re-benchmarked; recorded in `RESULTS.md`. Cached-zmx cold start:
      3 execs -> 1 (1 session) or 2 (N>1 sessions). Saves 64-81% at 1
      session and 37-54% at N>1, across 0/30/80ms -- holds at every tested
      latency and session count.
- [x] **V2a** Make the UI test target signable under the paid team, and add
      a signing-policy-compliant runner. Three changes: the
      `rootshellStandaloneUITests` target was the only one in the project
      still pinning upstream's identity literally
      (`DEVELOPMENT_TEAM = D97ZME3ET2`,
      `PRODUCT_BUNDLE_IDENTIFIER = com.kk2.rootshell.localuitests`), so
      `DeveloperSettings.xcconfig` never reached it — now derived from
      `$(ROOTSHELL_DEVELOPMENT_TEAM)` / `$(ROOTSHELL_ORG_IDENTIFIER)` like
      every other target; the test's hardcoded disposable host identifier is
      now switchable to target-app resolution
      (`ROOTSHELL_UI_TEST_USE_TARGET_APP=1`), default unchanged; and
      `scripts/test-macos-ui-paid-team.sh` is the signed runner.
- [ ] **V2** One end-to-end XCUITest run as whole-system confirmation.
      The relevant test is `testDetachThenTabExposeReturnsToLocal` — exactly
      the detach path this change alters.
      **The signing and authentication blockers are both gone.** The runner
      now initializes and executes all four tests. Two further blockers were
      found and fixed underneath them; one remains, and it is environmental.
      - **Resolved: `system.privilege.taskport` authentication.** Runs from
        2026-09-08 16:51 onward reach test execution, so the prompt described
        in the previous note was answered. No permanent change was made;
        `DevToolsSecurity -enable` was never run.
      - **Resolved: the generated UI-test runner is sandboxed.** All four
        tests failed in `setUpWithError()` with `NSCocoaErrorDomain 513` /
        `NSPOSIXErrorDomain 1 (EPERM)` creating the per-test socket
        directory under `/private/tmp`. Cause: Xcode signs
        `rootshellStandaloneUITests-Runner.app` with
        `com.apple.security.app-sandbox = true` plus only a **read-only**
        temporary exception for `/`. Those entitlements are Xcode's
        auto-generated Catalyst XCTRunner defaults — they do **not** come
        from `Configuration/LocalUITests.entitlements` (which holds only
        `get-task-allow`), and `ENABLE_APP_SANDBOX = NO` on the test target
        does not suppress them. `scripts/test-macos-ui-local.sh` avoids this
        only by `codesign --force`-re-signing every `*-Runner.app` with that
        sandbox-free file (`:350`) — precisely the entitlement stripping this
        checkout forbids, so the paid-team runner cannot copy it.
        Fix: the app under test is **not** sandboxed and already creates that
        exact directory as an intermediate of
        `ForkUITestConfiguration.configureSterileHome`
        (`rootshell/App/ForkUITestConfiguration.swift:142`), so the test now
        tolerates precisely `fileWriteNoPermission` + underlying `EPERM`,
        rethrows anything else, and polls after `app.launch()` to confirm the
        app really created it. Reads, `kill()`, and the shell trap's cleanup
        are all unaffected by the sandbox.
        **Verified:** `testLaunchesLocalTerminal` passes.
      - **Resolved in code, NOT yet verified: the host-key prompt could never
        be matched.** `acceptFreshHostKeyIfPresented` required the prompt
        title to equal exactly `"New SSH Host"`, but the terminal connection
        path builds `"New SSH Host \(alertContext)"` — on the fixture,
        `New SSH Host (zmx@127.0.0.1)` (`rootshell/UI/Shell/MainView+VNC.swift:218-223`).
        A screen recording from the run proves the dialog was fully on
        screen, correctly populated, with an enabled `Connect Once` button,
        while the test reported "SSH handshake stalled". This is a latent bug
        in the harness dating to `116a83a`, **not** fallout from T1 or V2a:
        these three tests could never have passed against the terminal SSH
        path. Detection is now keyed off the `Connect Once` button itself,
        with a guard that still refuses the deliberately-not-auto-accepted
        `"⚠️ WARNING: Host Key Changed …"` prompt.
      - **Timeout raised 15s → 60s, but the stated reason was wrong.** The
        original reading — a contact sheet showing the dialog "about 15
        seconds after Connect is tapped" — counted from the wrong frame; the
        log below puts the prompt on screen 270ms after the connect begins.
        The larger timeout is harmless headroom and is being kept, but there
        was never a 15s-races-15s race. Do not cite this as evidence of
        anything.
      - **RETRACTED: "the app's SSH connect is slow."** It is not. The app's
        own `SSHDebugLogger` was enabled for a run by adding
        `-sshDebugLoggingEnabled YES` to `app.launchArguments` — it writes to
        `sterileHomeDirectory/.ghostty/ssh_debug.log`, i.e. inside the run's
        own directory — alongside a `log stream --level info --predicate
        'subsystem == "com.rootshell"'` capture. Measured, one run:

        | phase | timestamp | delta |
        |---|---|---|
        | `Starting Citadel SSH connection` | 18:44:55.416 | — |
        | `niots connect 127.0.0.1:39787` | 18:44:55.426 | +10ms |
        | `niots connected local=… remote=…` | 18:44:55.433 | **+7ms TCP** |
        | `Loaded 0 known hosts` | 18:44:55.685 | +252ms |
        | `New host …, requesting user validation` | 18:44:55.686 | **+270ms total** |
        | `User accepted host for this session only` | 18:45:00.303 | +4.62s (test tapping) |
        | `SSH session ready` | 18:45:00.376 | +4.96s |

        **The host-key prompt is on screen 270ms after Connect.** TCP connect
        to loopback is 7ms. The 4.6s that follows is the test's own polling
        loop finding and tapping `Connect Once`, not the app waiting on
        anything. KEX negotiates `sntrup761x25519-sha512@openssh.com` first
        try. The earlier "~15s to the prompt, sometimes never" reading was the
        *harness* failing to match the dialog (the title bug above), not the
        app being slow. Note that the `CONN … elapsed=4.89s` event brackets
        the user-decision wait, so that figure is not connect time either —
        do not read it as one.
        Ruled out along the way, each with evidence: DNS (`127.0.0.1` is an IP
        literal, so `NetworkAddressUtils.resolveToCGNATIPv4` returns without
        calling `getaddrinfo`; the log confirms `resolve mode=fallback`);
        Multipath TCP (`Settings.Roam.multipathTCP` defaults `false`, and the
        log line reads `niots`, not `niots+multipath`); `SSHCustomAlgorithms`
        registration (metatype appends under a lock); Keychain (`Loaded 0 SSH
        keys`, and the test authenticates with method **None**).
      - **Confirmed working: host-key prompt matching.** The same run's
        recording shows `New SSH Host (zmx@127.0.0.1)` with
        `Connect Once` / `Trust & Save` / `Cancel`, and the log shows
        `User accepted host for this session only` — so the
        `label OR title OR identifier` matcher does find the button. The
        AppKit-`title` question is moot.
      - **Resolved: `openTabExpose` pressed the wrong chord, and its
        assertion could never fail.** The helper sent
        `Cmd-Shift-Backslash`, which is `toggle_tab_switcher` — the vertical
        tab bar (`rootshell/Core/Keybinds/KeybindManager.swift:140`). Tab
        Exposé is `toggle_tab_expose`, bound to **Cmd-Shift-A**
        (`KeybindManager.swift:141`; also the Tabs-menu item at
        `rootshell/App/CatalystAppDelegate.swift:1491-1496`). The exposé
        never opened, and the failure surfaced one line later as
        `XCTAssertTrue failed - expected accessibility value multiplexer, got
        Optional()`.
        The assertion that should have caught it is the same helper's second
        bug: `tab-expose-root` is assigned in `TabExposeView.init`
        (`rootshell/UI/Tabs/TabExposeView.swift:112-115`) and stays in the
        accessibility tree while the overlay is hidden, so waiting for the
        element to *exist* always succeeded. `accessibilityValue` is the real
        signal — set to `multiplexer`/`local` on activation
        (`TabExposeView.swift:247`), cleared to `nil` on dismissal (`:267`) —
        so the helper waits on that now.
        Third latent harness bug of the same kind: the SSH-dependent tests
        died in the connection long before reaching exposé, so this line had
        never once executed.


## Status log

- 2026-09-09 (later): **V2 is blocked by a menu-command routing bug that has
  nothing to do with T1.** Two clean attended single-test runs (no lock, runner
  verdict trusted, `SCRIPT EXIT=65` propagating correctly):

  | test | result |
  |---|---|
  | `testCommandTFromSSHLeavesLocalTerminalReady` | `("1") is less than ("2")` -- `File > New Tab` created no tab |
  | `testDetachThenTabExposeReturnsToLocal` | `Tab Exposé did not open (accessibility value Optional())` |

  The new diagnostics settled the first outright: exactly two terminals exist
  (`"ready"` + `"remote-ready"`), `appState` runningForeground, `alert=absent`,
  `sheet=absent`, 2 windows. No tab was created. The screen recording settled
  the second: the `Tabs` menu opens, `Tab Exposé (⇧⌘A)` renders in normal solid
  text and takes the blue hover highlight (so it is **not** disabled), the click
  registers and closes the menu -- and the window is then pixel-identical for
  the full 10s timeout. The zmx session really was attached first, so the test
  reached the state it needed.

  **Mechanism (read from source, largely verified).** This machine is macOS
  26.6.2, so the modern SwiftUI-Commands menu path is live:
  `rootshell/App/AppCommands.swift:100` gates it on
  `#available(macCatalyst 26.0, iOS 26.0, *)`, and
  `CatalystAppDelegate.buildFileMenu`/`buildTabsMenu` are the legacy
  "macOS 15 and earlier" path (`CatalystAppDelegate.swift:1073`). On that path
  the keyboard chords and the menu items are **not two routes**:
  `KeybindCommandGenerator.commandsForIOS26Plus` filters `new_local_shell` and
  `toggle_tab_expose` out of `TerminalView`'s `UIKeyCommand`s, so Cmd-T /
  Cmd-Shift-A and the menu clicks all land in the same `AppCommands` closures.
  That is why both routes fail identically.
  `AppCommands.swift:586-590` invokes Tab Exposé as
  `UIApplication.shared.menuToggleTabExpose(nil)`, which reaches
  `ghostty_postNotification` (`UIApplication+CommandFallback.swift:55-65`) and
  posts **`object: nil`** unconditionally. Every observer then runs
  `guard shouldHandleNotification(notification)`
  (`MainView+Notifications.swift:518-521`), and that function
  (`:664-684`) drops an `object: nil` notification unless either the
  `userInfo` scene id matches `windowSceneSessionID`, or
  `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }`
  has **count <= 1**. It returns `false` silently -- no alert, no log, no
  visible effect. That matches every observation.
  `New Tab` reaches the same gate whenever `sendAction(..., to: nil, ...)`
  does not find the focused `TerminalView` in the responder chain, since
  `UIApplication.menuCreateLocalShell`
  (`UIApplication+CommandFallback.swift:93-95`) also posts `object: nil`.

  **Not verified:** whether a second `UIWindowScene` was actually connected
  during these runs. The hidden "visor" scene (`RootShellApp.swift:354-357`)
  is a real `UIWindowScene` that starts hidden, and there is a concrete
  asymmetry in the codebase -- `MainView+ConnectionSheet.swift:409` and
  `MainView+IntentRequests.swift:44` filter it out with
  `CatalystSceneDelegate.isVisorScene` before counting scenes, while
  `shouldHandleNotification:681` and
  `ghostty_activeWindowSceneSessionID` (`UIApplication+CommandFallback.swift:68-83`)
  do not. If a visor scene is connected, the `count <= 1` bypass cannot fire and
  routing falls back to scene-id matching that depends on `WindowFocusRegistry`
  bookkeeping staying correct for a window brought forward by synthesized
  XCUITest events. Plausible and grounded in real code, but not observed.

  **Real-build datapoint from the user:** Tab Exposé works in release build
  1.0.11 (2026-09-08 15:27 UTC). Note that build **predates T1** (`66abe9f`,
  16:08 UTC), so it does not by itself separate "test-mode only" from "branch
  regression" -- but the mechanism above is in code that T1 never touched.

  Ruled out with evidence: the test clicking the wrong menu item (titles are
  unique in both menus -- the File menu's other command is titled
  "Open Connections", not "New Tab"); a disabled menu item (hover highlight
  proves otherwise); `handleNewTabCommand`'s
  `pendingNewTabRequest`/`unavailableNewTabRequest` guard (nothing outside that
  function sets them, and the Tab Exposé observer has no such guard at all, so
  it cannot be the unifying cause); a screen lock (unified log is clean for
  both runs); and crashes (no `.ips` attached to the V2 bundle).

  There is no test-only hook to invoke these commands directly --
  `ForkUITestConfiguration` exposes only `activateIfRequested`, the
  sterile-home plumbing, and `markTerminal`.

  **Next action: decide whether this is user-facing.** The cheap test is two
  rootshell windows open at once, then Cmd-Shift-A. If exposé fails with two
  windows, this is a real bug in scene routing and belongs in its own change,
  like the SSH read race did.

- 2026-09-09: **The 08:05 suite run is VOID.** All four tests "failed", but the
  macOS session locked at 08:06:15.958 (Screen Sharing disconnect ->
  `SACLockScreenImmediate`; see run hazard 3). Tests 2-4 spent ~123s each
  failing `app.activate()` against a shield window and say nothing about the
  code. Test 1's own recording failed to export ("Failed to finalize
  attachment"), so there is no video for it.
  What survives from test 1 and is *not* explained by the lock: after
  `File > New Tab`, the count of `terminal-readiness == "ready"` stayed below 2
  for the ~14s **before** the lock (poll ran 08:06:01.998-08:06:17.286, ~80
  queries). Its reported value of `0` is an artifact -- the assertion fired at
  08:06:17.431, 1.5s after the shield window went up. The prior run's `1` is
  the trustworthy reading, and `1` means the original local terminal alone.
  So `File > New Tab` still has not been shown to create a second local tab,
  and `invokeMenuItem` is not yet proven to have fixed what the raw Cmd-T
  chord could not do.
  Established statically while triaging, and it makes the `>= 2` threshold
  correct as written: SSH connect creates a **second** tab rather than
  converting the first, each `TerminalView` is marked exactly once by
  `ForkUITestConfiguration.markTerminal`
  (`rootshell/App/ForkUITestConfiguration.swift:189-196`), and an unselected
  tab stays in the accessibility tree -- `MainView+TerminalContent.swift:980-1093`
  renders every tab in one `ZStack` and applies only `.opacity(0)` /
  `.allowsHitTesting(false)`, never `isHidden` or `accessibilityElementsHidden`.
  A healthy post-Cmd-T tree is therefore 2 x `"ready"` + 1 x `"remote-ready"`.
  Two mitigations landed, neither yet exercised by a real run:
  `scripts/test-macos-ui-paid-team.sh` runs under `caffeinate -dimsu` and
  declares a VOID run from the unified log; and the assertion at
  `rootshellStandaloneUITests.swift:218` now carries
  `localTerminalReadinessDiagnostics()`, which dumps every
  `terminal-readiness` element with its value, `app.state`/`app.exists`, a
  bounded element inventory, and any alert or sheet -- enough to separate "no
  tab created" from "tab created but never ready" from "app fell out of the
  tree" without another 8-minute run. Catalyst `build-for-testing` green.
  Ruled out as causes, each with evidence: three `EXC_BAD_ACCESS`/`SIGILL`
  crashes whose faulting frame is Apple's own recursive
  `_XCElementSnapshotEnumerateDescendantsUsingBlock` /
  `-[XCElementSnapshot parent]`, **not** app code -- the identical signature
  appears 8x in the 09-08 23:22 run, in which `testLaunchesLocalTerminal`
  passed; and leftover fixture containers, of which there were none.
  **Next action: one attended run at the physical keyboard**, ideally
  `--only testCommandTFromSSHLeavesLocalTerminalReady` (~2 min, not ~8).

- 2026-09-08 (latest): V2 blocked on an app bug, not a test bug. Four more
  suite runs, now instrumented (`-sshDebugLoggingEnabled YES` in
  `app.launchArguments` + `log stream --level debug` + socket/`podman exec`
  snapshots taken while hung). Two harness bugs were found and fixed on the way
  — the host-key prompt title, and `openTabExpose` pressing Cmd-Shift-Backslash
  (the vertical tab bar) instead of Cmd-Shift-A behind an `exists` assertion
  that could never fail. With those fixed, one single-test run got all the way
  through SSH, the host-key prompt and zmx attach.
  What stops the other three is **an SSH handshake read race in the app**: the
  server's banner and KEXINIT arrive before Citadel installs its handlers on
  the pre-connected NIOTS channel and are dropped at the pipeline tail, after
  which both ends wait forever. Measured identically in three hangs: the app
  received 2458 bytes, sent exactly 23 (its identification string), Recv-Q 0.
  Full write-up in "App bug found while doing V2" below. It has nothing to do
  with T1 or exposé and needs its own change.
  My earlier "the app's SSH connect is slow, ~15s to the prompt" claim is
  **retracted** — the prompt is on screen 270ms after connect; see the V2 task
  note.
  Housekeeping: two leftover fixture containers removed. Their `Up (starting)`
  status was **not** a symptom — the image defines no healthcheck, so podman
  reports `starting` forever.

- 2026-09-08 (latest): V2 runner executes; 1 of 4 tests passing. Six suite
  runs peeled off four distinct blockers (sandboxed runner, host-key title
  match, a 15s wait racing a ~15s prompt, and two wrong turns of my own —
  see hazards 3 and 4). What remains is **not** a test bug: the app's SSH
  connect to the fixture takes ~15s to reach the host-key prompt and in the
  latest run never reached it within 60s, while the same fixture answers a
  shell SSH login in 0.111s. That is upstream of exposé and does not affect
  the T1 result. Only `rootshellStandaloneUITests.swift` changed; Catalyst
  `build-for-testing` green throughout.
  Housekeeping: two leftover fixture containers were removed —
  `rootshell-zmx-ssh-fixture:20260830` (9 days) and
  `rootshell-zmx-fixture:local` (17 hours). **Their `Up (starting)` status was
  not a symptom**: `podman inspect --format '{{json .Config.Healthcheck}}'`
  returns `{}` for this image, and podman reports `starting` forever when no
  healthcheck is defined. They were simply leftovers, not stuck. Each run's
  own container is cleaned up correctly.

- 2026-09-08 (latest): V2 runner now executes. Four consecutive suite runs
  peeled off three separate blockers; see the V2 task note for each. Net
  result: 1 of 4 tests passing, the other 3 fixed in code but unverified
  because the machine was in use during every run. **The next action is a
  single uninterrupted foreground run of `scripts/test-macos-ui-paid-team.sh`.**
  Only `rootshellStandaloneUITests.swift` changed; no app or project changes
  were needed beyond V2a's. Catalyst `build-for-testing` green throughout.

- 2026-09-08 (latest): V2 unblocked on the signing side, still blocked on the
  host. Added `scripts/test-macos-ui-paid-team.sh` — the counterpart to
  `scripts/test-macos-ui-local.sh` that keeps the app's real paid-team
  signature instead of ad-hoc signing a rewritten disposable bundle. Two
  project fixes were needed for it: the `rootshellStandaloneUITests` target
  had upstream's team and bundle identifier hardcoded (the only target in the
  project that did), and the test hardcoded the disposable host identifier.
  Both now follow the same `ROOTSHELL_*` override the rest of the project
  uses. Verified signed (`TeamIdentifier=5WM6947328`, `Apple Development`,
  `--verify --deep --strict` clean) and the whole pipeline runs up to XCTest
  runner launch; it then fails on `Developer mode is currently disabled` —
  needs `sudo DevToolsSecurity -enable` from the user. All four local gates
  re-run green after these changes (ZmxLogic 11/11, LoginShellLogic 20/20,
  zmx-expose-checks ALL CHECKS PASSED, check-sync all 8 rows).
  Two incidental findings, both recorded under "Runner script hazards" below.

- 2026-09-08 (latest): T1+V1 done on `perf/zmx-expose-coldstart` (branched
  from `perf/zmx-expose` @ 70310e0). New `MuxZmxBootstrap` enum in
  `MultiplexerExposeAdapter.swift` (headlessly testable, no GhosttyKit
  dependency) collapses the cached-zmx cold start from 3 execs to 1 (1
  session) or 2 (N>1). All required local gates green (`Tests/ZmxLogic`,
  `Tests/LoginShellLogic`, `docs/zmx-expose-checks/run.sh` -- now 33
  sections --, and the Mac Catalyst build). Bench harness gained a
  `tick_bootstrap_seed` phase (`bench/run_bench.py`) to measure the new
  combined tick directly; `bench/sync-manifest.txt` re-pinned for the line
  shifts this change caused (hashes unchanged -- confirmed byte-identical
  before re-pinning). Full before/after sweep in RESULTS.md. V2 (XCUITest)
  not run -- see RESULTS.md and the V2 task note above for why.
- 2026-09-08 (latest): B1-B3 done — `docs/zmx-expose-perf/bench/` (script-
  level harness over real SSH, transcribed-and-sync-checked scripts,
  realistic seeded content, latency injection with a verified fallback
  proxy since netem is unreachable on this dev machine). See its README
  for the full picture, including what's verified vs. untested. Only a
  `--quick` smoke sweep and one small custom sweep have actually been run;
  the full baseline sweep (M1) has not — that's next.
- 2026-09-08 (latest): Clean baseline captured in BASELINE.md. Two earlier
  invalid runs discarded — a delay-proxy pipelining bug and 290 fixture
  zombies; both root-caused and fixed, see BASELINE.md. Conclusion: round
  trips in cold start dominate; payload and the fetchCap ramp are irrelevant
  at every tested scale.
- 2026-09-08 (later): I1 instrumentation merged and corrected (see above).
  Build green. Benchmark harness (B1-B3) still in progress.
- 2026-09-08: Rebase complete and pushed. Fixture rebuilt on zmx v0.8.1.
  Explorations complete (client-side + zmx-side). Scope set. Nothing
  benchmarked yet — no baseline exists, so no perf change may be made yet.

## Instrumentation reference (I1, done)

`rootshell/Core/Diagnostics/MuxExposeSignposts.swift` — subsystem
`com.rootshell`, category `MuxExpose` (same category the existing `Logger`
uses). View in Instruments' os_signpost track, or:

```sh
log stream --predicate 'subsystem == "com.rootshell" AND category == "MuxExpose"' --info
```

Intervals: `timeToFirstTile`, `timeToAllFrames`, `timeToAllTiles`, `detect`
(`forced=`/`skipped=`), `resolveSession`, `tick`
(`panes=`/`bytes=`/`truncated=`/`timedOut=`), `parseTick`,
`tile.surfaceCreate`, `tile.writeFrame` (`bytes=`).
Events: `resolveSession.skipped`, `tick.pace` (`immediate` or `wait=`).

**Three metrics, deliberately distinct — do not conflate them:**
- `timeToFirstTile` — open until the first pane actually paints.
- `timeToAllFrames` — open until every previewable pane has capture *data*.
  Measures the network/remote half only.
- `timeToAllTiles` — open until every *currently visible* previewable pane has
  painted. Measures what the user actually experiences. Scoped to visible
  panes because off-screen tabs never create a surface (the tray only mirrors
  cells intersecting visible bounds), so an all-panes definition would never
  fire.

The gap between `timeToAllFrames` and `timeToAllTiles` is the render cost;
the gap between open and `timeToAllFrames` is the fetch cost. That split is
the point — it decides whether Track 1 should target round trips or rendering.

### Review corrections applied on top of the agent's commit
1. Its `timeToAllTiles` actually measured frame *arrival*, not paint, and so
   under-reported the user-visible number. Split into `timeToAllFrames`
   (arrival) and a genuinely paint-based `timeToAllTiles`.
2. Intervals begun in `start()` were never terminated when an exposé closed
   before completing, leaving unterminated intervals and overlapping begins on
   one `.exclusive` lane. Added `endOpenSessionIntervals()`, called from both
   `markSessionOpened()` and `teardownLoop()`, tagging them `abandoned=true`.
3. The truncation re-parse on the unparseable-reply path ran even when nothing
   was tracing; now guarded by `signposter.isEnabled`.

## Result (T1, done and independently verified)

`66abe9f` — skip the forced `detect()` revalidation when a cached zmx binding
already has a session name; let the first tick's own `zmx list` supply the
liveness proof (`boundSessionIsUnavailable` = session missing OR
`clients == 0`, so a detached session is still caught, reaching the same
`.unsupported` + `clearCurrentPassthroughBinding()` end state). Seed that first
tick with the known session name, and only force a follow-up tick when a pane
still lacks a frame. Gated to zmx; tmux/zellij/herdr unchanged.

Cached-zmx cold start: **3 execs -> 1** (single session) or **2** (N>1).
Full numbers in `RESULTS.md`; independent re-run in
`bench/results/verify-coldstart/`.

Gates verified by hand after the merge: Catalyst BUILD SUCCEEDED, ZmxLogic
11/11, LoginShellLogic 20/20, zmx-expose-checks ALL CHECKS PASSED (33
sections), check-sync all 8 rows.

## Three run hazards that void a suite run before any test logic

Both produce a "failure" that says nothing about the code. Check for them
before reading anything into a result.

1. **`The test runner failed to initialize for UI testing. (Underlying Error:
   Authentication canceled. System authentication is running.)`** — the
   `system.privilege.taskport` prompt. Needs someone at the keyboard to
   authenticate, and it recurs; it is not a once-per-machine grant. Zero tests
   run.

2. **`Failed to activate application 'org.marquard.rootshell …' (current state:
   Running Background)`** — `app.activate()` in `setUpWithError` could not
   bring the app to the foreground, so every test fails identically, including
   `testLaunchesLocalTerminal`, which touches nothing. Seen twice in a row late
   at night; a run started by the developer at the keyboard minutes earlier
   worked. These tests need an unlocked, attended GUI session.

3. **The macOS session locks mid-run.** Every test from that point on fails
   with the hazard-2 message above, so the run looks like an app regression and
   is not one. Seen 2026-09-09 08:05: a Screen Sharing session to this Mac
   ended and macOS locked the screen immediately --

   ```
   08:06:15.958  ScreensharingAgent  SACLockScreenImmediate:271: enter
   08:06:16.317  loginwindow  -[LWShieldWindowController raiseShieldWindowWithFade:] | enter
   08:06:16.695  loginwindow  sendDistributedNotification: com.apple.shieldWindowRaised
   ```

   -- and the screen recordings for tests 2-4 are the lock screen end to end.
   **Do not run this suite over Screen Sharing**: the disconnect is what locks
   the screen. `caffeinate` does not help here; it prevents only the idle and
   screensaver variants, not a direct `SACLockScreenImmediate`.
   `scripts/test-macos-ui-paid-team.sh` now runs under `caffeinate -dimsu` and,
   afterwards, greps the unified log over the run's own window for
   `SACLockScreenImmediate`/`shieldWindowRaised`; on a hit it prints a VOID
   banner and exits non-zero even if `xcodebuild` returned 0.

   A locked screen also poisons readings taken near the lock: an assertion that
   fires after it reads an empty accessibility tree, so a count of 0 means
   "app is shielded", not "the feature produced nothing".

The tell for the first two: **all four tests fail with the same message**, and
it is not an `XCTAssert`. A genuine result has `testLaunchesLocalTerminal`
passing. The tell for the third is that tests *before* the lock behave
normally while every test after it fails identically -- check the runner's
VOID banner, or the unified log, before reading anything into the results.

## App bug found while doing V2: SSH handshake lost to a read race

**Not a test bug, not related to T1 or exposé.** Recorded here because V2 found
it; it belongs in its own change.

### Symptom

Connecting to the fixture over loopback, the SSH handshake never starts. The
TCP channel connects, then the app emits nothing further — at `debug` level —
until it is killed. No key exchange, no error. When the race is won instead,
key exchange finishes ~250ms after connect. Reproduced 3 of 3 SSH tests in
each of three consecutive suite runs; a single-test run won the race and
passed, which is what made it look nondeterministic.

### Evidence

Socket state during the hang, byte-identical across three independent hangs
(`netstat -anv -p tcp`, plus `podman exec … ps` inside the fixture):

| observation | value |
|---|---|
| app socket state | `ESTABLISHED`, **Recv-Q 0** |
| bytes app received | **2458** |
| bytes app sent | **23** |
| fixture sshd | `1 of 10-100 startups`, `sshd: [accepted]`, `sshd: [net]` |

`SSH-2.0-Rootshell_1.0\r\n` (`swift-nio-ssh-rootshell/Sources/NIOSSH/Constants.swift:16`)
is exactly **23 bytes**. So the client sent its identification string and then
nothing — no KEXINIT. Meanwhile it had already *consumed* 2458 bytes from the
kernel (Recv-Q is 0): the server's banner plus its KEXINIT. Both sides are then
waiting on each other forever.

The fixture is not involved: 60/60 shell probes over 5 minutes gave TCP connect
≤3ms and banner ≤49ms with no drift.

### Mechanism

`MPTCPBootstrap.connectPlainChannel` (`rootshell/Features/SSH/Session/MPTCPBootstrap.swift:66-93`)
returns an **already-active** channel and hands it to
`SSHClient.connect(on:settings:)` (`rootshell/Features/SSH/Session/CitadelSSHSession.swift:745`).

1. `NIOTSConnectionBootstrap` defaults `autoRead` to `true`, and MPTCPBootstrap
   sets only `.connectTimeout`, multipath, and IP version — never `autoRead`.
2. On activation, `StateManagedChannel.becomeActive0` succeeds the connect
   promise **and then** calls `readIfNeeded0()`, which issues the first read
   immediately. So reads can begin before the caller has done anything.
3. Citadel installs `NIOSSHHandler` and `ClientHandshakeHandler` afterwards,
   asynchronously, via `channel.eventLoop.flatSubmit { addHandlers }`
   (`Citadel-rootshell/Sources/Citadel/Client.swift:280-308`,
   `ClientSession.swift:264-300`). It never disables `autoRead` and never
   issues an explicit `read()`.
4. Bytes that land in that window are fired down a pipeline with no inbound
   handler and are discarded at
   `StateManagedNWConnectionChannel.channelRead0` — whose entire body is
   `// drop the data, do nothing`.
5. `NIOSSHHandler` builds its `SSHConnectionStateMachine` in `init`, so there
   is no replay: the parser never sees the version string that already
   arrived. The client writes its own ident, the server has nothing left to
   send, and both block.

OpenSSH sends its banner within ~20ms of accept and does not wait for the
client's ident before sending KEXINIT, so on loopback the server almost always
wins this race — which is why it reproduces here far more readily than against
a remote host.

### Why nothing times out

- Citadel's `loginTimeout` **is** armed on this path
  (`ClientSession.swift:157-164`), but rootshell sets it to 300s
  (`SSHHandshakeHandler.swift:31`, applied at `CitadelSSHSession.swift:737`)
  to cover host-key approval and OTP entry. The tests kill the app long before.
- `InitialConnectRetry`'s "30s attempt-1 timeout" is not a deadline on the
  operation: `run` awaits `operation(attempt, policy.timeout)` directly with no
  timeout wrapper (`InitialConnectRetry.swift:131`); the value is passed
  through and used only as the TCP `connectTimeout` cap. Once TCP is up it can
  never fire. It also logs only in its `catch` branches, so zero lines from it
  is the expected signature of a first attempt parked forever.

### Fix (done, build-verified, not yet run-verified)

Branch `fix/ssh-handshake-read-race` off `main` — commit
`Fix SSH handshake lost to a read race on pre-connected channels`. The same
commit is on `perf/zmx-expose` so the perf work can continue here; the two are
byte-identical.

`MPTCPBootstrap.connectPlainChannel` gains `deferReads:` (default `false`, so
it is opt-in per call site). When set, the bootstrap is given
`ChannelOptions.autoRead = false`. Bootstrap channel options are applied before
the channel is registered or connected — `NIOTSConnectionBootstrap.connect`
applies options, then the initializer, then `register()`, then connect — so
`becomeActive0`'s `readIfNeeded0()` is a no-op and not one byte is read until
armed.

`MPTCPBootstrap.armReadsWhenSSHHandlerInstalled(on:within:)` arms them once
`NIOSSHHandler` is in the pipeline. Setting `autoRead` back to `true` issues the
first read immediately — NIOTS's `setOption0` calls `readIfNeeded0()` — so
nothing is missed. Citadel exposes no "handlers installed" hook, so the pipeline
is polled on the channel's own event loop at 1ms via `scheduleRepeatedTask`. If
the handler never appears, reads are armed anyway at the 10s deadline, so a
caller that did something else with the channel degrades to the old behaviour
rather than hanging.

All 16 call sites opt in. An audit confirmed every one hands the channel
straight to `SSHClient.connect(on:settings:)` with nothing in between, so the
"wait for `NIOSSHHandler`" rule is universally valid here: `CitadelSSHSession`,
`SSHConnectionHelper`, `HeadlessSSHExecutor`, `MoshServerSpawner`,
`UDPHolePuncher`, `TSSHSpawnHelper`, `AIAgentExecutor`, `GitSSHTransport` —
jump and direct in each.

Not chosen: patching the vendored Citadel fork's `addHandlers`. It would fix
every caller at once, but changes a dependency; the rootshell-side fix has the
smaller blast radius.

**Verified.** Suite run 2026-09-08 23:04. All three SSH-dependent tests now
connect, complete the handshake, accept the host key and reach a remote shell
prompt — the hang is gone. Their failures moved past the connection entirely:

| test | before the fix | after |
|---|---|---|
| `testCommandTFromSSHLeavesLocalTerminalReady` | never connected | reaches Cmd-T, `("1") is less than ("2")` |
| `testDetachThenTabExposeReturnsToLocal` | never connected | reaches exposé, "Tab Exposé did not open" |
| `testSSHZmxExposeUsesRealConnectionUI` | never connected | reaches exposé, "Tab Exposé did not open" |

`testLaunchesLocalTerminal` still passes. Catalyst `build-for-testing` is green
and warning-free (the first draft of the arming helper used `@Sendable` local
functions, which are an error in Swift 6 language mode; `scheduleRepeatedTask`
replaced them).

Note the two attempts before this one never reached a test at all —
`The test runner failed to initialize for UI testing. (Underlying Error:
Authentication canceled. System authentication is running.)`, the
`system.privilege.taskport` prompt. It needs someone at the keyboard, and it
recurs; treat it as a run hazard, not a failure.

## Runner script hazards (found while doing V2)

1. **`set -u` + empty array + bash 3.2 = a failure that reports success.**
   macOS `/bin/bash` is 3.2.57, where `"${arr[@]}"` on an *empty* array is an
   unbound-variable error under `set -u`. Worse, bash 3.2 then runs the `EXIT`
   trap with `$?` set to **0**, so the common
   `cleanup() { local status=$?; ...; exit "$status"; }` pattern converts the
   hard failure into exit 0. The first V2 run hit exactly this and reported
   success while never having run a single test.
   `scripts/test-macos-ui-paid-team.sh` now guards it with a `COMPLETED` flag
   the trap checks before believing a zero status.
   **`scripts/test-macos-ui-local.sh` still has the unguarded pattern.**

2. **`scripts/test-macos-ui-local.sh` is currently unrunnable on this
   checkout**, independent of signing policy: it requires `origin/macos-local-dev`
   (no such ref here — and `Configuration/LocalUITest*.entitlements` are now
   tracked in the repo, so the overlay looks obsolete), and it greps
   `SocketCommandServer.swift` for a helper-trust literal that main replaced
   with the `HelperPeerTrust` Info.plist lookup, exiting 1 when it is absent.

3. **`XCUIElement.hasFocus` is a compile-time trap.** It is declared under
   `#if !TARGET_OS_OSX`, so it *compiles* for a Mac Catalyst UI-test target —
   and then throws `NSInternalInconsistencyException` ("Calling hasFocus on
   element is not supported on a macOS") at runtime, failing every test that
   touches it. There is no public way to confirm keyboard focus here; let
   `typeText`'s own "Neither element nor any descendant has keyboard focus"
   assertion be the authoritative failure.

4. **`XCUIApplication.isEnabled` is not a frontmost signal.** The root
   Application element reports `Disabled` — as does its whole subtree —
   whenever a modal is up, including in runs where interaction then works
   fine. Gating the suite on it fails all four tests. `state ==
   .runningForeground` does not detect inactivity either.

6. **An `exists` assertion on a long-lived overlay always passes.** Views
   like `TabExposeView` set their `accessibilityIdentifier` in `init` and
   merely toggle `isHidden`, so the element is in the accessibility tree the
   whole time and `waitForExistence` proves only that the app launched.
   Assert on a property the feature actually changes when it opens — for
   Tab Exposé that is `accessibilityValue`, which is `nil` until activation.
   This masked a wrong-chord bug for the entire life of the helper.

7. **Check keybind chords against `KeybindManager`, not memory.** The
   exposé helper sent `Cmd-Shift-Backslash` (`toggle_tab_switcher`, the
   vertical tab bar) for years while intending `Cmd-Shift-A`
   (`toggle_tab_expose`). Both chords are bound, so nothing errored. Where a
   Catalyst menu item exists for the action — `Tabs → Tab Exposé`
   (`rootshell/App/CatalystAppDelegate.swift:1491-1496`) — clicking it is
   more deterministic than synthesizing a chord, since it does not depend on
   which view holds first responder.

8. **The app can instrument itself; use it before writing new probes.**
   Adding `-sshDebugLoggingEnabled YES` to `app.launchArguments` turns on
   `SSHDebugLogger`, which writes to
   `ForkUITestConfiguration.sterileHomeDirectory/.ghostty/ssh_debug.log` —
   inside the run directory, so it never touches the developer's real
   Documents. The runner deletes that directory on exit, so copy the file out
   while the run is live. Pair it with
   `log stream --level info --style compact --predicate 'subsystem ==
   "com.rootshell"'`: the os_log timestamps split TCP connect from KEX from
   the user-decision wait, which the single `CONN … elapsed=` figure cannot.

5. **The xcresult's screen recordings are the highest-value evidence** and are
   easy to forget: the failure text alone sent this investigation down two
   wrong paths (app activation, then keyboard focus), and one extracted video
   frame overturned both and showed the real bug. UI Snapshot attachments are
   `NSKeyedArchiver` plists, not images — go for the `.mp4`:
   ```sh
   xcrun xcresulttool export attachments --path <run>.xcresult --output-path /tmp/att
   # manifest.json maps testIdentifier -> exportedFileName
   ffmpeg -sseof -1 -i /tmp/att/<id>.mp4 -frames:v 1 -y /tmp/last.png
   ```
   `fixtureConnectionDiagnostics` now also dumps a bounded inventory of the
   static texts, buttons, sheets, and alerts the query actually sees, which is
   what finally distinguished "the dialog is up but unmatched" from "the app
   is not on screen at all".
