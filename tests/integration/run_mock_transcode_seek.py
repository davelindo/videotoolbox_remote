#!/usr/bin/env python3
"""Check caller-supplied transcode windows through the project-owned BSF."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
BASE_CAPS = "h264,hevc,pixfmt.nv12,packet_ack.v1"
WINDOW_CAP = "transcode.presentation_window.v1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG_BIN", str(ROOT / "ffmpeg/ffmpeg")))
    parser.add_argument("--fixture-ffmpeg", default=os.environ.get("FIXTURE_FFMPEG"))
    args = parser.parse_args()
    fixture_ffmpeg = args.fixture_ffmpeg or args.ffmpeg
    directory = Path(tempfile.mkdtemp(prefix="vtremote-mock-seek-"))
    print(f"Logs and generated sample: {directory}", flush=True)
    source = directory / "input.mp4"
    subprocess.run([fixture_ffmpeg, "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=64x64:rate=12:duration=4", "-c:v", "libx264",
                    "-preset", "ultrafast", "-g", "48", "-video_track_timescale", "12000", str(source)],
                   check=True, timeout=20)
    # The generated MP4 has a 1/12000 clock. Values below are wire PTS, not seconds.
    caps = BASE_CAPS + "," + WINDOW_CAP
    cases = [
        ("unchanged", [], None, None, None, None, BASE_CAPS, False, None),
        ("input", ["-ss", "2"], "0", None, 0, None, caps, False, None),
        ("bounded", ["-ss", "1"], "0", "2", 0, 24000, caps, False, None),
        ("window-only", [], "1", "3", 12000, 36000, caps, False, None),
        ("copyts", ["-copyts", "-ss", "2"], "2", None, 24000, None, caps, False, None),
        ("chain", ["-ss", "2"], "0", None, 0, None, caps, True, None),
        ("fractional", [], "0.000001", "1.000001", 1, 12001, caps, False, None),
        ("negative", [], "-0.000001", "0.000001", 0, 1, caps, False, None),
        ("end-only", [], None, "2", None, 24000, caps, False, None),
        ("missing-window", ["-ss", "2"], "0", None, None, None, BASE_CAPS, False, "transcode presentation window"),
        ("missing-credits", ["-ss", "2"], "0", None, None, None, "h264,pixfmt.nv12," + WINDOW_CAP, False, "input credits"),
    ]
    for name, input_options, start_time, end_time, start, end, caps, chain, error in cases:
        ready = directory / f"{name}.ready"
        expectations = []
        if start is not None:
            expectations += ["--expect-presentation-start-pts", str(start)]
        if end is not None:
            expectations += ["--expect-presentation-end-pts", str(end)]
        with (directory / f"{name}-server.log").open("w") as log:
            server = subprocess.Popen([
                sys.executable, str(ROOT / "tests/integration/mock_vtremoted/mock_vtremoted.py"),
                "--listen", "127.0.0.1:0", "--ready-file", str(ready), "--capabilities", caps,
                "--packet-reply", "none", "--once", *expectations,
            ], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"{name}: mock did not listen; see {directory}")
                    time.sleep(0.02)
                host, port = ready.read_text().strip().rsplit(":", 1)
                bsf = f"vtremote_transcode=vt_remote_host={host}:vt_remote_port={port}"
                if start_time is not None:
                    bsf += f":vt_remote_start_time={start_time}"
                if end_time is not None:
                    bsf += f":vt_remote_end_time={end_time}"
                options = ["-bsf:v", ("noise=amount=0," if chain else "") + bsf]
                with (directory / f"{name}-client.log").open("w+") as client_log:
                    result = subprocess.run([
                        args.ffmpeg, "-nostdin", "-v", "warning", *input_options, "-i", str(source),
                        "-map", "0:v:0", "-c:v", "copy", "-copypriorss", "1", *options, "-f", "null", "-",
                    ], stdout=client_log, stderr=client_log, timeout=15)
                    client_log.seek(0)
                    text = client_log.read()
                if error:
                    assert result.returncode != 0 and error in text, f"{name}: expected capability failure; see {directory}"
                else:
                    assert result.returncode == 0, f"{name}: client failed; see {directory}"
                    assert server.wait(timeout=5) == 0, f"{name}: configure mismatch; see {directory}"
                print(f"PASS {name}", flush=True)
            finally:
                if server.poll() is None:
                    server.terminate()
                    server.wait(timeout=5)


if __name__ == "__main__":
    main()
