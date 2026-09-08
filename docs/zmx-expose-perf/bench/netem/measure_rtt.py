#!/usr/bin/env python3
"""Verifies latency actually injected by delay_proxy.py (or the absence of
any injection, for the 0ms baseline).

Method: open a raw TCP connection to the target and time how long it takes
for the SSH server's version banner ("SSH-2.0-...\\r\\n") to start
arriving. sshd sends that banner unprompted as soon as it accepts the TCP
connection -- it does not wait for anything from the client -- so this
measures exactly one one-way network hop, with no SSH handshake, auth, or
crypto in the way. Run it against the fixture's real port directly (should
read close to the host's real loopback latency, a fraction of a
millisecond) and again through delay_proxy.py's listen port (should read
close to the proxy's --delay-ms) to confirm injection is real and roughly
the requested size, not just assumed from the command line that started
the proxy.

Usage: measure_rtt.py --host HOST --port PORT [--reps N]
Prints one JSON object to stdout: {host, port, reps, samples_ms, median_ms,
min_ms, max_ms}.
"""

from __future__ import annotations

import argparse
import json
import socket
import statistics
import sys
import time


def _one_sample(host: str, port: int, connect_timeout: float) -> float:
    t0 = time.perf_counter()
    with socket.create_connection((host, port), timeout=connect_timeout) as sock:
        sock.settimeout(connect_timeout)
        # First byte of the banner is enough; sshd writes the whole line
        # in one write() so this does not split a delayed chunk in two.
        sock.recv(1)
    t1 = time.perf_counter()
    return (t1 - t0) * 1000.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--reps", type=int, default=7)
    parser.add_argument("--connect-timeout", type=float, default=5.0)
    args = parser.parse_args()

    samples = []
    errors = []
    for _ in range(args.reps):
        try:
            samples.append(_one_sample(args.host, args.port, args.connect_timeout))
        except OSError as exc:
            errors.append(str(exc))

    if not samples:
        print(json.dumps({"host": args.host, "port": args.port, "reps": args.reps, "errors": errors}))
        return 1

    result = {
        "host": args.host,
        "port": args.port,
        "reps": args.reps,
        "samples_ms": [round(s, 3) for s in samples],
        "median_ms": round(statistics.median(samples), 3),
        "min_ms": round(min(samples), 3),
        "max_ms": round(max(samples), 3),
    }
    if errors:
        result["errors"] = errors
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
