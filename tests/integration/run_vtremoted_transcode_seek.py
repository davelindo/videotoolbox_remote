#!/usr/bin/env python3
"""Verify accurate packet-transcode seeks with a real VideoToolbox daemon."""

import argparse
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "hevc-input-seek": ("hevc", ["-ss", "2"], [], 0, None, 84, 0.0),
    "hevc-window-only": ("hevc", [], [], 2, None, 84, 2.0),
    "hevc-bounded-seek": ("hevc", ["-ss", "2"], ["-t", "3"], 0, 3, 36, 0.0),
    "hevc-copyts": ("hevc", ["-copyts", "-ss", "2"], [], 2, None, 84, 2.0),
    "hevc-between-frames": ("hevc", ["-ss", "2.04"], [], 0, None, 83, 0.043),
    "h264-input-seek": ("h264", ["-ss", "2.5"], [], 0, None, 78, 0.0),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", str(ROOT / "ffmpeg/ffmpeg")))
    parser.add_argument("--fixture-ffmpeg", default=os.environ.get("FIXTURE_FFMPEG"))
    parser.add_argument("--ffprobe", default=os.environ.get("FFPROBE", "ffprobe"))
    parser.add_argument("--daemon", default=os.environ.get("VTREMOTED", str(ROOT / "vtremoted/.build/debug/vtremoted")))
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--output-codec", choices=("h264", "hevc"), default="h264")
    args = parser.parse_args()
    fixture_ffmpeg = args.fixture_ffmpeg or args.ffmpeg
    directory = Path(tempfile.mkdtemp(prefix="vtremote-transcode-seek-"))
    print(f"Logs and generated samples: {directory}", flush=True)

    def run(command, name):
        with (directory / f"{name}.log").open("w") as log:
            return subprocess.run(command, stdout=log, stderr=log, check=True, timeout=60)

    source = directory / "input-h264.mp4"
    hevc = directory / "input-hevc.mp4"
    run([fixture_ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
         "testsrc2=size=160x90:rate=12", "-f", "lavfi", "-i", "sine=sample_rate=48000",
         "-t", "9", "-c:v", "libx264", "-threads", "2", "-preset", "ultrafast",
         "-g", "24", "-c:a", "aac", str(source)], "generate-h264")
    run([fixture_ffmpeg, "-nostdin", "-v", "error", "-i", str(source),
         "-c:v", "libx265", "-preset", "ultrafast", "-x265-params",
         "pools=1:frame-threads=1:log-level=error", "-c:a", "copy", str(hevc)], "generate-hevc")

    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with (directory / "daemon.log").open("w") as log:
        daemon = subprocess.Popen([args.daemon, "--listen", f"127.0.0.1:{port}"], stdout=log, stderr=log)
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

            bsf = (f"vtremote_transcode=vt_remote_host=127.0.0.1:vt_remote_port={port}:"
                   f"vt_remote_timeout_ms=10000:vt_remote_out_codec={args.output_codec}:"
                   "vt_remote_out_width=128:vt_remote_out_height=72:vt_remote_scale_mode=aspect:"
                   "vt_remote_pix_fmt=1:vt_remote_bitrate=150000:vt_remote_gop=48:"
                   "vt_remote_max_b_frames=0:vt_remote_allow_sw=0:vt_remote_realtime=1")
            for name, (codec, input_options, output_options, window_start, window_end, count, start) in CASES.items():
                if args.case and args.case != name:
                    continue
                output = directory / f"{name}.mkv"
                # The caller supplies video/audio windows on the same packet clock.
                audio_start = window_start
                window = f":vt_remote_start_time={window_start}"
                if window_end is not None:
                    window += f":vt_remote_end_time={window_end}"
                run([args.ffmpeg, "-nostdin", "-v", "warning", *input_options,
                     "-i", str(hevc if codec == "hevc" else source), *output_options,
                     "-map", "0:v:0", "-map", "0:a:0", "-sn", "-c:v", "copy", "-copypriorss", "1",
                     "-bsf:v", bsf + window,
                     "-c:a", "copy", "-bsf:a", f"noise=amount=0:drop='lt(pts*tb,{audio_start - 0.000001})'",
                     "-f", "matroska", "-live", "1", str(output)], name)
                run([fixture_ffmpeg, "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
                     "-i", str(output), "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-"], f"{name}-decode")
                result = json.loads(subprocess.check_output([
                    args.ffprobe, "-v", "error", "-count_frames", "-show_entries",
                    "stream=codec_type,nb_read_frames,start_time", "-of", "json", str(output),
                ], timeout=30))
                video = next(s for s in result["streams"] if s["codec_type"] == "video")
                audio = next(s for s in result["streams"] if s["codec_type"] == "audio")
                print(f"{name}: {json.dumps(result, sort_keys=True)}", flush=True)
                assert int(video["nb_read_frames"]) == count, f"{name}: expected {count} video frames"
                assert math.isclose(float(video["start_time"]), start, abs_tol=0.003), f"{name}: video start"
                assert abs(float(video["start_time"]) - float(audio["start_time"])) <= 1 / 12, f"{name}: A/V sync"
                packets = json.loads(subprocess.check_output([
                    args.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
                    "-show_entries", "packet=flags", "-of", "json", str(output),
                ], timeout=30))["packets"]
                assert "K" in packets[0]["flags"], f"{name}: first retained frame must be a keyframe"
                print(f"PASS {name}: {count} frames, synchronized audio, independently decodable output", flush=True)
        finally:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()


if __name__ == "__main__":
    main()
