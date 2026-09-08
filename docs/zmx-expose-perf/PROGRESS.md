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
- [ ] **V2** One end-to-end XCUITest run as whole-system confirmation.
      BLOCKED, deliberately. The relevant test is
      `testDetachThenTabExposeReturnsToLocal` — exactly the detach path this
      change alters — but `scripts/test-macos-ui-local.sh` ad-hoc-signs the
      build and resets host TCC/LaunchServices state. The user's standing rule
      is never to ad-hoc sign or strip entitlements, so this must NOT be run
      via that script without asking. Running it under the paid-team dev
      signing config instead is possible but also resets host state — ask
      first.. NOT
      run: the existing `testDetachThenTabExposeReturnsToLocal` (attach,
      expose, detach, expose again, expect local + no stale cell) is exactly
      this, but it runs through `scripts/test-macos-ui-local.sh`, which
      ad-hoc-signs the build and resets host TCC/LaunchServices state --
      out of step with this environment's paid-team-signing policy, so
      deliberately not run here. See RESULTS.md's correctness section.

## Status log

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
