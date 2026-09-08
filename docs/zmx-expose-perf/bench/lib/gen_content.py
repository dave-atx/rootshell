#!/usr/bin/env python3
"""Generates realistic, colour-rich terminal scrollback for seeding zmx
fixture sessions.

Why this exists: `zmx history <name> --vt | tail -n 80` is the expensive
half of every tick, and an empty `/bin/bash` session captures to almost
nothing -- a few dozen bytes of prompt. That would make every capture
measurement in the bench look artificially cheap and invalidate the whole
exercise (see the task brief: "empty shells would invalidate the whole
benchmark"). This generates several hundred lines mixing SGR colour,
bold/italic/underline, resets, and varying line lengths -- shaped like
build output / log tailing / `ls --color`, not lorem ipsum -- so the byte
size and structure `--vt` has to serialize is representative.

Output goes straight to stdout as raw bytes (real ESC sequences, not
`\\e` text) so a caller can pipe it directly into `zmx print <session>`
(zmx's Output-tag inject, which writes the caller's exact bytes into the
session's terminal state without going through a shell -- see
docs/zmx-expose-perf/bench/README.md).

Deterministic: `--seed` fixes the RNG, so the same seed always produces
byte-identical output -- needed for the harness's reproducibility promise.
"""

from __future__ import annotations

import argparse
import random
import sys

ESC = "\x1b"
RESET = f"{ESC}[0m"

# 8 standard + 8 bright foreground colours, occasionally paired with a
# background -- typical of build tool / log output (errors in red, warnings
# in yellow, paths in cyan, diff markers green/red-on-default, etc).
FG_CODES = [30, 31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97]
BG_CODES = [40, 41, 42, 43, 44, 45, 46, 47]
STYLE_CODES = [1, 3, 4]  # bold, italic, underline

WORDS = (
    "build compiling linking test PASS FAIL warning error info debug "
    "src lib main.rs util.zig loop.zig ipc.zig socket.zig cfg.zig "
    "commit abc1234 branch main origin/main HEAD detached "
    "GET POST 200 404 500 latency_ms=12 bytes=4096 conn=established "
    "session pane tab window client server socket epoll kqueue "
    "route table index scan lock unlock mutex acquired released "
    "node_modules target/debug target/release .cache /tmp/build "
    "0x1a2b3c4d checksum verified deploy staging production rollback "
    "cpu=12% mem=340MiB disk=78% io_wait=0.4 uptime=14d "
    "user@host:~/project$ npm run test -- --watch --coverage "
).split()


def _sgr(codes: list[int]) -> str:
    return f"{ESC}[{';'.join(str(c) for c in codes)}m"


def _random_line(rng: random.Random, width_lo: int, width_hi: int) -> str:
    target_len = rng.randint(width_lo, width_hi)
    out: list[str] = []
    visible = 0
    # A line has 1-4 differently-styled runs, mimicking multi-coloured
    # tool output (a log-level tag, then plain text, then a highlighted
    # token) rather than one flat SGR run per line.
    runs = rng.randint(1, 4)
    for i in range(runs):
        remaining_runs = runs - i
        run_target = max(1, (target_len - visible) // remaining_runs)
        words = []
        run_len = 0
        while run_len < run_target:
            w = rng.choice(WORDS)
            words.append(w)
            run_len += len(w) + 1
        text = " ".join(words)[:run_target] if run_len else ""
        if rng.random() < 0.75:
            codes = []
            if rng.random() < 0.6:
                codes.append(rng.choice(FG_CODES))
            if rng.random() < 0.15:
                codes.append(rng.choice(BG_CODES))
            if rng.random() < 0.35:
                codes.append(rng.choice(STYLE_CODES))
            if codes:
                out.append(_sgr(codes))
        out.append(text)
        # Reset most (not all -- real tool output routinely leaves SGR
        # state open across a line, which is exactly the case
        # ZmxExposeAdapter.parseTick's trailing `\u{1B}[0m` exists for).
        if rng.random() < 0.85:
            out.append(RESET)
        visible += len(text) + 1
    return "".join(out)


def generate(rng: random.Random, lines: int, width_lo: int, width_hi: int) -> str:
    out_lines = [_random_line(rng, width_lo, width_hi) for _ in range(lines)]
    # CRLF, not bare LF: this is injected directly into zmx's VT stream via
    # `zmx print` (the .Output IPC tag), bypassing the PTY layer that would
    # normally translate a shell's LF into CRLF. A bare LF only moves the
    # cursor down a row and leaves its column alone (true VT100 semantics),
    # which staircases every line further right instead of starting a new
    # one -- confirmed against the fixture: with LF-only joins, 600 lines
    # collapsed into a few visible cells instead of readable scrollback.
    return "\r\n".join(out_lines) + "\r\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lines", type=int, default=600)
    parser.add_argument("--width-lo", type=int, default=20)
    parser.add_argument("--width-hi", type=int, default=140)
    parser.add_argument("--seed", default="zmx-expose-bench", help="any string; hashed into the RNG seed")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    text = generate(rng, args.lines, args.width_lo, args.width_hi)
    sys.stdout.buffer.write(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
