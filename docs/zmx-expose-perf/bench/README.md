# zmx exposé perf bench

Measures where the time actually goes in one zmx exposé refresh tick, over a
**real SSH connection** to the **real zmx fixture** (`Tests/ZmxFixture/`),
running the **real scripts** rootshell sends -- not a reimplementation of the
app's behavior, a benchmark harness for it. This directory makes no app or
zmx behavior changes; see `docs/zmx-expose-perf/PROGRESS.md` for the ground
rules and the plan this harness serves (steps B1-B3 there).

## Quick start

You need an already-running fixture (this harness never starts, stops, or
rebuilds one -- image builds take ~3 minutes, so it deliberately stays out
of that business):

```sh
cd /Users/dave/src/rootshell
Tests/ZmxFixture/zmx-fixture.sh start --env-file /tmp/zmx.env   # if none is running yet
```

Then, from `docs/zmx-expose-perf/bench/`:

```sh
./run-bench.sh --env-file /tmp/zmx.env --quick
```

`--quick` runs a tiny smoke sweep (1 and 3 sessions, 0ms latency, 2 reps) in
well under a minute -- use it to confirm the harness still works before
committing to a full sweep. Drop `--quick` and pass your own `--sessions`,
`--latencies`, `--reps` for a real run:

```sh
./run-bench.sh --env-file /tmp/zmx.env \
    --sessions 1,3,5,8,10,16,24 \
    --latencies 0,30,80 \
    --reps 7 \
    --out-dir results/baseline
```

Output goes to `results.json` (full detail), `results.tsv` (one row per
phase per config, for spreadsheets), and `summary.txt` (the same table
printed to stdout).

If you only have a state directory (no env file handy):

```sh
./run-bench.sh --state-dir "$ZMX_FIXTURE_STATE_DIR" --quick
```

The harness creates and destroys its own sessions (named
`<fixture-prefix>-bench00`, `-bench01`, ...) and cleans them up after every
session-count step and on exit, including on error. It never touches
sessions it did not create.

## What gets measured, and why those four phases

Every zmx exposé refresh tick is one SSH exec of a script built by
`ZmxExposeAdapter.tickScript` (`rootshell/Features/Multiplexer/Expose/ZmxExposeAdapter.swift`),
which runs `zmx list` then, serially per session, `zmx history <name> --vt |
tail -n 80`. Before the first tick can even happen, `MultiplexerExposeFeed`
runs `detect()` (identifies which multiplexer a pane is inside -- a heavy
`ps`/`lsof`/`/proc` process-tree walk) and `resolveSession()` (a lightweight
"is there exactly one session" check). Both gate time-to-first-tile.

Per (latency, session count) configuration, the harness times:

| phase | what it runs | mirrors |
|---|---|---|
| `detect` | the full process-tree probe | `MultiplexerExposeFeed.detect()` |
| `resolve_session` | `zmx list --short` | `MultiplexerExposeFeed.resolveSession()` / `ZmxExposeAdapter.resolveSessionScript` |
| `tick_topology_only` | `zmx list`, no captures (`fetch=[]`) | a tick that only needs to redraw topology |
| `tick_with_captures` | `zmx list` + `zmx history --vt \| tail -n 80` for every seeded session | a full refresh tick |

Each phase runs `--reps` times (default 5) per configuration and reports
**median, min, max** wall-clock milliseconds and reply byte size -- never a
single sample. Content and session counts are fixed per run (seeded from a
deterministic RNG, see below), so the *inputs* are reproducible; wall-clock
*outputs* will vary run to run and host to host, same as any live-network
benchmark.

## Why the scripts are transcribed, not imported

There is no headless way to import Swift app code without Xcode. Instead,
`lib/mux_scripts.py` is a **byte-faithful transcription** of the exact
Swift functions that build these scripts (`ZmxExposeAdapter.tickScript`,
`.resolveSessionScript`, `MultiplexerExposeFeed.detect()`'s probe body,
`MuxScript.wrap`/`.dq`, `LoginShellCommand.singleQuoted`/`.pathPrefix`,
...). Every function has a docstring naming its Swift source.

Faithfulness is enforced, not assumed: `check-sync.sh` hashes the exact
Swift source line ranges each function claims to mirror (pinned in
`sync-manifest.txt`) and fails the whole run if they've drifted --
`run-bench.sh`/`run_bench.py` run it automatically before every sweep
(override with `--skip-sync-check` or `ZMX_BENCH_SKIP_SYNC_CHECK=1`, only
for a deliberate, already-reviewed drift). This is not theoretical: during
this harness's own development, a concurrent commit
(`1128243 Add signposts to the zmx exposé pipeline for baseline
measurement`) moved `detect()`/`resolveSession()`/`nonce()` by 40-100 lines
inside `MultiplexerExposeFeed.swift` while this file was being written, and
`check-sync.sh` caught it immediately. The manifest was re-verified and
re-pinned against the new line numbers (confirmed via `git diff`, that
change is instrumentation-only -- signposts wrapped around the same
script-building and `RemoteExecProbe.run` calls, zero bytes different on
the wire). **If you see a `check-sync: FAILED` before a future run,
that is the harness doing its job -- re-verify and re-pin, don't just
skip it.**

Every script this module builds is handed to `ssh user@host "<script>"` as
a single argument -- the same shape `RemoteExecProbe.run` hands Citadel's
`client.executeCommand` (one SSH exec-channel request carrying the whole
command string).

## Realistic seeded content

An empty `/bin/bash` session captures to a few dozen bytes -- unrealistically
tiny, and it would invalidate every capture-phase number. `lib/gen_content.py`
generates several hundred lines of mixed ANSI/SGR content (colours,
bold/italic/underline, resets, varying line lengths -- shaped like build
output / log tail / `ls --color`, deterministic per session name via a
seeded RNG) and injects it directly into each session's terminal state via
`zmx print <name>` (zmx's `.Output` IPC tag: the daemon applies the exact
bytes you send to its VT parser, bypassing the shell entirely -- see
`main.zig`'s `send()`/`print` command).

**Found empirically while building this**: a single `zmx print` call
carrying more than roughly **4089-4090 bytes** silently fails on zmx
v0.8.1 -- the session ends up back at a bare prompt as if nothing was
sent, `zmx print` still exits 0, no error anywhere. Reproduced with no SSH
in the loop at all (`podman exec` directly into the fixture container), so
it's a zmx behavior, not an SSH/transport artifact, and it was not a race
(a 1-second sleep before reading it back made no difference). Binary search
pinned the boundary between 4088 (reliably works) and 4090 (reliably
fails), independent of the specific bytes. Not investigated further or
patched -- zmx is pinned read-only for this task (v0.8.1, no changes) --
just worked around: `run_bench.py` sends seeded content in chunks of
`SEED_CHUNK_BYTES = 3000` (comfortably under the cliff), sequential
`zmx print` calls over the same SSH connection. Verified working up to the
default 200-line seed (about 19KB, ~7 chunks/session) with no corruption or
truncation in the resulting `history --vt` capture. If you bump
`--seed-lines` a lot, the chunking still applies automatically; no flag
needed.

`gen_content.py` also had to switch its line separator from `\n` to `\r\n`:
because `.Output` injects directly into the VT stream rather than through a
PTY (which is what normally translates a shell's bare `\n` into `\r\n`), a
lone `\n` only moves the cursor down a row and leaves its column alone
(true VT100 semantics) -- observed as content "staircasing" further right
each line instead of starting a fresh one.

## Latency injection: what was tried, what actually works here

The brief asked to try `tc netem` inside the container first, expecting
rootless Podman to deny it for lack of `NET_ADMIN`. What was actually found
differs and is worth recording precisely (`netem/try_netem.sh` does the
real check every run, not a hard-coded answer):

1. The fixture image ships no `tc` at all (`Tests/ZmxFixture/Containerfile`
   never installs `iproute2` -- it never needed to before).
2. To find out whether the *capability* story was really the blocker, a
   throwaway `debian:12-slim` container (not the fixture) was started with
   `podman run --cap-add=NET_ADMIN` and had `iproute2` installed at
   runtime. **NET_ADMIN was granted** -- `tc qdisc add dev eth0 root netem
   delay 30ms` did not fail on permissions.
3. It failed anyway: `Error: Specified qdisc kind is unknown.` The podman
   machine backing this host (`podman-machine-default`, Apple Hypervisor,
   Fedora CoreOS kernel `6.12.13-200.fc41.aarch64`) has **no `sch_netem`
   kernel module anywhere** (`find /lib/modules -iname '*netem*'` inside
   the machine returns nothing, and there is no `modprobe` in the
   container to load one even if there were). So on this dev machine,
   netem is unreachable at the kernel level, a level below the
   capability question the brief anticipated.

`try_netem.sh` still performs both checks for real (tc presence, then a
live `tc qdisc add`) every time it's asked, so it keeps telling the truth
if either constraint is ever lifted (a fixture image with `iproute2` baked
in, or a podman machine whose kernel carries `sch_netem`) -- **the netem
success path itself is therefore implemented but unverified**; nothing in
this environment could exercise it.

**Fallback (what every run on this machine actually uses):**
`netem/delay_proxy.py`, a plain asyncio TCP relay sitting between SSH and
the fixture's published loopback port. It delays every relayed chunk by
`--delay-ms` in each direction independently, so a full round trip through
it gains roughly `2 x --delay-ms`. `run_bench.py` runs it at
`target_rtt_ms / 2` per hop.

**Verifying the delay is real** (not just trusting the CLI flag that
started the proxy): `netem/measure_rtt.py` opens a raw TCP connection and
times how long the SSH server's version banner takes to arrive. sshd sends
that banner unprompted the instant it accepts the TCP connection -- no
handshake, no auth, no crypto -- so this isolates exactly one one-way
network hop. Every sweep run measures this twice per latency level: once
straight to the fixture (baseline) and once through the proxy, and reports
both plus their delta in `results.json` under
`configs[].latency_measured`. Example from a real run on this machine, target
+30ms RTT (proxy configured at 15ms/hop):

```json
{"direct_one_hop_ms": 6.339, "via_proxy_one_hop_ms": 23.972,
 "verified_added_one_hop_ms": 17.633, "implied_added_rtt_ms": 35.266,
 "configured_delay_ms_per_hop": 15.0}
```

Loopback-through-the-podman-machine baseline latency on this host runs
several milliseconds (not the ~0.2ms flat loopback the ground rules in
`PROGRESS.md` assumed) -- Podman's userspace networking (gvproxy/pasta
inside the Apple Hypervisor VM) adds real, measurable overhead of its own.
Worth keeping in mind when reading the 0ms-latency baseline numbers: they
already include a few milliseconds of virtualization tax that a bare-metal
Linux host would not have.

One more thing the numbers above show: injected latency does not map 1:1
onto tick wall-clock time. A tick over an *already-open, multiplexed* SSH
connection still crosses the wire more than once (open a channel, send the
exec request, stream the reply, close it), so a 30ms target RTT typically
adds noticeably more than 30ms to a tick's wall time -- expect a multiple
of the injected one-way delay, not a flat addition. `results.json` gives
you the actual verified injection alongside the actual tick timings so you
can see this directly rather than assume a ratio.

## What each result field means

- `median_ms` / `min_ms` / `max_ms` -- wall-clock time for one SSH exec of
  that phase's script, over an already-open ControlMaster connection (see
  below), across `--reps` repetitions.
- `median_reply_bytes` / `max_reply_bytes` -- size of the raw script output
  (nothing truncated on the harness's side -- see next point).
- `would_exceed_response_cap` -- true if any rep's *actual, untruncated*
  reply would have exceeded the cap `RemoteExecProbe`/Citadel enforces for
  that call in the real app (`tick`: 512KB `responseCap`; `detect`: 64KB;
  `resolveSession`: 16KB -- see `MultiplexerExposeFeed.swift`). The harness
  itself never truncates, so this tells you how close to the real cap a
  configuration runs, not just whether it happened to get cut off.
- `exceeded_tick_timeout` -- true if any rep took longer than the app's 5s
  `tickTimeout`, i.e. the real app would have discarded that whole tick.
- `capture_bytes_per_session` -- actual `zmx history <name> --vt | tail -n
  80` byte size per seeded session, measured once per configuration right
  after seeding (not a rep-averaged figure -- content is fixed per
  session, so this number does not vary across reps).

## One SSH connection per latency level, reused throughout

`run_bench.py` opens exactly one `ssh -M -N -f -S <ctrlpath>`
ControlMaster per latency level and reuses it for every session count and
every rep at that latency -- each phase measurement is a new *exec
channel* on that connection, never a fresh TCP+SSH handshake. This mirrors
the real app: `RemoteExecProbe.run` always runs over the pane's
already-connected Citadel session (see that file's doc comment) --
opening a new connection per tick is not something the real code does, and
a benchmark that did that would be measuring handshake cost, not tick
cost.

## Files

```
check-sync.sh          verifies lib/mux_scripts.py against sync-manifest.txt
sync-manifest.txt       path:start:end:sha256 pins over the Swift source
lib/mux_scripts.py       transcribed script builders (tick/resolveSession/detect)
lib/gen_content.py       deterministic ANSI/SGR scrollback generator
netem/try_netem.sh       best-effort in-container tc netem attempt
netem/delay_proxy.py     host-side TCP delay proxy (the fallback that actually runs here)
netem/measure_rtt.py     verifies injected latency via SSH banner arrival time
run_bench.py             the sweep driver
run-bench.sh             thin entry point (env validation, hands off to run_bench.py)
results/                 default --out-dir location (gitignored)
```

## Known-untested paths

- The netem *success* path (`try_netem.sh` returning 0, `run_bench.py`
  using `tc qdisc add`/`del` directly instead of the proxy) has never run
  against a working `sch_netem` -- there is no such kernel available on
  this machine to test it against. Code review only.
- Only `--quick` and one small non-default sweep (`--sessions 1,5
  --latencies 0,30 --reps 3`) have actually been run end to end (see
  `results/` in this session's log if still present, or re-run to
  reproduce). **The full default sweep (1,3,5,8,10,16,24 sessions x
  0/30/80ms x N reps) has deliberately not been run as a final act** --
  per the task brief, a working, documented harness beats a half-finished
  measurement run. `./run-bench.sh --env-file ... ` with no other flags
  runs it.
- 16 and 24 sessions are included as out-of-range reference points per the
  brief, but this harness's own smoke testing stayed at 1 and 5 sessions
  to keep iteration fast; nothing about the higher counts is expected to
  behave differently, but they haven't been specifically exercised here.
