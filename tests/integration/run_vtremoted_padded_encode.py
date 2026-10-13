#!/usr/bin/env python3
"""Check padded encoder input through none/LZ4/Zstd transport on real hardware."""

import argparse
import hashlib
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

from run_transport_regressions import hello, message, read_message, string

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", str(ROOT / "ffmpeg/ffmpeg")))
    parser.add_argument("--daemon", default=os.environ.get("VTREMOTED", str(ROOT / "vtremoted/.build/release/vtremoted")))
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="vtremote-padded-encode-"))
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with (directory / "daemon.log").open("w") as log:
        daemon = subprocess.Popen([args.daemon, "--listen", f"127.0.0.1:{port}",
                                   "--idle-timeout", "2"], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), 0.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline or daemon.poll() is not None:
                        raise RuntimeError(f"daemon did not listen; see {directory}")
                    time.sleep(0.02)

            for codec, pix_fmt in (("h264", "nv12"), ("hevc", "p010le"), ("hevc", "bgra")):
                for width in (254, 258):
                    reference = None
                    for wire in ("none", "lz4", "zstd"):
                        name = f"{codec}-{pix_fmt}-{width}-{wire}"
                        output = directory / f"{name}.mkv"
                        with (directory / f"{name}.log").open("w") as capture:
                            subprocess.run([
                                args.ffmpeg, "-hide_banner", "-v", "warning", "-nostdin", "-xerror",
                                "-f", "lavfi", "-i", f"testsrc2=size={width}x146:rate=30",
                                "-frames:v", "60", "-pix_fmt", pix_fmt,
                                "-c:v", f"{codec}_videotoolbox_remote", "-b:v", "500k", "-g", "30", "-bf", "0",
                                "-vt_remote_host", f"127.0.0.1:{port}", "-vt_remote_wire_compression", wire,
                                "-vt_remote_inflight", "1", str(output),
                            ], check=True, stdout=capture, stderr=capture, timeout=30)
                            decoded = subprocess.check_output([
                                args.ffmpeg, "-v", "error", "-nostdin", "-xerror", "-err_detect", "explode",
                                "-i", str(output), "-map", "0:v:0", "-f", "framemd5", "-",
                            ], stderr=capture, timeout=30)
                        frames = [line for line in decoded.splitlines() if not line.startswith(b"#")]
                        assert len(frames) == 60, f"frame count mismatch: {name}"
                        digest = hashlib.sha256(b"\n".join(frames)).hexdigest()
                        if reference is None:
                            reference = digest
                        assert digest == reference, f"decoded pixels or timestamps differ: {name}"
                    print(f"PASS {codec}/{pix_fmt} {width}x146: all 60 frames identical across transports", flush=True)

            # A bulk read must still fail on a truncated plane and release the session.
            with socket.create_connection(("127.0.0.1", port), 3) as peer:
                peer.settimeout(5)
                peer.sendall(hello())
                assert read_message(peer)[0] == 2
                options = {"mode": "encode", "bitrate": "500000", "max_b_frames": "0", "wire_compression": "0"}
                body = struct.pack(">IIBIIIIH", 258, 146, 1, 1, 30, 30, 1, len(options))
                body += b"".join(string(key) + string(value) for key, value in options.items())
                peer.sendall(message(3, body))
                kind, ack = read_message(peer)
                assert kind == 4 and ack[0] == 0
                frame = struct.pack(">qqIBIII", 0, 1, 0, 2, 320, 146, 320 * 146)
                peer.sendall(message(5, frame + bytes(320 * 146))[:12 + len(frame) + 319])
                peer.shutdown(socket.SHUT_WR)
                kind, _ = read_message(peer)
                assert kind == 9, "truncated plane did not report ERROR"
            print("PASS truncated padded plane reports an error", flush=True)
        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()
    print(f"Results: {directory}")


if __name__ == "__main__":
    main()
