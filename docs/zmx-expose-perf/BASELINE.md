# Baseline — zmx exposé, clean fixture

Source: `bench/results/baseline-v2/` (7 reps, medians). zmx v0.8.1 (`8bab1f0`).
Fixture restarted with `--init` immediately before the run; `zombies_before=2`.

**Do not compare against `bench/results/baseline/` (v1). It is invalid** — see
"Two invalid runs" below.

## Numbers (median ms)

### 0ms added latency
| sessions | detect | resolve_session | tick_topology | tick_with_captures | reply bytes |
|---|---|---|---|---|---|
| 1  |  30.9 |  8.7 |  9.2 | 10.8 |   7,954 |
| 3  |  43.4 |  9.4 |  9.9 | 12.9 |  24,155 |
| 5  |  50.7 |  9.5 | 10.1 | 15.6 |  39,808 |
| 8  |  68.0 |  9.9 | 10.9 | 19.1 |  63,626 |
| 10 |  79.6 | 10.3 | 10.6 | 19.5 |  79,706 |
| 16 | 116.5 | 10.8 | 11.3 | 25.1 | 126,576 |
| 24 | 164.9 | 12.1 | 11.7 | 32.7 | 191,703 |

### 30ms added latency
| sessions | detect | resolve_session | tick_topology | tick_with_captures |
|---|---|---|---|---|
| 1  | 114.2 |  82.5 |  92.7 |  94.7 |
| 10 | 153.5 | 105.8 | 103.7 | 121.0 |
| 24 | 239.8 | 100.6 | 109.1 | 119.1 |

### 80ms added latency
| sessions | detect | resolve_session | tick_topology | tick_with_captures |
|---|---|---|---|---|
| 1  | 242.8 | 205.6 | 197.5 | 208.2 |
| 10 | 281.8 | 200.6 | 210.2 | 227.6 |
| 24 | 367.3 | 211.3 | 210.3 | 243.3 |

## What the data says

1. **Every phase costs about one round trip.** Each gains ~85ms at 30ms and
   ~200ms at 80ms, uniformly. Cold start is `detect` → `resolveSession` →
   topology tick → capture tick = **4 sequential execs**. At 80ms RTT that is
   ~890ms before the last tile can paint, and ~640ms of it is pure latency.

2. **Payload is a non-issue at any plausible scale.** 24 sessions is 191KB
   against a 512KB `responseCap`; `would_exceed_cap` is False for every row in
   the sweep. Truncation never fires, so the `fetchCap` halve-fast/double-slow
   ramp is dead code in practice. The originally-suspected dominant cost is
   not a cost at all.

3. **The serial `zmx history` loop is cheap.** At 10 sessions, captures add
   only ~9ms over topology-only at 0ms latency (19.5 vs 10.6). Capturing all
   sessions is not the problem.

4. **`detect`'s remote work grows with session count** but stays modest on a
   clean host: 31ms (1) → 80ms (10) → 165ms (24) at 0ms latency. Real, but
   second-order next to round trips.

**Therefore the target is round-trip count in the cold-start path, not payload,
not capture concurrency, not the fetchCap ramp.**

## Two invalid runs, and why (kept as a warning)

**v1 baseline (`bench/results/baseline/`) — discarded entirely.**
- *Latency columns:* the delay proxy slept inline in its read loop
  (`read → sleep → write → read`), charging N chunks × delay instead of a
  constant delay. Phases that dribble output out over time were penalised far
  more than phases returning the same bytes in one burst — `detect` gained
  +780ms at "30ms" where a capture tick of the same size gained +107ms. Fixed
  in `bench/netem/delay_proxy.py`; chunks now carry an arrival deadline and are
  held concurrently while reading continues.
- *All columns:* the fixture had accumulated **290 zombie `[zmx] <defunct>`
  processes**. PID 1 was `sleep infinity`, which never `wait()`s. `detect()`
  matches candidates with `grep -E "tmux|herdr|zellij|zmx"` and a zombie still
  carries the name, so every corpse became a candidate that `_walk`, `lsof`,
  and `/proc/net/unix` scans then ran against. This took `detect` from ~31ms to
  ~3.8s. Because zombies accumulated *during* the sweep, the growth looked
  exactly like "detect scales with session count" — it does not.
  The zombies were owned by the fixture account, so a root
  `podman exec ps -x` showed 5 processes while `ps -eo` showed 705.
- Fixed in `Tests/ZmxFixture/zmx-fixture.sh` (`--init`, so PID 1 reaps) and
  guarded in `bench/run_bench.py` (`check_fixture_clean`, refuses to run above
  20 zombies).

## Separate finding, not part of this work

`detect()` counting defunct processes as live multiplexer candidates is a real
robustness bug in rootshell, independent of the fixture. Any host that does not
reap — containers being the common case — degrades it badly (~31ms → ~3.8s at
290 zombies). Cheap to fix (exclude `<defunct>` from the candidate grep) but it
needs its own before/after measurement.
