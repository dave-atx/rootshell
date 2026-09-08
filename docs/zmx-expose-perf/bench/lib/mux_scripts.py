#!/usr/bin/env python3
"""Byte-faithful transcription of the zmx exposé remote scripts.

This does NOT import rootshell's Swift source (there is no headless way to
do that without Xcode). Instead every function below is a line-by-line
transcription of one Swift function, with a comment naming the exact source
range it mirrors. `../check-sync.sh` hashes those same ranges against
`../sync-manifest.txt` and fails loudly if the source has moved since this
file was last verified against it -- run it before trusting any benchmark
number.

Sources transcribed (see sync-manifest.txt for the pinned line ranges):
  - rootshell/Features/Multiplexer/Expose/ZmxExposeAdapter.swift
      minInterval, prefix, captureRows, resolveSessionScript, tickScript
  - rootshell/Features/Multiplexer/Expose/MultiplexerExposeAdapter.swift
      MuxScript.{begin,end,topology,panePrefix,wrap,dq,paneMarker}
  - rootshell/Core/Shell/LoginShellCommand.swift
      pathPrefix, singleQuoted, doubleQuoted, runInPOSIXShell
  - rootshell/Features/Multiplexer/Expose/MultiplexerExposeFeed.swift
      detect() (the probe script only -- its Swift-side response parsing
      is not reproduced, since this harness only measures wall time and
      byte counts, not binding resolution), resolveSession(), nonce()
  - rootshell/Features/Multiplexer/Expose/TmuxExposeAdapter.swift
      separator (used inside detect()'s tmux list-clients call)
  - rootshell/Core/Terminal/TerminalIdentity.swift
      paneTokenVariable (used inside detect()'s env grep)

Every script this module builds is meant to be handed to `ssh user@host
"<script>"` as a single argument, exactly like RemoteExecProbe.run does
through Citadel's client.executeCommand (a single SSH exec-channel request
carrying the whole command string) -- see RemoteExecProbe.swift.
"""

from __future__ import annotations

import random


# ---------------------------------------------------------------------------
# LoginShellCommand.swift -- PATH prefix, shell quoting, POSIX wrapper.
# (see ../sync-manifest.txt for the exact pinned line range)
# ---------------------------------------------------------------------------

# Transcribed from LoginShellCommand.pathPrefix (LoginShellCommand.swift
# :29-39). This is a *value*, not logic with inputs, so it is reproduced
# here as the literal shell text that closure builds -- deterministically,
# it never depends on anything but the fixed entry lists below.
_TOOL_PATH_ENTRIES = ["/opt/homebrew/bin", "/usr/local/bin", "$HOME/go/bin", "/usr/local/go/bin"]
_LINUX_PATH_ENTRIES = ["/home/linuxbrew/.linuxbrew/bin", "/snap/bin"]
_SYSTEM_PATH_ENTRIES = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]


def _path_words(entries: list[str]) -> str:
    return " ".join(f'"{e}"' if "$" in e else e for e in entries)


PATH_PREFIX = (
    '_rsp=; _rsl=; [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ] || _rsl="'
    + " ".join(_LINUX_PATH_ENTRIES)
    + '"; for _rsd in '
    + _path_words(_TOOL_PATH_ENTRIES)
    + " $_rsl "
    + _path_words(_SYSTEM_PATH_ENTRIES)
    + '; do [ -d "$_rsd" ] && _rsp="$_rsp$_rsd:"; done; export PATH="$_rsp$PATH"; '
)


def single_quoted(value: str) -> str:
    """LoginShellCommand.swift:42-52 `singleQuoted`."""
    out = ["'"]
    for ch in value:
        if ch == "'":
            out.append("'\"'\"'")
        elif ch == "\\":
            out.append("'\"\\\\\"'")
        else:
            out.append(ch)
    out.append("'")
    return "".join(out)


def double_quoted(value: str) -> str:
    """LoginShellCommand.swift:55-65 `doubleQuoted`."""
    out = ['"']
    for ch in value:
        if ch in ('"', "\\", "$", "`"):
            out.append("\\" + ch)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def run_in_posix_shell(script: str, login: bool = False) -> str:
    """LoginShellCommand.swift:68-71 `runInPOSIXShell`."""
    return f"sh {'-lc' if login else '-c'} {single_quoted(script)}"


# ---------------------------------------------------------------------------
# MultiplexerExposeAdapter.swift -- MuxScript marker framing.
# (see ../sync-manifest.txt for the exact pinned line range)
# ---------------------------------------------------------------------------

UNSUPPORTED_MARKER = "::MX_UNSUPPORTED::"


def mx_begin(nonce: str) -> str:
    return f"::MX_B_{nonce}::"


def mx_end(nonce: str) -> str:
    return f"::MX_E_{nonce}::"


def mx_topology(nonce: str) -> str:
    return f"::MX_T_{nonce}::"


def mx_pane_prefix(nonce: str) -> str:
    return f"::MX_P_{nonce}:"


def mux_wrap(body: str, nonce: str) -> str:
    """MuxScript.wrap -- also folds in SSHConfig.remoteExecPathPrefix, which
    is just LoginShellCommand.pathPrefix (SSHConfig.swift:87)."""
    script = f'echo "{mx_begin(nonce)}"; {body}; echo "{mx_end(nonce)}"; exit 0'
    return run_in_posix_shell(PATH_PREFIX + script, login=True)


def mux_pane_marker(nonce: str, pane_id: str, extra: str = "") -> str:
    return "echo " + double_quoted(f"{mx_pane_prefix(nonce)}{pane_id}:{extra}::")


def nonce() -> str:
    """MultiplexerExposeFeed.swift `nonce()` -- random UInt64,
    base 36. Python's random module is fine here: this only needs to be an
    alphanumeric token that varies per tick, not cryptographically strong."""
    return _base36(random.randint(0, (1 << 64) - 1))


def _base36(n: int) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if n == 0:
        return "0"
    out = []
    while n:
        n, r = divmod(n, 36)
        out.append(digits[r])
    return "".join(reversed(out))


# ---------------------------------------------------------------------------
# ZmxExposeAdapter.swift -- zmx-specific scripts.
# (see ../sync-manifest.txt for the exact pinned line range)
# ---------------------------------------------------------------------------

ZMX_MIN_INTERVAL_S = 1.5          # ZmxExposeAdapter.swift:12
ZMX_CAPTURE_ROWS = 80             # ZmxExposeAdapter.swift:19
_ZMX_PREFIX = "ZMX_SESSION_PREFIX= "  # ZmxExposeAdapter.swift:16


def resolve_session_script(nonce_value: str) -> str:
    """ZmxExposeAdapter.swift:23-30 `resolveSessionScript`."""
    body = "echo " + double_quoted(mx_topology(nonce_value)) + f"; {_ZMX_PREFIX}zmx list --short 2>/dev/null"
    return mux_wrap(body, nonce_value)


def tick_script(fetch: list[str], nonce_value: str) -> str:
    """ZmxExposeAdapter.swift:32-47 `tickScript`. `session` (the currently
    active tab, used only for `isActive` bookkeeping client-side) never
    appears in the script text, so it is not a parameter here."""
    body = "command -v zmx >/dev/null 2>&1 || echo " + double_quoted(UNSUPPORTED_MARKER)
    body += '; _zt=""; command -v timeout >/dev/null 2>&1 && _zt="timeout 2"'
    body += "; echo " + double_quoted(mx_topology(nonce_value))
    body += '; echo "::SESSIONS::"'
    body += f"; {_ZMX_PREFIX}" + '${_zt:+timeout 5} zmx list 2>/dev/null'
    for name in fetch:
        body += "; " + mux_pane_marker(nonce_value, name)
        body += f"; {_ZMX_PREFIX}" + "$_zt zmx history " + double_quoted(name) + " --vt 2>/dev/null"
        body += f" | tail -n {ZMX_CAPTURE_ROWS}"
        body += "; echo"
    return mux_wrap(body, nonce_value)


# ---------------------------------------------------------------------------
# MultiplexerExposeFeed.swift -- detect(), probe script only.
# (see ../sync-manifest.txt for the exact pinned line range -- this function
# has moved more than once already, under concurrent instrumentation work
# on the same branch; check-sync.sh is what actually guards freshness, not
# any line number written here)
# ---------------------------------------------------------------------------

_TMUX_CLIENT_SEPARATOR = "<|>"          # TmuxExposeAdapter.swift:18
_PANE_TOKEN_VARIABLE = "LC_ROOTSHELL_PANE"  # TerminalIdentity.swift:49


def detect_script(nonce_value: str, tty: str | None = None) -> str:
    """MultiplexerExposeFeed.swift `detect()`, script-building portion
    only; the surrounding Swift also parses the
    reply and walks candidate PIDs client-side, which this harness has no
    use for -- it only needs the exact bytes sent over the wire and the
    exact bytes that come back.

    `tty` mirrors `Self.localTTY(terminal)`: for every SSH-backed pane (the
    only case the zmx exposé runs against) that is always nil, so this
    benchmark always takes the `tty == nil` branch -- the same branch real
    usage takes.
    """
    if tty:
        candidates = f"ps -t {double_quoted(tty)} -o pid=,ppid=,tty=,args= 2>/dev/null"
    else:
        candidates = 'ps -xo pid=,ppid=,tty=,args= 2>/dev/null | grep -E "tmux|herdr|zellij|zmx" | grep -v grep'
    candidate_pids = '$(' + candidates + ' | awk "{print \\$1}")'
    walk = (
        '_q=$1; while [ -n "$_q" ] && [ "$_q" -gt 1 ] 2>/dev/null;'
        ' do echo "$_q"; _q=$(ps -o ppid= -p "$_q" 2>/dev/null | tr -d " "); done'
    )

    body = f"_walk() {{ {walk}; }}"
    body += "; echo " + double_quoted(mx_topology(nonce_value))
    body += f"; {candidates}"
    body += '; echo "::MX_SELF::"; _walk $$'
    body += '; echo "::MX_CONNECTION::"; printf "%s\\n" "${SSH_CONNECTION-}"'
    body += f'; echo "::MX_CHAINS::"; for _p in {candidate_pids}; do echo "::MX_PID:$_p::"; _walk "$_p"; done'
    body += '; echo "::MX_CLIENTS::"'
    body += f'; tmux list-clients -F "#{{client_tty}}{_TMUX_CLIENT_SEPARATOR}#{{session_name}}" 2>/dev/null'
    body += f'; echo "::MX_SOCKETS::"; for _p in {candidate_pids}; do echo "::MX_PID:$_p::";'
    body += ' for _s in "$_p" $(ps -xo pid=,ppid= 2>/dev/null | awk -v p="$_p" "\\$2==p {print \\$1}"); do'
    body += ' lsof -a -p "$_s" -U -F n 2>/dev/null;'
    body += ' if [ -d "/proc/$_s/fd" ]; then'
    body += ' for _i in $(ls -l "/proc/$_s/fd" 2>/dev/null'
    body += ' | sed -n "s/.*socket:\\[\\([0-9][0-9]*\\)\\].*/\\1/p"); do'
    body += ' awk -v i="$_i" "\\$7==i && \\$8 ~ /^\\// {print \\$8}" /proc/net/unix 2>/dev/null;'
    body += ' done; fi; done; done'
    body += f'; echo "::MX_ENV::"; for _p in {candidate_pids}; do echo "::MX_PID:$_p::";'
    body += ' [ -r "/proc/$_p/environ" ] && tr "\\0" "\\n" < "/proc/$_p/environ" 2>/dev/null'
    body += (
        ' | grep -E "^(HERDR_SESSION|HERDR_SOCKET_PATH|ZELLIJ_SESSION_NAME|SSH_CONNECTION|'
        f'{_PANE_TOKEN_VARIABLE})="; done'
    )
    body += '; echo "::MX_SERVERS::"; ps -xo pid=,ppid=,args= 2>/dev/null | grep -- "--server" | grep -v grep'

    return mux_wrap(body, nonce_value)


# ---------------------------------------------------------------------------
# CLI: print one script to stdout, for shell callers.
# ---------------------------------------------------------------------------

def _main() -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="which", required=True)

    p_tick = sub.add_parser("tick", help="tickScript")
    p_tick.add_argument("--nonce", default=None)
    p_tick.add_argument("--fetch", default="", help="comma-separated session names")

    p_resolve = sub.add_parser("resolve-session", help="resolveSessionScript")
    p_resolve.add_argument("--nonce", default=None)

    p_detect = sub.add_parser("detect", help="detect() probe script")
    p_detect.add_argument("--nonce", default=None)

    p_nonce = sub.add_parser("nonce", help="print a fresh nonce")

    args = parser.parse_args()

    if args.which == "nonce":
        print(nonce())
        return 0

    n = args.nonce or nonce()
    if args.which == "tick":
        fetch = [s for s in args.fetch.split(",") if s]
        print(tick_script(fetch, n))
    elif args.which == "resolve-session":
        print(resolve_session_script(n))
    elif args.which == "detect":
        print(detect_script(n))
    else:
        parser.error(f"unknown subcommand: {args.which}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
