# Results — `perf/zmx-expose-coldstart`

Source: `bench/results/coldstart-v1/` (7 reps, medians), same sweep shape as
`BASELINE.md`. zmx v0.8.1 (`8bab1f0`). Fixture restarted before the run;
`zombies_before=0`.

## What changed

`MultiplexerExposeFeed.run()`/`tick()` (see `MultiplexerExposeAdapter.swift`'s
new `MuxZmxBootstrap` enum and `docs/zmx-expose-perf/PROGRESS.md`'s design
section for the full reasoning):

1. **Skip the forced `detect()` revalidation for a cached zmx binding.**
   `ZmxExposeAdapter.tickScript` already runs `zmx list` on every tick, and
   `parseTick` already trusts that listing as authoritative for liveness
   (`boundSessionIsUnavailable`) — the same check the steady-state loop
   already used to catch a mid-life detach. The first tick now supplies that
   proof instead of a dedicated `detect()` probe.
2. **Seed the first tick's fetch list with the already-known session name**
   (`MuxZmxBootstrap.seededFetch`), instead of a topology-only first tick
   that fetches nothing.
3. **Only force a second, immediate tick when something is still
   unfetched** (`MuxZmxBootstrap.needsImmediateFollowUp`), instead of
   unconditionally, so the 1-session case needs no second tick at all.

`detect()` is unchanged and still runs in full for the genuinely-unknown
case (no cached binding at all). tmux/zellij/herdr are untouched: both
`MuxZmxBootstrap` functions are no-ops for any `type != .zmx`, verified by
`docs/zmx-expose-checks/main.swift` section 33.

## Correction to the BASELINE/PROGRESS "4 round trips" framing

Re-reading `MultiplexerExposeFeed.run()` before touching it: for the
**cached zmx binding** path specifically, `resolveSession()` never actually
ran even before this change. `Ghostty.TerminalView.RawMultiplexerBinding`
only ever carries a zmx `sessionName` that is non-nil — `bindPassthroughMultiplexer`
takes a non-optional `String`, and `detect()`'s own zmx candidate branch
`guard let session else { continue }`s away any candidate it cannot name — so
`sessionName == nil` is never true once a zmx binding exists, and the
existing `resolveSession.skipped` signpost event (unchanged, already present
before this branch) fires on every such run. The actual old sequence for
this path was **3** sequential execs (`detect` → topology tick → capture
tick), not 4. The before/after numbers below reflect that 3-exec baseline,
not the 4-exec figure `BASELINE.md`/`PROGRESS.md` state — that figure looks
like it describes the general framework (tmux/zellij *can* have a nil
session name and *do* call `resolveSession()`), generalized to zmx without
checking the invariant above. Flagging this rather than quietly using
whichever number made the win look bigger.

## Round trips, cached-zmx-binding cold start

| | old | new |
|---|---|---|
| 1 session | 3 execs (detect, topology tick, capture tick) | **1 exec** (combined validate+topology+capture tick) |
| N>1 sessions | 3 execs | **2 execs** (combined tick above, then one more capture tick for the remaining N-1 sessions — unchanged in shape from today's capture tick) |

## Before/after (median ms), derived from `bench/results/coldstart-v1/`

"old" = `detect + tick_topology_only + tick_with_captures` (the sequence the
cached-zmx path actually ran). "new" = `tick_bootstrap_seed` alone at 1
session, else `tick_bootstrap_seed + tick_with_captures` (using
`tick_with_captures`'s all-N-sessions cost as a deliberately conservative
stand-in for "the remaining N-1" — the real second tick is slightly
cheaper, so these savings are, if anything, understated).

### 0ms added latency

| sessions | old | new | saved | saved % |
|---|---|---|---|---|
| 1  |  62.1 |  11.7 |  50.4 | 81% |
| 3  |  83.1 |  26.2 |  56.9 | 68% |
| 5  |  87.6 |  29.3 |  58.3 | 67% |
| 8  | 115.8 |  33.2 |  82.6 | 71% |
| 10 | 135.2 |  38.5 |  96.7 | **71%** |
| 16 | 185.4 |  42.5 | 142.9 | 77% |
| 24 | 256.0 |  51.7 | 204.3 | 80% |

### 30ms added latency

| sessions | old | new | saved | saved % |
|---|---|---|---|---|
| 1  | 293.1 | 105.2 | 187.9 | **64%** |
| 3  | 324.9 | 189.4 | 135.5 | 42% |
| 5  | 350.8 | 208.5 | 142.3 | 41% |
| 8  | 373.0 | 219.2 | 153.8 | 41% |
| 10 | 379.7 | 216.7 | 163.0 | **43%** |
| 16 | 436.3 | 229.2 | 207.1 | 47% |
| 24 | 494.6 | 227.0 | 267.6 | 54% |

### 80ms added latency

| sessions | old | new | saved | saved % |
|---|---|---|---|---|
| 1  | 630.3 | 197.2 | 433.1 | **69%** |
| 3  | 623.1 | 392.5 | 230.6 | 37% |
| 5  | 663.3 | 404.9 | 258.4 | 39% |
| 8  | 697.6 | 408.7 | 288.9 | 41% |
| 10 | 711.4 | 422.1 | 289.3 | **41%** |
| 16 | 756.9 | 431.3 | 325.6 | 43% |
| 24 | 825.4 | 428.5 | 396.9 | 48% |

**Highlighted rows are the ones the task asked for specifically: 1 and 10
sessions at 0/30/80ms.**

## What the data says

1. **The win is real and holds at every tested latency and session count.**
   At 1 session (the single most common case per the ground rules' "under
   10 sessions") the round-trip collapse removes 2 of 3 execs outright,
   saving 64-81% of the cached-path cold-start time depending on latency.
2. **At N>1 the saving is smaller but still substantial (~37-54%)** because
   a second tick is still needed to fetch the other sessions' previews —
   exactly as expected: only the `detect()` + topology-only-tick portion of
   the chain was eliminated, not the fundamental need to fetch N-1 more
   captures.
3. **`detect()`'s cost (the piece being removed) still grows with session
   count** exactly as `BASELINE.md` found (39ms → 206ms at 0ms latency
   across 1→24 sessions) — so the *relative* win from removing it shrinks a
   little as N grows within one tick's ability to fetch everything (the
   second tick still needs to run), but the *absolute* saved milliseconds
   actually grows with N (204ms saved at 24 sessions vs 50ms at 1, 0ms
   latency) since `detect()` itself gets more expensive.
4. **Payload remains a non-issue.** `tick_bootstrap_seed`'s reply size
   barely grows with N (fixed at ~1 capture regardless of session count,
   ~572B topology + ~7.7-8KB for the one capture) — confirms it is not
   reintroducing the truncation-ramp cost the baseline ruled out.

## Correctness verification (detach must still be caught)

The task's hard constraint: a zmx session detached while the feed's cached
binding is stale must never be shown as live.

**Mechanism relied on**: `ZmxExposeAdapter.parseTick`'s existing
`boundSessionIsUnavailable(session)` check (`!census.sessions.contains(session)
|| census.clients[session] == 0`), fed by the SAME `zmx list` output the
combined first tick already requests. When it fires, `parseTick` returns
`nil`; `MultiplexerExposeFeed.tick(generation:)`'s existing unparseable-reply
handling (unchanged by this branch) detects the zmx-specific case and calls
`clearCurrentPassthroughBinding()` then returns `.unsupported`, which
`run()`'s loop turns into `giveUp("tick: session no longer usable")` —
`state = .unsupported`, `loop = nil`, `terminal.passthroughMultiplexer =
nil`, `onChange?()`. This is the **exact same end state and the exact same
`clearCurrentPassthroughBinding()` call** a conclusive `detect()` failure
reaches on the genuinely-unknown path — the only thing that changed is which
code path proves it.

**How this was verified:**
- **Live-fixture protocol check** (real zmx v0.8.1, not synthetic): seeded a
  session with `zmx print` (no client ever attached) and confirmed
  `zmx list` reports `clients=0` for it — the exact field
  `boundSessionIsUnavailable` reads. A real detach clears the same field the
  same way (same zmx code path), so this confirms the signal the mechanism
  depends on is accurate at the protocol level.
- **Headless pure-logic tests** (`docs/zmx-expose-checks/main.swift`
  sections 31/32, pre-existing and unmodified): synthetic-data coverage of
  `boundSessionIsUnavailable` and the client-count census this relies on.
- **New headless tests** (section 33): `MuxZmxBootstrap.seededFetch` and
  `.needsImmediateFollowUp` in isolation — confirms the bootstrap-seed logic
  activates only for zmx, only when the topology is genuinely unknown, and
  never suppresses the follow-up tick tmux/zellij/herdr rely on.
- **STILL NOT run** (updated 2026-09-08): the existing whole-system XCUITest
  `testDetachThenTabExposeReturnsToLocal` in
  `rootshellStandaloneUITests.swift` (attaches, opens exposé, detaches with
  Ctrl-\, reopens exposé, asserts it falls back to `local` state and the
  detached session's cell is gone) is exactly the end-to-end confirmation
  PROGRESS.md's V2 step asks for, and would be the strongest possible check
  for this. **The signing objection no longer applies**:
  `scripts/test-macos-ui-paid-team.sh` now runs the suite under this
  checkout's own paid team with no ad-hoc signing, no entitlement stripping,
  no bundle-identifier rewriting, no `lsregister` and no `tccutil reset` —
  and it was confirmed to build, sign
  (`org.marquard.rootshell`, `Apple Development: Dave Marquard`, team
  `5WM6947328`, `codesign --verify --deep --strict` clean), seed the fixture,
  patch the xctestrun and launch the runner. It then fails at runner
  initialization because macOS developer mode is disabled on this host
  (`DevToolsSecurity -status` → *"Developer mode is currently disabled"*;
  XCTest reports *"The test runner failed to initialize for UI testing.
  (Underlying Error: Authentication canceled. System authentication is
  running.)"*). What is actually required is one interactive authentication
  of the `system.privilege.taskport` right (currently `authenticate-user
  true`, `group _developer`, `shared true`, `timeout 36000`), which XCTest
  needs for `task_for_pid` on the app under test. Answering the "Developer
  Tools Access" dialog once at the keyboard covers 10 hours and changes
  nothing permanently; `sudo DevToolsSecurity -enable` stops the prompt for
  good but is convenience, not a prerequisite. Either way it needs the user's
  password and so is theirs to run, not an agent's.
  So this remains the one item from the task's "what could you NOT verify"
  ask: **the `testDetachThenTabExposeReturnsToLocal` end-to-end run is still
  unverified by this change**. The reasoning above and the mandatory local
  gates (all green, re-run after the V2 enabling changes) are the evidence in
  hand; re-running `scripts/test-macos-ui-paid-team.sh` after developer mode
  is enabled is the one remaining step.
