#!/usr/bin/env python3
"""Unit tests for the narrow Plex Transcoder argument transformation."""

import argparse
import os
import subprocess
import tempfile


def run(wrapper, arguments, enabled=True, audit_file=None,
        avcodec_version="60.31.102"):
    environment = os.environ.copy()
    environment["VTREMOTE_PLEX_WRAPPER_TEST"] = "1"
    environment["VTREMOTE_PLEX_TRANSCODER_REAL"] = "/real/Plex Transcoder"
    environment["VTREMOTE_HOST"] = "192.0.2.10"
    environment["VTREMOTE_PLEX_BSF_LIBRARY"] = "/opt/test/vtremote-plex-bsf.so"
    environment["VTREMOTE_PLEX_TEST_AVCODEC_VERSION"] = avcodec_version
    if enabled:
        environment["VTREMOTE_PLEX_REMOTE_TRANSCODE"] = "1"
    else:
        environment.pop("VTREMOTE_PLEX_REMOTE_TRANSCODE", None)
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
        "[0:0]scale=w=720:h=300:force_divisible_by=4[0];[0]format=pix_fmts=nv12[1];[1]hwupload[2]",
        "-map", "[2]",
        "-codec:0", "h264_vaapi",
        "-b:0", "1527000",
        "-maxrate:0", "1800000",
        "-bufsize:0", "3600000",
        "-g:0", "72",
        "-bf:0", "0",
        "-r:0", "24",
        "-rc_mode:0", "VBR",
        "-quality:0", "4",
        "-profile:0", "high",
        "-level:0", "4.1",
        "-coder:0", "cabac",
        "-sei:0", "a53_cc",
        "-force_key_frames:0", "expr:gte(t,n_forced*3)",
        "-filter_complex", "[0:1]aresample=async=1[3]",
        "-map", "[3]",
        "-b:1", "128000",
    ]

    with tempfile.TemporaryDirectory() as temp:
        audit_file = os.path.join(temp, "wrapper.log")
        code, output, error = run(args.wrapper, plex_arguments, audit_file=audit_file)
        assert code == 0, (code, output, error)
        assert not os.path.exists(audit_file)
    assert output == [
        "/real/Plex Transcoder",
        "-i", "/media/input.mkv",
        "-map", "0:0",
        "-codec:0", "copy",
        "-bsf:0",
        "vtremote_transcode=vt_remote_out_codec=h264:vt_remote_out_width=720:vt_remote_out_height=300:vt_remote_scale_mode=stretch:vt_remote_pix_fmt=1:vt_remote_decode_async=1:vt_remote_decode_reorder_depth=2:vt_remote_inflight=16:vt_remote_bitrate=1527000:vt_remote_maxrate=1800000:vt_remote_bufsize=3600000:vt_remote_gop=72:vt_remote_max_b_frames=0:vt_remote_profile=100:vt_remote_level=41:vt_remote_entropy=2:vt_remote_a53_cc=1:vt_remote_flags=2147483648",
        "-r:0", "24",
        "-filter_complex", "[0:1]aresample=async=1[3]",
        "-map", "[3]",
        "-b:1", "128000",
    ], output
    assert error == "LD_PRELOAD=/opt/test/vtremote-plex-bsf.so\n", error

    cbr_arguments = ["CBR" if value == "VBR" else value
                     for value in plex_arguments]
    code, cbr_output, error = run(args.wrapper, cbr_arguments)
    assert code == 0, (code, cbr_output, error)
    assert (
        ":vt_remote_constant_bit_rate=1:vt_remote_a53_cc=1"
        in cbr_output[cbr_output.index("-bsf:0") + 1]
    ), cbr_output

    inferred_cbr_arguments = list(plex_arguments)
    rc_index = inferred_cbr_arguments.index("-rc_mode:0")
    del inferred_cbr_arguments[rc_index:rc_index + 2]
    maxrate_index = inferred_cbr_arguments.index("-maxrate:0") + 1
    inferred_cbr_arguments[maxrate_index] = "1527k"
    code, inferred_cbr_output, error = run(args.wrapper,
                                           inferred_cbr_arguments)
    assert code == 0, (code, inferred_cbr_output, error)
    assert (
        ":vt_remote_constant_bit_rate=1:vt_remote_a53_cc=1"
        in inferred_cbr_output[inferred_cbr_output.index("-bsf:0") + 1]
    ), inferred_cbr_output

    cqp_arguments = ["CQP" if value == "VBR" else value
                     for value in plex_arguments]
    rc_index = cqp_arguments.index("-rc_mode:0")
    cqp_arguments[rc_index:rc_index] = ["-qp:0", "23"]
    code, cqp_output, error = run(args.wrapper, cqp_arguments)
    assert code == 0, (code, cqp_output, error)
    assert (
        ":vt_remote_global_quality=56:vt_remote_a53_cc=1"
        in cqp_output[cqp_output.index("-bsf:0") + 1]
    ), cqp_output

    code, output, error = run(args.wrapper, plex_arguments, enabled=False)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *plex_arguments], output

    code, output, error = run(
        args.wrapper, plex_arguments, avcodec_version="60.31.103"
    )
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

    unsupported_input = [
        "-codec:0", "av1",
        "-hwaccel:0", "vaapi",
        "-filter_complex",
        "[0:0]scale=w=720:h=300:force_divisible_by=4[0];[0]format=pix_fmts=nv12[1];[1]hwupload[2]",
        "-codec:0", "h264_vaapi",
    ]
    code, output, error = run(args.wrapper, unsupported_input)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *unsupported_input], output

    unsupported_keyframes = list(plex_arguments)
    force_index = unsupported_keyframes.index("-force_key_frames:0") + 1
    unsupported_keyframes[force_index] = "source"
    code, output, error = run(args.wrapper, unsupported_keyframes)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *unsupported_keyframes], output

    unsupported_profile = list(plex_arguments)
    profile_index = unsupported_profile.index("-profile:0") + 1
    unsupported_profile[profile_index] = "not-a-profile"
    code, output, error = run(args.wrapper, unsupported_profile)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *unsupported_profile], output

    indirect_graph = list(plex_arguments)
    graph_index = indirect_graph.index("-filter_complex") + 1
    indirect_graph[graph_index] = indirect_graph[graph_index].replace(
        "[0:0]scale", "[decoded]scale"
    )
    code, output, error = run(args.wrapper, indirect_graph)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *indirect_graph], output

    multiple_outputs = [*plex_arguments, "-codec:1", "hevc_vaapi"]
    code, output, error = run(args.wrapper, multiple_outputs)
    assert code == 2, (code, output, error)
    assert output == ["/real/Plex Transcoder", *multiple_outputs], output


if __name__ == "__main__":
    main()
