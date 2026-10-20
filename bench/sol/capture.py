#!/usr/bin/env python3
# Capture the exact wire bytes an app returns for each benchmark route, as
# replay files for bench/sol/sol.c (`sol PORT PATH=FILE...`).
#
#   bench/sol/capture.py --base http://127.0.0.1:PORT --out DIR \
#       --cookie-file FILE --routes room_show=/rooms/123 avatar=/users/TKN/avatar ...
#
# The load generator asks with Accept-Encoding: gzip and a session cookie; we
# do the same so the replayed bytes are what the benchmark actually measures.
# Files are named after the route label.
import argparse, socket, sys

def fetch(host, port, path, cookie, gzip_wanted):
    ae = b"gzip" if gzip_wanted else b"identity"
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Accept-Encoding: {ae.decode()}\r\n"
        f"Cookie: {cookie}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode()
    s = socket.create_connection((host, port), timeout=10)
    s.sendall(req)
    chunks = []
    while True:
        data = s.recv(1 << 16)
        if not data:
            break
        chunks.append(data)
    s.close()
    return b"".join(chunks)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--cookie-file", required=True)
    p.add_argument("--identity", action="store_true", help="capture without gzip")
    p.add_argument("routes", nargs="+", help="label=/path entries")
    a = p.parse_args()
    host_port = a.base.split("://", 1)[1].rstrip("/")
    host, _, port = host_port.partition(":")
    cookie = open(a.cookie_file).read().strip()
    import os
    os.makedirs(a.out, exist_ok=True)
    for spec in a.routes:
        label, _, path = spec.partition("=")
        if not path:
            sys.exit(f"bad route spec {spec!r} (want label=/path)")
        raw = fetch(host, int(port or 80), path, cookie, not a.identity)
        fn = f"{a.out.rstrip('/')}/{label}.http"
        with open(fn, "wb") as f:
            f.write(raw)
        head, _, _ = raw.partition(b"\r\n")
        print(f"{label:16} {len(raw):>8} bytes  {head.decode(errors='replace')}")

if __name__ == "__main__":
    main()
