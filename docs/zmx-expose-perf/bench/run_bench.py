#!/usr/bin/env python3
"""zmx exposé perf bench -- main sweep driver.

Measures the REAL wall-clock cost of the zmx exposé's remote scripts
(detect, resolveSession, and the tick -- topology-only and with captures)
over a REAL SSH connection to the zmx fixture, across a sweep of session
counts and injected latencies. See README.md for the full picture; this
docstring covers only what a reader needs to modify the driver itself.

Design choices worth knowing before you change this file:

- One SSH ControlMaster per latency level, reused for every session count
  and every rep at that latency. This mirrors the real app: RemoteExecProbe
  runs every probe/tick over the pane's ALREADY-OPEN Citadel connection, a
  new exec channel each time, never a fresh TCP+SSH handshake per tick. A
  driver that reconnected per rep would be measuring handshake cost, not
  tick cost.

- Scripts come from lib/mux_scripts.py, a transcription (not import) of the
  Swift script-builders -- see that file's docstring and check-sync.sh for
  why, and how drift is caught.

- Session content is seeded through zmx's own `.Output` IPC tag (`zmx
  print <name>`, fed via stdin) rather than typed through a shell, so
  seeding is fast and produces exact, reproducible bytes. It must be sent
  in chunks under ~4KB per call: feeding a single `zmx print` more than
  ~4089 bytes in one message was found, empirically, to silently fail
  (the session ends up back at a bare prompt, `zmx print` still exits 0) --
  reproduced with no SSH in the loop at all (via `podman exec`), so it is
  a zmx v0.8.1 behavior, not a transport artifact. Not investigated
  further or patched (zmx is pinned read-only for this task); worked
  around here by chunking. See README.md "Surprises".
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

BENCH_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCH_DIR / "lib"))
import gen_content  # noqa: E402
import mux_scripts  # noqa: E402

# ---------------------------------------------------------------------------
# Constants mirrored from MultiplexerExposeFeed.swift / RemoteExecProbe.swift
# (documentation only below this point -- not used to alter behavior, since
# this harness measures real, untruncated wall time and byte counts and
# reports how they compare to these caps rather than emulating the caps).
# ---------------------------------------------------------------------------
RESPONSE_CAP_TICK = 512 * 1024          # MultiplexerExposeFeed.swift:64
RESPONSE_CAP_DETECT = 64 * 1024         # MultiplexerExposeFeed.swift:690
RESPONSE_CAP_RESOLVE = 16 * 1024        # MultiplexerExposeFeed.swift:957
TICK_TIMEOUT_S = 5                      # MultiplexerExposeFeed.swift:65

# Chunk size for seeding: comfortably under the ~4089-4090 byte cliff found
# empirically (see module docstring).
SEED_CHUNK_BYTES = 3000

DEFAULT_SESSIONS = [1, 3, 5, 8, 10, 16, 24]
DEFAULT_LATENCIES_MS = [0, 30, 80]
DEFAULT_REPS = 5
DEFAULT_SEED_LINES = 200


# ---------------------------------------------------------------------------
# Fixture env
# ---------------------------------------------------------------------------

@dataclass
class FixtureEnv:
    state_dir: str
    container_id: str
    host: str
    port: int
    username: str
    prefix: str
    key: str
    known_hosts: str
    revision: str


def load_fixture_env(env_file: Path) -> FixtureEnv:
    values: dict[str, str] = {}
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        values[k] = v
    state_dir = values.get("ZMX_FIXTURE_STATE_DIR", "")
    known_hosts = str(Path(state_dir) / "known_hosts") if state_dir else values.get("ZMX_FIXTURE_KNOWN_HOSTS", "")
    return FixtureEnv(
        state_dir=state_dir,
        container_id=values["ZMX_FIXTURE_CONTAINER_ID"],
        host=values["ZMX_FIXTURE_HOST"],
        port=int(values["ZMX_FIXTURE_PORT"]),
        username=values["ZMX_FIXTURE_USERNAME"],
        prefix=values["ZMX_FIXTURE_SESSION_PREFIX"],
        key=values["ZMX_FIXTURE_PRIVATE_KEY"],
        known_hosts=known_hosts,
        revision=values.get("ZMX_FIXTURE_ZMX_REVISION", "unknown"),
    )


# ---------------------------------------------------------------------------
# SSH: one ControlMaster per latency level, exec channels reused over it.
# ---------------------------------------------------------------------------

class SSHTarget:
    """A live SSH ControlMaster to `host:port`, closed on context exit."""

    def __init__(self, fixture: FixtureEnv, host: str, port: int, work_dir: Path, label: str):
        self.fixture = fixture
        self.host = host
        self.port = port
        self.ctrl_path = str(work_dir / f"ctrl-{label}.sock")
        self._started = False

    def _base_opts(self) -> list[str]:
        return [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", f"UserKnownHostsFile={self.fixture.known_hosts}",
        ]

    def __enter__(self) -> "SSHTarget":
        cmd = [
            "ssh", *self._base_opts(),
            "-i", self.fixture.key,
            "-p", str(self.port),
            "-M", "-N", "-f",
            "-S", self.ctrl_path,
            f"{self.fixture.username}@{self.host}",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            raise RuntimeError(f"ControlMaster failed to start: {result.stderr.strip()}")
        self._started = True
        return self

    def __exit__(self, *exc) -> None:
        if not self._started:
            return
        subprocess.run(
            ["ssh", "-S", self.ctrl_path, "-O", "exit", f"{self.fixture.username}@{self.host}"],
            capture_output=True, timeout=10,
        )

    def exec(self, command: str, input_bytes: Optional[bytes] = None, timeout: float = 30.0) -> tuple[int, bytes, bytes, float]:
        """Runs `command` as a single SSH exec-channel request over the
        shared master connection, exactly as RemoteExecProbe hands a whole
        assembled script string to Citadel's client.executeCommand.
        Returns (returncode, stdout, stderr, wall_seconds)."""
        cmd = ["ssh", "-o", "BatchMode=yes", "-S", self.ctrl_path, f"{self.fixture.username}@{self.host}", command]
        t0 = time.perf_counter()
        try:
            result = subprocess.run(cmd, input=input_bytes, capture_output=True, timeout=timeout)
            wall = time.perf_counter() - t0
            return result.returncode, result.stdout, result.stderr, wall
        except subprocess.TimeoutExpired as exc:
            wall = time.perf_counter() - t0
            return -1, exc.stdout or b"", (exc.stderr or b""), wall


# ---------------------------------------------------------------------------
# Latency injection
# ---------------------------------------------------------------------------

@dataclass
class LatencyChannel:
    """Where to point SSH for one latency level, plus how that latency was
    verified (not just assumed from the CLI argument used to configure it)."""
    target_ms: int
    host: str
    port: int
    via: str  # "direct" | "proxy" | "netem"
    proxy_proc: Optional[subprocess.Popen] = None
    measured: Optional[dict] = None


def measure_one_way_ms(host: str, port: int, reps: int = 7) -> dict:
    proc = subprocess.run(
        [sys.executable, str(BENCH_DIR / "netem" / "measure_rtt.py"), "--host", host, "--port", str(port), "--reps", str(reps)],
        capture_output=True, text=True, timeout=30,
    )
    try:
        return json.loads(proc.stdout.strip())
    except (ValueError, IndexError):
        return {"error": proc.stdout + proc.stderr}


def open_latency_channel(fixture: FixtureEnv, target_ms: int, work_dir: Path, netem_checked: dict) -> LatencyChannel:
    if target_ms == 0:
        measured = measure_one_way_ms(fixture.host, fixture.port)
        return LatencyChannel(target_ms=0, host=fixture.host, port=fixture.port, via="direct", measured=measured)

    if "available" not in netem_checked:
        probe = subprocess.run(
            ["sh", str(BENCH_DIR / "netem" / "try_netem.sh"), fixture.container_id, "5"],
            capture_output=True, text=True, timeout=20,
        )
        netem_checked["available"] = probe.returncode == 0
        netem_checked["message"] = (probe.stderr or probe.stdout).strip()
        if netem_checked["available"]:
            subprocess.run(["podman", "exec", fixture.container_id, "tc", "qdisc", "del", "dev", "eth0", "root"],
                            capture_output=True)
        print(netem_checked["message"], file=sys.stderr)

    if netem_checked["available"]:
        add = subprocess.run(
            ["podman", "exec", fixture.container_id, "tc", "qdisc", "add", "dev", "eth0", "root", "netem",
             "delay", f"{target_ms // 2}ms"],
            capture_output=True, text=True,
        )
        if add.returncode == 0:
            measured = measure_one_way_ms(fixture.host, fixture.port)
            return LatencyChannel(target_ms=target_ms, host=fixture.host, port=fixture.port, via="netem", measured=measured)
        print(f"try_netem: qdisc add failed at runtime ({add.stderr.strip()}); falling back to proxy", file=sys.stderr)

    # Fallback: host-side delay proxy. delay-ms is applied per direction,
    # so target_ms/2 per hop makes a round trip gain ~target_ms.
    listen_port = _free_port()
    ready_file = work_dir / f"proxy-ready-{target_ms}"
    proc = subprocess.Popen(
        [sys.executable, str(BENCH_DIR / "netem" / "delay_proxy.py"),
         "--listen-port", str(listen_port), "--upstream-port", str(fixture.port),
         "--delay-ms", str(target_ms / 2), "--ready-file", str(ready_file)],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
    )
    for _ in range(50):
        if ready_file.exists():
            break
        time.sleep(0.1)
    else:
        proc.kill()
        raise RuntimeError(f"delay proxy for {target_ms}ms did not become ready")

    direct = measure_one_way_ms(fixture.host, fixture.port)
    via_proxy = measure_one_way_ms("127.0.0.1", listen_port)
    delta_ms = None
    if "median_ms" in direct and "median_ms" in via_proxy:
        delta_ms = round(via_proxy["median_ms"] - direct["median_ms"], 3)
    measured = {
        "direct_one_hop_ms": direct.get("median_ms"),
        "via_proxy_one_hop_ms": via_proxy.get("median_ms"),
        "verified_added_one_hop_ms": delta_ms,
        "implied_added_rtt_ms": (delta_ms * 2) if delta_ms is not None else None,
        "configured_delay_ms_per_hop": target_ms / 2,
    }
    return LatencyChannel(target_ms=target_ms, host="127.0.0.1", port=listen_port, via="proxy",
                           proxy_proc=proc, measured=measured)


def close_latency_channel(channel: LatencyChannel, fixture: FixtureEnv) -> None:
    if channel.via == "netem":
        subprocess.run(["podman", "exec", fixture.container_id, "tc", "qdisc", "del", "dev", "eth0", "root"],
                        capture_output=True)
    if channel.proxy_proc is not None:
        channel.proxy_proc.terminate()
        try:
            channel.proxy_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            channel.proxy_proc.kill()


def _free_port() -> int:
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# Session seeding
# ---------------------------------------------------------------------------

def session_name(fixture: FixtureEnv, index: int) -> str:
    return f"{fixture.prefix}-bench{index:02d}"


def kill_bench_sessions(ssh: SSHTarget, fixture: FixtureEnv) -> None:
    rc, out, _err, _wall = ssh.exec("ZMX_SESSION_PREFIX= zmx list --short", timeout=15)
    if rc != 0:
        return
    names = [n.strip() for n in out.decode("utf-8", "replace").splitlines() if n.strip()]
    targets = [n for n in names if n.startswith(f"{fixture.prefix}-bench")]
    if targets:
        ssh.exec("ZMX_SESSION_PREFIX= zmx kill --force " + " ".join(targets), timeout=20)


def seed_sessions(ssh: SSHTarget, fixture: FixtureEnv, count: int, seed_lines: int) -> dict[str, int]:
    """Creates `count` fresh sessions and seeds each with realistic ANSI
    content. Returns {session_name: last-80-lines capture byte size}."""
    names = [session_name(fixture, i) for i in range(count)]
    for name in names:
        rc, _out, err, _wall = ssh.exec(f"ZMX_SESSION_PREFIX= zmx run {name} -d /bin/bash", timeout=15)
        if rc != 0:
            raise RuntimeError(f"failed to create session {name}: {err.decode('utf-8', 'replace')}")

    for i, name in enumerate(names):
        content = gen_content.generate(__import__("random").Random(f"{name}-seed-v1"), seed_lines, 20, 140).encode("utf-8")
        for start in range(0, len(content), SEED_CHUNK_BYTES):
            chunk = content[start:start + SEED_CHUNK_BYTES]
            rc, _out, err, _wall = ssh.exec(f"ZMX_SESSION_PREFIX= zmx print {name}", input_bytes=chunk, timeout=15)
            if rc != 0:
                raise RuntimeError(f"failed to seed {name}: {err.decode('utf-8', 'replace')}")

    capture_bytes: dict[str, int] = {}
    for name in names:
        rc, out, _err, _wall = ssh.exec(f"ZMX_SESSION_PREFIX= zmx history {name} --vt | tail -n {mux_scripts.ZMX_CAPTURE_ROWS}", timeout=15)
        capture_bytes[name] = len(out) if rc == 0 else -1
    return capture_bytes


# ---------------------------------------------------------------------------
# Phase measurement
# ---------------------------------------------------------------------------

@dataclass
class PhaseResult:
    wall_ms: list[float] = field(default_factory=list)
    reply_bytes: list[int] = field(default_factory=list)
    rc: list[int] = field(default_factory=list)
    response_cap: int = 0

    def summarize(self) -> dict:
        return {
            "reps": len(self.wall_ms),
            "median_ms": round(statistics.median(self.wall_ms), 2) if self.wall_ms else None,
            "min_ms": round(min(self.wall_ms), 2) if self.wall_ms else None,
            "max_ms": round(max(self.wall_ms), 2) if self.wall_ms else None,
            "median_reply_bytes": round(statistics.median(self.reply_bytes)) if self.reply_bytes else None,
            "max_reply_bytes": max(self.reply_bytes) if self.reply_bytes else None,
            "would_exceed_response_cap": any(b > self.response_cap for b in self.reply_bytes) if self.response_cap else False,
            "exceeded_tick_timeout": any(w > TICK_TIMEOUT_S * 1000 for w in self.wall_ms),
            "nonzero_exit": any(c != 0 for c in self.rc),
        }


def run_phase(ssh: SSHTarget, build_script, reps: int, response_cap: int) -> PhaseResult:
    result = PhaseResult(response_cap=response_cap)
    for _ in range(reps):
        script = build_script()
        rc, out, _err, wall = ssh.exec(script, timeout=max(30.0, TICK_TIMEOUT_S * 3))
        result.wall_ms.append(wall * 1000.0)
        result.reply_bytes.append(len(out))
        result.rc.append(rc)
    return result


# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------

def check_fixture_clean(fixture, *, limit: int = 20) -> int:
    """Counts zombie processes in the fixture container.

    This exists because a polluted fixture silently corrupts every number this
    harness produces. The fixture's PID 1 used to be `sleep infinity`, which
    never wait()s, so each torn-down zmx session left a `[zmx] <defunct>`
    zombie. rootshell's detect() probe matches candidates with
    `ps ... | grep -E "tmux|herdr|zellij|zmx"`, and a zombie still carries the
    name -- so every corpse became a candidate that detect() then ran `_walk`,
    `lsof`, and `/proc/net/unix` scans against. ~290 accumulated zombies took
    detect() from sub-second to ~3.8s, and because they build up DURING a
    sweep, they masquerade as "detect scales with session count".

    Note the zombies belong to the fixture account, so a root
    `podman exec ... ps -x` shows nothing. `ps -eo` is required to see them.
    """
    proc = subprocess.run(
        ["podman", "exec", fixture.container_id, "sh", "-c",
         "ps -eo stat=,args= | grep -c 'defunct'"],
        capture_output=True, text=True,
    )
    try:
        zombies = int((proc.stdout or "0").strip())
    except ValueError:
        zombies = 0
    if zombies > limit:
        raise SystemExit(
            f"run_bench: fixture has {zombies} zombie processes (limit {limit}).\n"
            f"  Numbers from this fixture would be meaningless -- detect() counts\n"
            f"  each zombie as a live multiplexer candidate.\n"
            f"  Restart it:  Tests/ZmxFixture/zmx-fixture.sh stop {fixture.state_dir}\n"
            f"               Tests/ZmxFixture/zmx-fixture.sh start --env-file ...\n"
            f"  The fixture now runs the container with --init so PID 1 reaps;\n"
            f"  a container started before that change will keep leaking."
        )
    return zombies


def run_sweep(args: argparse.Namespace) -> dict:
    fixture = load_fixture_env(Path(args.env_file))
    zombies_before = check_fixture_clean(fixture)
    work_dir = Path(tempfile.mkdtemp(prefix="zmxb-"))
    netem_checked: dict = {}
    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "zmx_revision": fixture.revision,
        "fixture_state_dir": fixture.state_dir,
        "seed_lines": args.seed_lines,
        "reps": args.reps,
        "sessions_sweep": args.sessions,
        "zombies_before": zombies_before,
        "latencies_ms": args.latencies,
        "configs": [],
    }

    try:
        for target_ms in args.latencies:
            print(f"== latency {target_ms}ms ==", file=sys.stderr)
            channel = open_latency_channel(fixture, target_ms, work_dir, netem_checked)
            print(f"   via={channel.via} measured={channel.measured}", file=sys.stderr)
            try:
                with SSHTarget(fixture, channel.host, channel.port, work_dir, label=f"L{target_ms}") as ssh:
                    kill_bench_sessions(ssh, fixture)
                    for count in args.sessions:
                        print(f"   -- sessions={count}", file=sys.stderr)
                        kill_bench_sessions(ssh, fixture)
                        capture_bytes = seed_sessions(ssh, fixture, count, args.seed_lines)
                        names = list(capture_bytes.keys())

                        detect_res = run_phase(ssh, lambda: mux_scripts.detect_script(mux_scripts.nonce()),
                                                args.reps, RESPONSE_CAP_DETECT)
                        resolve_res = run_phase(ssh, lambda: mux_scripts.resolve_session_script(mux_scripts.nonce()),
                                                 args.reps, RESPONSE_CAP_RESOLVE)
                        topo_res = run_phase(ssh, lambda: mux_scripts.tick_script([], mux_scripts.nonce()),
                                              args.reps, RESPONSE_CAP_TICK)
                        capture_res = run_phase(ssh, lambda: mux_scripts.tick_script(names, mux_scripts.nonce()),
                                                 args.reps, RESPONSE_CAP_TICK)
                        # perf/zmx-expose-coldstart: what the reopen-a-cached
                        # -zmx-binding cold start now sends as its FIRST (and,
                        # at 1 session, only) tick -- `zmx list` plus a
                        # capture for just the one session already known from
                        # the cached binding (MuxZmxBootstrap.seededFetch in
                        # MultiplexerExposeAdapter.swift), rather than a
                        # topology-only tick. Fixed at one fetched name
                        # regardless of `count` -- that fixedness IS the
                        # point being measured (it no longer scales with
                        # session count the way `tick_with_captures` does).
                        bootstrap_res = run_phase(
                            ssh, lambda: mux_scripts.tick_script(names[:1], mux_scripts.nonce()),
                            args.reps, RESPONSE_CAP_TICK
                        )

                        report["configs"].append({
                            "latency_target_ms": target_ms,
                            "latency_via": channel.via,
                            "latency_measured": channel.measured,
                            "sessions": count,
                            "capture_bytes_per_session": capture_bytes,
                            "phases": {
                                "detect": detect_res.summarize(),
                                "resolve_session": resolve_res.summarize(),
                                "tick_topology_only": topo_res.summarize(),
                                "tick_with_captures": capture_res.summarize(),
                                "tick_bootstrap_seed": bootstrap_res.summarize(),
                            },
                        })
                        kill_bench_sessions(ssh, fixture)
            finally:
                close_latency_channel(channel, fixture)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    return report


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def write_outputs(report: dict, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "results.json").write_text(json.dumps(report, indent=2))

    tsv_lines = ["latency_ms\tvia\tsessions\tphase\treps\tmedian_ms\tmin_ms\tmax_ms\tmedian_reply_bytes\tmax_reply_bytes\twould_exceed_cap\texceeded_tick_timeout"]
    for cfg in report["configs"]:
        for phase_name, phase in cfg["phases"].items():
            tsv_lines.append("\t".join(str(x) for x in [
                cfg["latency_target_ms"], cfg["latency_via"], cfg["sessions"], phase_name,
                phase["reps"], phase["median_ms"], phase["min_ms"], phase["max_ms"],
                phase["median_reply_bytes"], phase["max_reply_bytes"],
                phase["would_exceed_response_cap"], phase["exceeded_tick_timeout"],
            ]))
    (out_dir / "results.tsv").write_text("\n".join(tsv_lines) + "\n")

    summary_lines = [f"zmx exposé perf bench -- {report['generated_at']}", f"zmx revision: {report['zmx_revision']}", ""]
    for cfg in report["configs"]:
        cap_bytes = list(cfg["capture_bytes_per_session"].values())
        cap_med = statistics.median(cap_bytes) if cap_bytes else 0
        summary_lines.append(
            f"latency={cfg['latency_target_ms']:>3}ms ({cfg['latency_via']:6}) sessions={cfg['sessions']:>2} "
            f"capture/session~{cap_med:>6.0f}B"
        )
        for phase_name, phase in cfg["phases"].items():
            flag = ""
            if phase["would_exceed_response_cap"]:
                flag += " [EXCEEDS 512KB CAP]"
            if phase["exceeded_tick_timeout"]:
                flag += " [EXCEEDS 5s TIMEOUT]"
            summary_lines.append(
                f"    {phase_name:20} median={phase['median_ms']:>8.1f}ms  "
                f"min={phase['min_ms']:>8.1f}ms  max={phase['max_ms']:>8.1f}ms  "
                f"bytes~{phase['median_reply_bytes']}{flag}"
            )
        summary_lines.append("")
    (out_dir / "summary.txt").write_text("\n".join(summary_lines))
    print("\n".join(summary_lines))
    print(f"\nWrote {out_dir / 'results.json'}, results.tsv, summary.txt", file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_int_list(s: str) -> list[int]:
    return [int(x) for x in s.split(",") if x.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", required=True, help="zmx-fixture.sh env file (ZMX_FIXTURE_* vars)")
    parser.add_argument("--sessions", default=",".join(map(str, DEFAULT_SESSIONS)), help="comma-separated session counts")
    parser.add_argument("--latencies", default=",".join(map(str, DEFAULT_LATENCIES_MS)), help="comma-separated target added-RTT ms")
    parser.add_argument("--reps", type=int, default=DEFAULT_REPS)
    parser.add_argument("--seed-lines", type=int, default=DEFAULT_SEED_LINES)
    parser.add_argument("--out-dir", default=None)
    parser.add_argument("--skip-sync-check", action="store_true")
    parser.add_argument("--quick", action="store_true", help="tiny smoke-test sweep: sessions=1,3 latencies=0 reps=2")
    args = parser.parse_args()

    if args.quick:
        args.sessions = "1,3"
        args.latencies = "0"
        args.reps = 2

    args.sessions = parse_int_list(args.sessions)
    args.latencies = parse_int_list(args.latencies)

    if not args.skip_sync_check and not os.environ.get("ZMX_BENCH_SKIP_SYNC_CHECK"):
        rc = subprocess.run(["sh", str(BENCH_DIR / "check-sync.sh"), "--quiet"]).returncode
        if rc != 0:
            print("run_bench: aborting -- check-sync.sh failed (see above); "
                  "override with --skip-sync-check or ZMX_BENCH_SKIP_SYNC_CHECK=1", file=sys.stderr)
            return 1

    out_dir = Path(args.out_dir) if args.out_dir else BENCH_DIR / "results" / time.strftime("%Y%m%d-%H%M%S")
    report = run_sweep(args)
    write_outputs(report, out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
