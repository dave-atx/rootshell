#!/bin/sh
#
# Thin entry point for the zmx exposé perf bench. Validates the environment
# headlessly (no Xcode needed) and hands off to run_bench.py, which does
# the actual sweep. See README.md for the full picture.
#
# Usage:
#   run-bench.sh --env-file /path/to/zmx.env [options...]
#   run-bench.sh --state-dir /path/to/fixture-state-dir [options...]
#
# Any option not recognized here (--sessions, --latencies, --reps,
# --seed-lines, --out-dir, --skip-sync-check, --quick) is passed through to
# run_bench.py -- see `run_bench.py --help`.
#
# Requires an ALREADY-RUNNING fixture (this script never starts or stops
# one -- see Tests/ZmxFixture/zmx-fixture.sh start). Reuses it; never
# rebuilds the image.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd -P)

need_command() { command -v "$1" >/dev/null 2>&1 || { echo "run-bench: required command not found: $1" >&2; exit 1; }; }
need_command python3
need_command ssh
need_command podman

env_file=""
state_dir=""

# POSIX sh has no arrays: walk exactly the original argument count (`i` vs
# `remaining`), shifting one word off the front per iteration and either
# consuming it (--env-file/--state-dir) or moving it to the back with
# `set --`. Without the counter this would loop forever re-visiting the
# words it just moved to the back.
remaining=$#
i=0
while [ "$i" -lt "$remaining" ]; do
    arg=$1
    shift
    case "$arg" in
        --env-file)
            [ "$#" -ge 1 ] || { echo "run-bench: --env-file requires a path" >&2; exit 1; }
            env_file=$1
            shift
            i=$((i + 2))
            ;;
        --state-dir)
            [ "$#" -ge 1 ] || { echo "run-bench: --state-dir requires a path" >&2; exit 1; }
            state_dir=$1
            shift
            i=$((i + 2))
            ;;
        *)
            set -- "$@" "$arg"
            i=$((i + 1))
            ;;
    esac
done

if [ -z "$env_file" ]; then
    if [ -z "$state_dir" ]; then
        echo "run-bench: need --env-file FILE or --state-dir DIR (see README.md)" >&2
        exit 1
    fi
    env_file=$(mktemp "${TMPDIR:-/tmp}/zmx-bench-env.XXXXXX")
    "$repo_root/Tests/ZmxFixture/zmx-fixture.sh" env "$state_dir" > "$env_file"
fi

[ -f "$env_file" ] || { echo "run-bench: env file not found: $env_file" >&2; exit 1; }

exec python3 "$script_dir/run_bench.py" --env-file "$env_file" "$@"
