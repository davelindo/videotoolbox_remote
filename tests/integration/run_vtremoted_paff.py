#!/usr/bin/env python3
"""Check separately packetized, mixed and already-paired H.264 fields."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
SUITE = "https://fate-suite.ffmpeg.org/"
FIXTURES = (
    ("h264-conformance/Sharp_MP_Field_1_B.jvt",
     "19f22b627c6da7d075efc552c0b0d04429375f4ac7317b357175684d7c91ca19", 15, 30),
    ("h264-conformance/Sharp_MP_PAFF_1r2.jvt",
     "541df810a033d64a2706d25cc335b80d562041af586f3f622d2d1d79566bd588", 15, 23),
    ("h264-conformance/CVPA1_TOSHIBA_B.264",
     "23c2b3299efed3475956b0f7e6a098387ceba1cf3f0b17aff8906daadaf09dc3", 90, 138),
    ("h264/twofields_packet.mp4",
     "96033a51958f07033a3742ba63b05931ac61f125433d863df8431a846a764843", 147, 147),
)


def run(command, log):
    with log.open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=output, timeout=120)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}); see {log}")


def probe(binary, source, packets=False):
    command = [binary, "-v", "error", "-select_streams", "v:0", "-count_frames",
               "-count_packets", "-show_streams", "-of", "json", str(source)]
    if packets:
        command.insert(-1, "-show_packets")
    return json.loads(subprocess.check_output(command, stderr=subprocess.PIPE, timeout=60))


def fixture(directory, relative, digest):
    source = directory / Path(relative).name
    if not source.exists():
        with urllib.request.urlopen(SUITE + relative, timeout=30) as response, source.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
    if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f"fixture SHA-256 mismatch: {source}")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=str(ROOT / "ffmpeg/ffmpeg"))
    parser.add_argument("--local-ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--daemon", default=str(ROOT / "vtremoted/.build/debug/vtremoted"))
    parser.add_argument("--fixtures", type=Path, help="cache of the four hash-checked FFmpeg FATE fixtures")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    directory = args.output or Path(tempfile.mkdtemp(prefix="vtremote-paff-"))
    directory.mkdir(parents=True, exist_ok=True)
    fixtures = args.fixtures or directory / "fixtures"
    fixtures.mkdir(parents=True, exist_ok=True)
    print(f"Logs and samples: {directory}", flush=True)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with (directory / "server.log").open("w") as log:
        server = subprocess.Popen([args.daemon, "--listen", f"127.0.0.1:{port}", "--log-level", "1"],
                                  stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                if server.poll() is not None:
                    raise RuntimeError("test daemon exited before listening")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("test daemon failed to listen")
                    time.sleep(0.05)

            for relative, digest, frames, packets in FIXTURES:
                source = fixture(fixtures, relative, digest)
                name = source.stem
                reference = probe(args.ffprobe, source)["streams"][0]
                assert int(reference["nb_read_frames"]) == frames, f"unexpected reference frames: {source}"
                assert int(reference["nb_read_packets"]) == packets, f"unexpected packetization: {source}"
                transport = source
                if source.suffix != ".mp4":
                    transport = directory / f"{name}-input.mp4"
                    # Raw conformance streams have no timestamps. Derive PTS from
                    # picture order, rather than assigning decode-order PTS to B-frames.
                    run([args.local_ffmpeg, "-v", "error", "-y", "-fflags", "+genpts",
                         "-i", str(source), "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "dts2pts",
                         str(transport)], directory / f"{name}-remux.log")
                for asynchronous in (0, 1):
                    label = f"{name}-async{asynchronous}"
                    output = directory / f"{label}.ts"
                    client_log = directory / f"{label}-client.log"
                    server_offset = (directory / "server.log").stat().st_size
                    run([args.ffmpeg, "-hide_banner", "-v", "verbose", "-y", "-i", str(transport),
                         "-map", "0:v:0", "-c:v", "copy", "-vt_remote_transcode:v:0",
                         "-vt_remote_host", "127.0.0.1", "-vt_remote_port", str(port),
                         "-vt_remote_decode_async", str(asynchronous), "-vt_remote_inflight", "1",
                         "-vt_remote_out_codec:v:0", "h264", "-b:v", "8M", "-g:v", "50",
                         str(output)], client_log)
                    assert "vtremote server error" not in client_log.read_text(), f"server error: {client_log}"
                    server_log = (directory / "server.log").read_bytes()[server_offset:].decode()
                    expected_mode = "true" if asynchronous else "false"
                    assert re.search(rf"DECODE codec=h264 .* async={expected_mode}\b", server_log), "decode mode was not forwarded"
                    result = probe(args.ffprobe, output, packets=True)
                    assert int(result["streams"][0]["nb_read_frames"]) == frames, f"wrong output frame count: {output}"
                    timing = result["packets"]
                    assert len(timing) == frames, f"wrong output packet count: {output}"
                    pts = [int(packet["pts"]) for packet in timing]
                    assert all(a < b for a, b in zip(pts, pts[1:])), f"unordered output PTS: {output}"
                    run([args.local_ffmpeg, "-v", "error", "-xerror", "-i", str(output),
                         "-map", "0:v:0", "-f", "null", "-"], directory / f"{label}-decode.log")
                    quality_log = directory / f"{label}-ssim.log"
                    run([args.local_ffmpeg, "-hide_banner", "-v", "info", "-i", str(source),
                         "-i", str(output), "-lavfi",
                         "[0:v]setpts=N/(25*TB),format=yuv420p[ref];"
                         "[1:v]setpts=N/(25*TB),format=yuv420p[out];[ref][out]ssim=shortest=1",
                         "-an", "-f", "null", "-"], quality_log)
                    match = re.search(r"SSIM .*All:([0-9.]+)", quality_log.read_text())
                    assert match and float(match[1]) > 0.95, f"pixel/order mismatch: {quality_log}"
                    print(f"OK: {label}: {packets} input packets -> {frames} decoded frames; SSIM={match[1]}", flush=True)

            field_source = directory / "Sharp_MP_Field_1_B-input.mp4"
            for label, extra, expected_error in (
                ("missing-final-field", ["-frames:v", "29"], "input ended with an unpaired field"),
                ("missing-second-field", ["-bsf:v", "noise=drop='eq(n,1)'"], "non-complementary field packets"),
            ):
                malformed = directory / f"{label}.mp4"
                run([args.local_ffmpeg, "-v", "error", "-y", "-i", str(field_source),
                     "-map", "0:v:0", "-c:v", "copy", *extra, str(malformed)], directory / f"{label}-remux.log")
                client_log = directory / f"{label}-client.log"
                with client_log.open("w") as output:
                    result = subprocess.run([
                        args.ffmpeg, "-hide_banner", "-v", "verbose", "-xerror", "-i", str(malformed),
                        "-map", "0:v:0", "-c:v", "copy", "-vt_remote_transcode:v:0",
                        "-vt_remote_host", "127.0.0.1", "-vt_remote_port", str(port),
                        "-f", "null", "-",
                    ], stdout=output, stderr=output, timeout=30)
                assert result.returncode != 0 and expected_error in client_log.read_text(), f"bad field accepted: {client_log}"
                print(f"OK: {label}: rejected incomplete picture", flush=True)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()
