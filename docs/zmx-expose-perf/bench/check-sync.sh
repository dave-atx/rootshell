#!/bin/sh
#
# Verifies that docs/zmx-expose-perf/bench/lib/mux_scripts.py still matches
# the Swift source it transcribes (see sync-manifest.txt for why this is a
# transcription and not an import). Run this before trusting any benchmark
# number: a drifted script would silently benchmark something the app no
# longer sends over the wire.
#
# Usage: check-sync.sh [--quiet]
# Exit status: 0 all rows match, 1 any row drifted, 2 usage/setup error.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd -P)
manifest=$script_dir/sync-manifest.txt
quiet=false
[ "${1:-}" = "--quiet" ] && quiet=true

[ -f "$manifest" ] || { echo "check-sync: missing manifest: $manifest" >&2; exit 2; }

fail=0
count=0
while IFS=: read -r path start end want_hash; do
    case "$path" in
        ''|'#'*) continue ;;
    esac
    count=$((count + 1))
    file="$repo_root/$path"
    if [ ! -f "$file" ]; then
        echo "DRIFT  $path:$start-$end -- file not found" >&2
        fail=1
        continue
    fi
    got_hash=$(sed -n "${start},${end}p" "$file" | shasum -a 256 | awk '{print $1}')
    if [ "$got_hash" = "$want_hash" ]; then
        $quiet || echo "ok     $path:$start-$end"
    else
        echo "DRIFT  $path:$start-$end" >&2
        echo "       expected $want_hash" >&2
        echo "       got      $got_hash" >&2
        fail=1
    fi
done < "$manifest"

if [ "$count" -eq 0 ]; then
    echo "check-sync: manifest had no rows: $manifest" >&2
    exit 2
fi

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

check-sync: FAILED -- rootshell's script-building source has moved since
lib/mux_scripts.py was last verified against it. The benchmark would be
measuring a script the app no longer sends. Re-read the drifted range(s),
update the matching function(s) in lib/mux_scripts.py, then regenerate the
hash with:
    sed -n 'START,ENDp' FILE | shasum -a 256
and update sync-manifest.txt.

Override (NOT recommended -- only for a deliberate, already-reviewed drift):
    ZMX_BENCH_SKIP_SYNC_CHECK=1 ./run-bench.sh ...
EOF
    exit 1
fi

$quiet || echo "check-sync: all $count row(s) match"
exit 0
