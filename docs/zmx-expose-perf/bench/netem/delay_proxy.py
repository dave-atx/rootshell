#!/usr/bin/env python3
"""Host-side TCP delay proxy -- the latency-injection fallback.

`try_netem.sh` establishes that `tc netem` is not usable against this
fixture: the image ships no `tc`, and separately (verified against a
throwaway container with iproute2 installed) this host's podman machine
kernel has no `sch_netem` qdisc at all, so netem would fail even with
NET_ADMIN granted. See README.md for how that was verified.

This proxy is a plain asyncio TCP relay between a local listening port and
the fixture's published SSH port. It delays every relayed chunk by
`--delay-ms` before forwarding it, independently in each direction. A full
round trip crosses the proxy twice (client->server, then the reply
server->client), so it gains ~2x --delay-ms of one-way delay. To target an
added round-trip time of D ms, run with `--delay-ms D/2`.

measure_rtt.py verifies the actual delay produced (it does not just trust
the --delay-ms argument): it times how long the SSH server's version
banner takes to arrive after connecting through the proxy, which is
exactly one one-way hop (the server sends its banner unprompted, before
any client data crosses the proxy) and should read close to --delay-ms.
"""

from __future__ import annotations

import argparse
import asyncio
import sys


async def _pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, delay_s: float) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            if delay_s > 0:
                await asyncio.sleep(delay_s)
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        writer.close()


async def _handle(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    upstream_host: str,
    upstream_port: int,
    delay_s: float,
) -> None:
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(upstream_host, upstream_port)
    except OSError as exc:
        print(f"delay-proxy: upstream connect failed: {exc}", file=sys.stderr, flush=True)
        client_writer.close()
        return
    await asyncio.gather(
        _pump(client_reader, upstream_writer, delay_s),
        _pump(upstream_reader, client_writer, delay_s),
    )


async def _main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument(
        "--delay-ms", type=float, required=True,
        help="one-way delay applied per relayed chunk, per direction (target RTT / 2)",
    )
    parser.add_argument(
        "--ready-file", default=None,
        help="written once the listener is bound, so a caller can poll for readiness",
    )
    args = parser.parse_args()
    delay_s = args.delay_ms / 1000.0

    server = await asyncio.start_server(
        lambda r, w: _handle(r, w, args.upstream_host, args.upstream_port, delay_s),
        host="127.0.0.1",
        port=args.listen_port,
    )
    if args.ready_file:
        with open(args.ready_file, "w") as f:
            f.write("ready\n")
    print(
        f"delay-proxy: 127.0.0.1:{args.listen_port} -> "
        f"{args.upstream_host}:{args.upstream_port} delay={args.delay_ms}ms/hop (pid={__import__('os').getpid()})",
        file=sys.stderr, flush=True,
    )
    async with server:
        await server.serve_forever()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(_main()))
    except KeyboardInterrupt:
        raise SystemExit(0)
