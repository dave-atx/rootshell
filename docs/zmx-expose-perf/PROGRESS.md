# zmx exposé performance — working notes

**Purpose:** make "show all zmx tabs in exposé" faster, with every change proven
by benchmark + tests. This file is the resume point: it must be enough to pick
the work back up cold, without re-reading the whole codebase.

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
- [ ] **B1** Build script-level benchmark harness (real SSH → fixture, runs the
      real `tickScript`, sweeps session count × latency, reports per-phase wall
      time and byte counts)
- [ ] **B2** Add host-side latency injection (0/30/80ms). netem needs NET_ADMIN
      which rootless podman may deny — fall back to a host TCP delay proxy.
- [ ] **B3** Seed sessions with realistic coloured scrollback (empty shells
      produce unrealistically tiny captures)
- [ ] **I1** Add instrumentation to the MuxExpose path (signposts + structured
      timing covering detect / resolveSession / each tick / parse / render)
- [ ] **M1** Capture and record the BASELINE numbers in `BASELINE.md`
- [ ] **T1** Implement Track 1 changes *justified by the baseline data only*
- [ ] **V1** Re-benchmark; prove faster + no regressions; record in `RESULTS.md`
- [ ] **V2** One end-to-end XCUITest run as whole-system confirmation

## Status log

- 2026-09-08: Rebase complete and pushed. Fixture rebuilt on zmx v0.8.1.
  Explorations complete (client-side + zmx-side). Scope set. Nothing
  benchmarked yet — no baseline exists, so no perf change may be made yet.
