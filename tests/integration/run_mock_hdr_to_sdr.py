#!/usr/bin/env python3
"""Verify HDR opt-in negotiation and source/output validation without a Mac."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG_BIN", str(ROOT / "ffmpeg/ffmpeg")))
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="vtremote-mock-hdr-"))
    print(f"Logs and generated samples: {directory}", flush=True)
    for transfer in ["smpte2084", "arib-std-b67", "bt709"]:
        with (directory / f"generate-{transfer}.log").open("w") as log:
            subprocess.run([args.ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                "testsrc2=size=64x64:rate=5:duration=1", "-pix_fmt", "yuv420p10le",
                "-c:v", "libx265", "-preset", "ultrafast", "-x265-params",
                f"pools=1:frame-threads=1:log-level=error:colorprim=9:colormatrix=9:transfer={ {'smpte2084': 16, 'arib-std-b67': 18, 'bt709': 1}[transfer] }", "-color_primaries", "bt2020",
                "-colorspace", "bt2020nc", "-color_trc", transfer, str(directory / f"{transfer}.mp4")],
                stdout=log, stderr=log, check=True, timeout=30)
    baseline = "h264,hevc,pixfmt.nv12,pixfmt.p010,packet_ack.v1,side_data.v2"
    cases = [
        ("pq", "smpte2084", True, "", None),
        ("hlg", "arib-std-b67", True, "", None),
        ("old-server", "smpte2084", False, "", "HDR-to-SDR tone mapping"),
        ("sdr-source", "bt709", True, "", "requires 10-bit 4:2:0 HEVC BT.2020 PQ/HLG"),
        ("conflicting-tags", "smpte2084", True, ":vt_remote_color_trc=16", "output must be limited-range BT.709"),
        ("unsupported-output", "smpte2084", True, ":vt_remote_pix_fmt=3", "requires 10-bit 4:2:0 HEVC"),
    ]
    for name, transfer, capable, extra, error in cases:
        ready = directory / f"{name}.ready"
        with (directory / f"{name}-server.log").open("w") as server_log:
            server = subprocess.Popen([sys.executable, str(ROOT / "tests/integration/mock_vtremoted/mock_vtremoted.py"),
                "--listen", "127.0.0.1:0", "--ready-file", str(ready), "--once", "--packet-reply", "none",
                "--capabilities", baseline + (",transcode.hdr_to_sdr.v1" if capable else ""),
                "--expect-hdr-to-sdr", "1", "--expect-hdr-source-transfer", "18" if transfer == "arib-std-b67" else "16",
                "--expect-color-range", "1", "--expect-colorspace", "1", "--expect-color-primaries", "1",
                "--expect-color-trc", "1"], stdout=server_log, stderr=server_log)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"mock did not listen; see {directory}")
                    time.sleep(0.02)
                host, port = ready.read_text().strip().rsplit(":", 1)
                bsf = (f"vtremote_transcode=vt_remote_host={host}:vt_remote_port={port}:"
                       "vt_remote_timeout_ms=3000:vt_remote_hdr_to_sdr=1:vt_remote_out_codec=hevc" + extra)
                with (directory / f"{name}-client.log").open("w+") as log:
                    result = subprocess.run([args.ffmpeg, "-nostdin", "-v", "warning", "-i",
                        str(directory / f"{transfer}.mp4"), "-map", "0:v:0", "-c:v", "copy",
                        "-bsf:v", bsf, "-f", "null", "-"], stdout=log, stderr=log, timeout=15)
                    log.seek(0)
                    output = log.read()
                if error:
                    assert result.returncode != 0 and error in output, (name, output)
                else:
                    assert result.returncode == 0, (name, output)
                    assert server.wait(timeout=5) == 0, f"{name}: configuration mismatch; see {directory}"
                print(f"PASS {name}", flush=True)
            finally:
                if server.poll() is None:
                    server.terminate()
                    server.wait(timeout=5)


if __name__ == "__main__":
    main()
