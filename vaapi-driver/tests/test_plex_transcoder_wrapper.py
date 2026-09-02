#!/usr/bin/env python3
"""Unit tests for the narrow Plex Transcoder argument transformation."""

import argparse
import os
import subprocess
import tempfile


def run(wrapper, arguments, enabled=True, audit_file=None):
    environment = os.environ.copy()
    environment["VTREMOTE_PLEX_WRAPPER_TEST"] = "1"
    environment["VTREMOTE_PLEX_TRANSCODER_REAL"] = "/real/Plex Transcoder"
    if enabled:
        environment["VTREMOTE_PLEX_SOFTWARE_PIPELINE"] = "1"
    else:
        environment.pop("VTREMOTE_PLEX_SOFTWARE_PIPELINE", None)
    if audit_file is not None:
        environment["VTREMOTE_PLEX_AUDIT_FILE"] = audit_file
    result = subprocess.run(
        [wrapper, *arguments],
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout.splitlines(), result.stderr


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wrapper", required=True)
    args = parser.parse_args()

    plex_arguments = [
        "-codec:0", "h264",
        "-hwaccel:0", "vaapi",
        "-hwaccel_output_format:0", "vaapi",
        "-hwaccel_device:0", "vaapi",
        "-i", "/media/input.mkv",
        "-init_hw_device", "vaapi=vaapi:/dev/dri/renderD128,driver=iHD",
        "-filter_hw_device", "vaapi",
        "-filter_complex",
        "[0:0]hwupload[0];[0]scale_vaapi=w=720:h=300:format=nv12[1];[1]hwupload[2]",
        "-map", "[2]",
        "-codec:0", "h264_vaapi",
        "-filter_complex", "[0:1]aresample=async=1[3]",
        "-map", "[3]",
    ]

    with tempfile.TemporaryDirectory() as temp:
        audit_file = os.path.join(temp, "wrapper.log")
        code, output, error = run(args.wrapper, plex_arguments, audit_file=audit_file)
        assert code == 0, (code, output, error)
        with open(audit_file, encoding="utf-8") as handle:
            assert handle.read() == "software-decode-remote-encode\n"
    assert output == [
        "/real/Plex Transcoder",
        "-codec:0", "h264",
        "-i", "/media/input.mkv",
        "-init_hw_device", "vaapi=vaapi:/dev/dri/renderD128,driver=vtremote",
        "-filter_hw_device", "vaapi",
        "-filter_complex", "[0:0]scale=w=720:h=300,format=nv12,hwupload[2]",
        "-map", "[2]",
        "-codec:0", "h264_vaapi",
        "-filter_complex", "[0:1]aresample=async=1[3]",
        "-map", "[3]",
    ], output

    code, output, error = run(args.wrapper, plex_arguments, enabled=False)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *plex_arguments], output

    unsupported = [
        "-hwaccel:0", "vaapi",
        "-filter_complex", "[0:0]tonemap_vaapi=format=nv12[1]",
        "-codec:0", "h264_vaapi",
    ]
    code, output, error = run(args.wrapper, unsupported)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *unsupported], output

    mixed_graphs = [
        *plex_arguments,
        "-filter_complex", "[4]tonemap_vaapi=format=nv12[5]",
    ]
    code, output, error = run(args.wrapper, mixed_graphs)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *mixed_graphs], output

    missing_device = [
        "-hwaccel:0", "vaapi",
        "-filter_complex",
        "[0:0]hwupload[0];[0]scale_vaapi=w=720:h=300:format=nv12[1];[1]hwupload[2]",
        "-codec:0", "h264_vaapi",
    ]
    code, output, error = run(args.wrapper, missing_device)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *missing_device], output


if __name__ == "__main__":
    main()
