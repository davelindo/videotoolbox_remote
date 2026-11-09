#!/usr/bin/env python3
"""Verify HEVC random access survives omitted leading pictures in both modes."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", str(ROOT / "ffmpeg/ffmpeg")))
    parser.add_argument("--fixture-ffmpeg", default=os.environ.get("FFMPEG_LOCAL_BIN", "ffmpeg"))
    parser.add_argument("--ffprobe", default=os.environ.get("FFPROBE", "ffprobe"))
    parser.add_argument("--daemon", default=os.environ.get("VTREMOTED", str(ROOT / "vtremoted/.build/debug/vtremoted")))
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="vtremote-hevc-leading-"))
    print(f"Logs and generated samples: {directory}", flush=True)

    def run(command, label):
        with (directory / f"{label}.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=log, check=True, timeout=60)

    source = directory / "open-gop.mp4"
    run([args.fixture_ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
         "testsrc2=size=96x64:rate=12", "-t", "4", "-c:v", "libx265", "-preset", "ultrafast",
         "-x265-params", "pools=1:frame-threads=1:log-level=error:keyint=12:min-keyint=12:"
         "scenecut=0:open-gop=1:bframes=3", str(source)], "generate")

    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    server_log = directory / "daemon.log"
    with server_log.open("w") as log:
        daemon = subprocess.Popen([args.daemon, "--listen", f"127.0.0.1:{port}", "--log-level", "2"],
                                  stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), 0.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline or daemon.poll() is not None:
                        raise RuntimeError(f"daemon did not listen; see {directory}")
                    time.sleep(0.02)

            for mode in ("decode", "transcode"):
                for asynchronous in (0, 1):
                    label = f"{mode}-async{asynchronous}"
                    output = directory / f"{label}.mkv"
                    offset = server_log.stat().st_size
                    command = [args.ffmpeg, "-nostdin", "-v", "error", "-xerror", "-ss", "2"]
                    if mode == "decode":
                        command += ["-c:v", "hevc_videotoolbox_remote", "-vt_remote_host", f"127.0.0.1:{port}",
                                    "-vt_remote_decode_async", str(asynchronous)]
                    command += ["-i", str(source), "-map", "0:v:0", "-an"]
                    if mode == "decode":
                        # Synchronous callbacks can arrive in decode order. Keep
                        # every picture when packaging this frame-count check.
                        command += ["-vf", "setpts=N/(12*TB)", "-enc_time_base", "1:12",
                                    "-c:v", "ffv1", "-fps_mode", "passthrough"]
                    else:
                        bsf = (f"vtremote_transcode=vt_remote_host=127.0.0.1:vt_remote_port={port}:"
                               f"vt_remote_decode_async={asynchronous}:vt_remote_inflight=1:"
                               "vt_remote_out_codec=h264:vt_remote_bitrate=500000:"
                               "vt_remote_max_b_frames=0:vt_remote_start_time=0")
                        command += ["-c:v", "copy", "-copypriorss", "1", "-bsf:v", bsf]
                    run([*command, str(output)], label)
                    run([args.fixture_ffmpeg, "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
                         "-i", str(output), "-map", "0:v:0", "-f", "null", "-"], f"{label}-decode")
                    probe = json.loads(subprocess.check_output([
                        args.ffprobe, "-v", "error", "-count_frames", "-select_streams", "v:0",
                        "-show_entries", "stream=nb_read_frames", "-of", "json", str(output)
                    ], timeout=30))
                    assert int(probe["streams"][0]["nb_read_frames"]) == 24, f"{label}: wrong frame count"
                    diagnostic = server_log.read_bytes()[offset:].decode()
                    assert "DECODE skipped leading frame" in diagnostic, f"{label}: fixture did not exercise a drop"
                    assert "fatal codec error" not in diagnostic, f"{label}: terminal decoder error"
                    print(f"PASS {label}: leading pictures omitted, 24 frames independently decoded", flush=True)
        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()


if __name__ == "__main__":
    main()
