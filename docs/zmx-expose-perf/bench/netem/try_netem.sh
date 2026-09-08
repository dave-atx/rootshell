#!/bin/sh
#
# Best-effort attempt to use `tc netem` INSIDE the fixture container for
# latency injection, before falling back to the host-side delay proxy
# (delay_proxy.py). Rootless Podman was expected to deny this outright
# (missing NET_ADMIN); what was actually found on this dev machine (a
# Fedora CoreOS podman machine under Apple Hypervisor) is different and
# worth recording: NET_ADMIN IS granted to a container started with
# `--cap-add=NET_ADMIN`, but the podman machine's kernel has no
# `sch_netem` module at all -- `tc qdisc add ... netem` fails with
# "Specified qdisc kind is unknown" regardless of capabilities. Verified
# 2026-09-08 with a throwaway debian:12-slim container (not the fixture
# image, which does not ship iproute2 either). See README.md.
#
# The zmx fixture container itself is started by zmx-fixture.sh WITHOUT
# --cap-add=NET_ADMIN (it never needed it before), so this script's first
# check -- capability presence -- will already fail there. It still runs
# the real check rather than hard-coding the answer, so it keeps telling
# the truth if either constraint is ever lifted (a future fixture image
# with iproute2 baked in, or a podman machine whose kernel carries
# sch_netem).
#
# Usage: try_netem.sh CONTAINER_ID DELAY_MS
# Exit status: 0 netem works (qdisc added -- caller must remove it when
#              done, see `tc qdisc del dev eth0 root`), 1 not viable
#              (fall back to the delay proxy), 2 usage error.

set -eu

[ "$#" -eq 2 ] || { echo "usage: try_netem.sh CONTAINER_ID DELAY_MS" >&2; exit 2; }
container_id=$1
delay_ms=$2
podman_bin=${PODMAN_BIN:-podman}

reason=""

if ! "$podman_bin" exec "$container_id" sh -c 'command -v tc >/dev/null 2>&1'; then
    reason="tc(8) is not installed in the fixture image"
elif ! "$podman_bin" exec "$container_id" sh -c \
    'cat /proc/self/status 2>/dev/null | grep -qi "^CapEff:.*[1-9a-f]" && tc qdisc add dev eth0 root netem delay '"${delay_ms}"'ms' 2>/tmp/try_netem.stderr; then
    reason="tc qdisc add failed: $(tail -n1 /tmp/try_netem.stderr 2>/dev/null || echo 'unknown error')"
fi

if [ -n "$reason" ]; then
    echo "try_netem: not viable -- $reason" >&2
    exit 1
fi

echo "try_netem: netem delay ${delay_ms}ms active on $container_id (eth0)" >&2
exit 0
