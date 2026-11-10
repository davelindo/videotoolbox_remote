#!/usr/bin/env python3
"""Verify HDR-to-SDR pixels, signalling and seeks through a real Mac daemon."""

import argparse
from array import array
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
WIDTH, HEIGHT, FPS, FRAMES = 256, 128, 12, 48


def pq(nits):
    p = (nits / 10000) ** (2610 / 16384)
    return ((3424 / 4096 + 2413 / 128 * p) / (1 + 2392 / 128 * p)) ** (2523 / 32)


def hlg(nits):
    linear = (nits / 1000) ** (1 / 1.2)
    a, b, c = 0.17883277, 0.28466892, 0.55991073
    return math.sqrt(3 * linear) if linear <= 1 / 12 else a * math.log(12 * linear - b) + c


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG_BIN", str(ROOT / "ffmpeg/ffmpeg")))
    parser.add_argument("--fixture-ffmpeg", default=os.environ.get("FFMPEG_LOCAL_BIN", "ffmpeg"))
    parser.add_argument("--ffprobe", default=os.environ.get("FFPROBE_LOCAL_BIN", "ffprobe"))
    parser.add_argument("--daemon", default=os.environ.get("VTREMOTED", str(ROOT / "vtremoted/.build/debug/vtremoted")))
    parser.add_argument("--endpoint", help="Use an existing test daemon at HOST:PORT")
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix="vtremote-hdr-to-sdr-"))
    print(f"Logs and generated samples: {directory}", flush=True)

    def run(command, name):
        with (directory / f"{name}.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=log, check=True, timeout=90)

    def probe(path, *options):
        return json.loads(subprocess.check_output(
            [args.ffprobe, "-v", "error", *options, "-of", "json", str(path)], timeout=30))

    sources = {}
    for transfer, peak, curve, nits in [
        ("smpte2084", 10000, pq, [0, 10, 100, 203, 400, 1000, 4000, 10000]),
        ("arib-std-b67", 1000, hlg, [0, 1, 10, 50, 100, 250, 500, 1000]),
    ]:
        raw = directory / f"{transfer}.yuv"
        # Generate binary media outside the checkout, including a changing frame
        # marker below the static luminance bars.
        with raw.open("wb") as output:
            for frame in range(FRAMES):
                luma = array("H", (round(64 + 876 * curve(nits[min(7, x // 32)]))
                                   if y < HEIGHT - 16 else 64 + frame * 16
                                   for y in range(HEIGHT) for x in range(WIDTH)))
                chroma = array("H", [512]) * (WIDTH * HEIGHT // 2)
                if sys.byteorder != "little":
                    luma.byteswap()
                    chroma.byteswap()
                output.write(luma.tobytes() + chroma.tobytes())
        source = directory / f"{transfer}.mkv"
        run([args.fixture_ffmpeg, "-nostdin", "-v", "error", "-f", "rawvideo",
             "-pixel_format", "yuv420p10le", "-video_size", f"{WIDTH}x{HEIGHT}",
             "-framerate", str(FPS), "-i", str(raw), "-f", "lavfi", "-i", "sine=sample_rate=48000",
             "-t", "4", "-c:v", "libx265", "-preset", "ultrafast", "-x265-params",
             f"lossless=1:pools=1:frame-threads=1:log-level=error:keyint=24:min-keyint=24:scenecut=0:bframes=4:"
             f"colorprim=9:transfer={16 if peak == 10000 else 18}:colormatrix=9:"
             f"master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L({peak * 10000},1):"
             f"max-cll={peak},203", "-color_range", "tv", "-color_primaries", "bt2020",
             "-colorspace", "bt2020nc", "-color_trc", transfer, "-c:a", "aac", str(source)],
            f"generate-{transfer}")
        sources[transfer] = source

    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    host = "127.0.0.1"
    if args.endpoint:
        host, port = args.endpoint.rsplit(":", 1)
        port = int(port)
    with (directory / "daemon.log").open("w") as log:
        daemon = None if args.endpoint else subprocess.Popen(
            [args.daemon, "--listen", f"127.0.0.1:{port}"], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    with socket.create_connection((host, port), 0.1):
                        break
                except OSError:
                    if (daemon is not None and daemon.poll() is not None) or time.monotonic() >= deadline:
                        raise RuntimeError(f"daemon did not listen; see {directory}")
                    time.sleep(0.02)
            cases = [(transfer, codec, pixel, False) for transfer in sources
                     for codec, pixel in [("h264", 1), ("hevc", 1), ("hevc", 2)]]
            cases.append(("smpte2084", "hevc", 2, True))
            for transfer, codec, pixel, seek in cases:
                name = f"{transfer}-{codec}-{pixel}" + ("-seek" if seek else "")
                output = directory / f"{name}.mkv"
                width, height = (128, 64) if seek else (WIDTH, HEIGHT)
                bsf = (f"vtremote_transcode=vt_remote_host={host}:vt_remote_port={port}:"
                       f"vt_remote_timeout_ms=15000:vt_remote_out_codec={codec}:vt_remote_pix_fmt={pixel}:"
                       f"vt_remote_out_width={width}:vt_remote_out_height={height}:"
                       "vt_remote_hdr_to_sdr=1:vt_remote_bitrate=4000000:vt_remote_max_b_frames=0:"
                       "vt_remote_allow_sw=0:vt_remote_realtime=1")
                if seek:
                    bsf += ":vt_remote_start_time=0:vt_remote_end_time=1"
                run([args.ffmpeg, "-nostdin", "-v", "warning", *(["-ss", "2"] if seek else []),
                     "-i", str(sources[transfer]), *(["-t", "1"] if seek else []),
                     "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-copypriorss", "1",
                     *(["-bsf:a", "noise=amount=0:drop='lt(pts*tb,0)'"] if seek else []),
                     "-bsf:v", bsf, "-f", "matroska", "-live", "1", str(output)], name)
                info = probe(output, "-count_frames", "-show_streams", "-show_frames")
                video = next(s for s in info["streams"] if s["codec_type"] == "video")
                audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
                frames = [f for f in info["frames"] if f["media_type"] == "video"]
                count = 12 if seek else FRAMES
                assert int(video["nb_read_frames"]) == len(frames) == count, (name, "frame count", video)
                assert video["codec_name"] == codec, (name, "output codec")
                assert (video["width"], video["height"]) == (width, height), (name, "output dimensions")
                for key in ["color_space", "color_primaries", "color_transfer"]:
                    assert video[key] == "bt709", (name, key, video)
                assert video["color_range"] == "tv", (name, "range")
                assert video["pix_fmt"] == ("yuv420p10le" if pixel == 2 else "yuv420p"), (name, "precision")
                assert abs(float(video["start_time"]) - float(audio["start_time"])) <= 1 / FPS, (name, "A/V sync")
                times = [float(f["best_effort_timestamp_time"]) for f in frames]
                for i, pts in enumerate(times):
                    assert abs(pts - times[0] - i / FPS) < 0.002, (name, "timestamp", i, pts)
                assert frames[0]["key_frame"] == 1, (name, "seek keyframe")
                # Inspect stream, decoded-frame and compressed-packet metadata.
                packets = probe(output, "-select_streams", "v:0", "-show_packets")["packets"]
                for item in [video, *frames, *packets]:
                    for data in item.get("side_data_list", []):
                        kind = data["side_data_type"].lower()
                        assert not any(hdr in kind for hdr in ["mastering", "content light", "hdr", "dovi", "icc"]), (name, data)
                decoded = directory / f"{name}.yuv"
                run([args.fixture_ffmpeg, "-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
                     "-i", str(output), "-map", "0:v:0", "-pix_fmt", "yuv420p10le", "-f", "rawvideo", str(decoded)],
                    f"{name}-decode")
                pixels = array("H")
                pixels.frombytes(decoded.read_bytes())
                if sys.byteorder != "little":
                    pixels.byteswap()
                assert len(pixels) == count * width * height * 3 // 2, (name, "decoded size")
                bars = []
                for i in range(8):
                    samples = [pixels[y * width + x] for y in range(height // 4, height // 2)
                               for x in range(i * width // 8 + width // 32, (i + 1) * width // 8 - width // 32)]
                    bars.append(sum(samples) / len(samples))
                assert bars[0] < 80 and 890 < bars[-1] <= 950, (name, "SDR black/white", bars)
                assert all(b - a > 8 for a, b in zip(bars, bars[1:])), (name, "lost highlight detail", bars)
                print(f"PASS {name}: {count} frames, BT.709 SDR, no stale HDR metadata, luminance bars {list(map(round, bars))}", flush=True)
            preserved = directory / "hdr-preserved.mkv"
            run([args.ffmpeg, "-nostdin", "-v", "warning", "-i", str(sources["smpte2084"]),
                 "-map", "0:v:0", "-c:v", "copy", "-bsf:v",
                 f"vtremote_transcode=vt_remote_host={host}:vt_remote_port={port}:vt_remote_out_codec=hevc:"
                 "vt_remote_pix_fmt=2:vt_remote_bitrate=4000000:vt_remote_max_b_frames=0:vt_remote_hdr_to_sdr=0",
                 str(preserved)], "hdr-preserved")
            original = probe(preserved, "-select_streams", "v:0", "-count_frames", "-show_streams")["streams"][0]
            assert original["color_transfer"] == "smpte2084", original
            assert original["color_primaries"] == "bt2020" and original["color_space"] == "bt2020nc", original
            assert original["pix_fmt"] == "yuv420p10le" and int(original["nb_read_frames"]) == FRAMES, original
            print("PASS HDR-preserving packet transcode with tone mapping disabled", flush=True)
        finally:
            if daemon is not None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()


if __name__ == "__main__":
    main()
