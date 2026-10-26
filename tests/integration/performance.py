#!/usr/bin/env python3
"""Reproducible Intel/software/VideoToolbox/NVENC performance comparisons.

Prepare and measure on the designated hosts. The coordinating computer only
dispatches jobs and collects results; it never encodes benchmark video.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import signal
import statistics
import subprocess
import sys
import time
import zipfile

BACKENDS = ("intel-vaapi", "cpu-fast", "cpu-medium", "videotoolbox", "videotoolbox-remote")
NVENC_BACKENDS = ("nvenc-p4", "nvenc-p7")
MAC_ENERGY_BACKENDS = ("videotoolbox",)
GPU_ENERGY_KEYS = ("gpu_board_joules", "gpu_board_average_watts", "gpu_board_frames_per_joule")
MAC_ENERGY_KEYS = ("mac_system_joules", "mac_system_average_watts", "mac_system_frames_per_joule")
FIXTURES = ("big-buck-bunny", "testsrc2", "smptebars")
BITRATES = {("h264", 720): 4_000_000, ("hevc", 720): 3_000_000,
            ("h264", 1080): 6_000_000, ("hevc", 1080): 4_000_000}
CALIBRATION_MEASUREMENT = "Whole-file bitrate reported by ffprobe; container overhead and codec filler included"
BBB_URL = "https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4.zip"
LABELS = {"intel-vaapi": "Intel iGPU VA-API", "cpu-fast": "CPU fast", "cpu-medium": "CPU medium",
          "videotoolbox": "VideoToolbox local", "videotoolbox-remote": "VideoToolbox remote",
          "nvenc-p4": "NVIDIA NVENC P4", "nvenc-p7": "NVIDIA NVENC P7"}


def public_results(summary):
    """Export a strict allowlist, never host inventory, paths or commands."""
    metadata = summary["metadata"]
    if metadata["frames"] != 1800 or metadata["repeats"] != 3 or metadata["warmup_frames"] != 60 or not summary["all_correct"]:
        raise ValueError("only complete, validated three-repeat comparisons can be published")
    if metadata["calibration_measurement"] != CALIBRATION_MEASUREMENT:
        raise ValueError("public results require the supported whole-file calibration method")
    backends = tuple(metadata["backends"])
    if backends not in (BACKENDS, NVENC_BACKENDS, MAC_ENERGY_BACKENDS):
        raise ValueError("public results require a complete measured comparison")
    expected = set(itertools.product(FIXTURES, ("h264", "hevc"), ("1280x720", "1920x1080"), backends))
    actual = [(row["fixture"], row["codec"], row["size"], row["backend"]) for row in summary["rows"]]
    if len(actual) != len(expected) or set(actual) != expected or not all(row["all_correct"] for row in summary["rows"]):
        raise ValueError("public comparison is incomplete or contains duplicate or invalid rows")
    if any(row["vmaf_frame_stride"] != 1 or row["vmaf_sampled_frames"] != metadata["frames"] for row in summary["rows"]):
        raise ValueError("public quality measurements must score every frame")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", metadata["release"]):
        raise ValueError("invalid public release identifier")
    keys = ("fixture", "codec", "size", "backend", "median_fps", "min_fps", "max_fps", "fps_cv_percent",
            "median_cpu_seconds", "median_peak_rss_bytes", "median_video_mbps", "median_file_bytes", "median_container_mbps",
            "median_filler_mbps", "target_mbps", "requested_mbps", "all_correct",
            "all_file_within_2_percent_target", "max_file_target_deviation_percent", "max_b_picture_frames", "max_decoder_reorder_frames",
            "max_gop_frames", "vmaf", "ssim", "vmaf_frame_stride", "vmaf_sampled_frames")
    repeat_keys = ("repeat", "output_sha256", "file_bytes", "duration_seconds", "container_mbps",
                   "video_mbps", "filler_mbps", "fps", "client_cpu_seconds", "correct")
    def public_repeat(repeat, energy_keys):
        allowed = repeat_keys + energy_keys
        result = {key: repeat[key] for key in allowed}
        if not re.fullmatch(r"[0-9a-f]{64}", result["output_sha256"]):
            raise ValueError("invalid public output hash")
        if type(result["correct"]) is not bool or not result["correct"]:
            raise ValueError("public repeats must pass validation")
        for key in set(allowed) - {"output_sha256", "correct"}:
            if isinstance(result[key], bool) or not isinstance(result[key], (int, float)) or not math.isfinite(result[key]) or result[key] < 0:
                raise ValueError("public repeat measurements must be finite nonnegative numbers")
        if any(result[key] <= 0 for key in ("repeat", "file_bytes", "duration_seconds", "fps") + energy_keys):
            raise ValueError("public timing, output size, and energy must be positive")
        return result

    rows = []
    for row in summary["rows"]:
        nvenc = row["backend"] in NVENC_BACKENDS
        energy_keys = GPU_ENERGY_KEYS if nvenc else MAC_ENERGY_KEYS if backends == MAC_ENERGY_BACKENDS else ()
        if energy_keys and row["fixture"] != "smptebars" and not row["all_file_within_2_percent_target"]:
            raise ValueError("moving energy measurements must match the common file budget")
        repeats = [public_repeat(repeat, energy_keys) for repeat in row["measured_repeats"]]
        if len(repeats) != 3 or [repeat["repeat"] for repeat in repeats] != [1, 2, 3]:
            raise ValueError("public rows need exactly three measured repeats")
        scored = public_repeat(row["scored_output"], energy_keys)
        if scored != repeats[0]:
            raise ValueError("quality must identify the first measured output")
        rows.append({**{key: row[key] for key in keys}, "label": LABELS[row["backend"]],
                     "comparison": "control" if row["fixture"] == "smptebars" else "common-bitrate-budget",
                     "scored_output": scored, "measured_repeats": repeats})
        if energy_keys:
            rows[-1].update({f"median_{key}": statistics.median(repeat[key] for repeat in repeats) for key in energy_keys})
    numeric_keys = set(keys) - {"fixture", "codec", "size", "backend", "all_correct", "all_file_within_2_percent_target"}
    for row in rows:
        if any(isinstance(row[key], bool) or not isinstance(row[key], (int, float)) or not math.isfinite(row[key]) for key in numeric_keys):
            raise ValueError("public measurements must be finite numbers")
        if type(row["all_correct"]) is not bool or type(row["all_file_within_2_percent_target"]) is not bool:
            raise ValueError("public validation fields must be boolean")
    fixtures = [{"id": name, "label": {"big-buck-bunny": "Big Buck Bunny", "testsrc2": "Moving testsrc2 signal", "smptebars": "Static SMPTE bars (control)"}[name]}
                for name in FIXTURES]
    outputs = [{"label": f"{'H.264 High' if codec == 'h264' else 'HEVC Main'} · {size.split('x')[1]}p",
                "codec": codec, "size": size} for codec, size in itertools.product(("h264", "hevc"), ("1280x720", "1920x1080"))]
    source_hashes = []
    builds = []
    for host in metadata["hosts"].values():
        for fixture in host["fixture_manifest"]["fixtures"]:
            if fixture["name"] not in FIXTURES or not re.fullmatch(r"[0-9a-f]{64}", fixture["sha256"]):
                raise ValueError("invalid public fixture identity")
            record = {"fixture": fixture["name"], "sha256": fixture["sha256"]}
            if record not in source_hashes:
                source_hashes.append(record)
        for key in ("native_ffmpeg", "remote_ffmpeg", "quality_ffmpeg"):
            info = host[key]
            match = re.match(r"ffmpeg version (git-\d{4}-\d{2}-\d{2}-[0-9a-f]+|n\d+\.\d+\.\d+-\d+-g[0-9a-f]+-\d{8}|\d+\.\d+(?:\.\d+|\.git)?(?:-\d+ubuntu[0-9.+a-z]+)?) ", info["version"])
            if not match or not re.fullmatch(r"[0-9a-f]{64}", info["sha256"]):
                raise ValueError("build identity needs a safe public version and hash")
            record = {"version": match[1], "sha256": info["sha256"]}
            if record not in builds:
                builds.append(record)
    scorer = next(build for build in builds if build["sha256"] == metadata["quality_scorer"]["sha256"])
    result = {"date": datetime.fromisoformat(metadata["created_at"]).date().isoformat() + " UTC",
            "release": metadata["release"], "fixtures": fixtures, "outputs": outputs,
            "source_hashes": source_hashes, "builds": builds, "quality_scorer": scorer,
            "frames": metadata["frames"], "repeats": metadata["repeats"],
            "warmup_frames": metadata["warmup_frames"], "vmaf_model": "vmaf_v0.6.1",
            "rate_control": "average/VBR, -bf 0 and zero frame reordering, 60-frame maximum GOP",
            "intel_hevc_picture_types": "Driver-required GPB B-slices use past references; no future references or frame reordering",
            "output_cost_scope": "physical output files including container overhead and every filler byte",
            "calibration_measurement": CALIBRATION_MEASUREMENT,
            "rows": rows}
    if backends == NVENC_BACKENDS:
        if len(metadata["hosts"]) != 1:
            raise ValueError("NVENC results require one measured host")
        host = next(iter(metadata["hosts"].values()))
        fields = [value.strip() for value in host["nvidia"].split(",")]
        if len(fields) != 4 or not re.fullmatch(r"NVIDIA GeForce RTX \d{4}(?: Ti| SUPER)?", fields[0]) or not re.fullmatch(r"\d{3}\.\d+\.\d+", fields[1]):
            raise ValueError("invalid public GPU model or driver version")
        limits = [float(value) for value in fields[2:]]
        if any(not math.isfinite(value) or value <= 0 for value in limits):
            raise ValueError("invalid GPU power limits")
        result["nvenc"] = {"gpu": fields[0], "driver": fields[1],
                           "power_limit_watts": limits[0], "default_power_limit_watts": limits[1],
                           "encoder": next(build for build in builds if build["sha256"] == host["native_ffmpeg"]["sha256"]),
                           "presets": ["p4", "p7"], "tuning": "hq", "multipass": "disabled",
                           "scaler": "scale_cuda bicubic", "power_scope": "GPU board, including idle; CPU and other system components excluded"}
        if "reference_gpu_activity_validation" in metadata:
            audit = metadata["reference_gpu_activity_validation"]
            audited = [repeat["output_sha256"] for row in rows
                       if row["fixture"] == "big-buck-bunny" and row["codec"] == "hevc"
                       and row["size"] == "1920x1080" for repeat in row["measured_repeats"]]
            if sorted(audit["output_sha256"]) != sorted(audited) or len(audited) != 6:
                raise ValueError("GPU activity validation must identify all six reference outputs")
            counts = ("telemetry_samples", "encoder_activity_samples", "unrelated_active_samples")
            if any(type(audit[key]) is not int or audit[key] < 0 for key in counts):
                raise ValueError("GPU activity validation needs nonnegative integer counts")
            if not audit["telemetry_samples"] or not audit["encoder_activity_samples"] or audit["unrelated_active_samples"]:
                raise ValueError("GPU activity validation requires observed encoder activity without unrelated activity")
            result["nvenc"]["reference_activity_validation"] = {
                "date": datetime.fromisoformat(audit["created_at"]).date().isoformat() + " UTC",
                "fixture": "big-buck-bunny", "codec": "hevc", "size": "1920x1080",
                "monitored_repeats": 6, "method": "NVML per-process SM, memory, encoder and decoder activity",
                "energy_counter_reads": "FFmpeg start and end only",
                **{key: audit[key] for key in counts}, "output_sha256": list(audit["output_sha256"])}
    if backends == MAC_ENERGY_BACKENDS:
        sampler = metadata["mac_power_sampler"]
        version = re.fullmatch(r"mactop version: v(\d+\.\d+\.\d+)", sampler["version"])
        if not version or not re.fullmatch(r"[0-9a-f]{64}", sampler["sha256"]):
            raise ValueError("invalid Mac power sampler identity")
        result["mac_power"] = {"sampler": {"version": version[1], "sha256": sampler["sha256"]},
                               "sensor": "SMC PSTR", "power_scope": "Mac system, including idle consumption"}
    return result


def append_nvenc_results(existing, addition):
    """Add a complete exported NVIDIA matrix to the retained measured data."""
    if "nvenc" not in addition:
        raise ValueError("only an exported NVENC comparison can be appended")
    expected = set(itertools.product(FIXTURES, ("h264", "hevc"), ("1280x720", "1920x1080"), BACKENDS))
    identities = [(row["fixture"], row["codec"], row["size"], row["backend"]) for row in existing["rows"]]
    if len(identities) != len(expected) or set(identities) != expected:
        raise ValueError("existing data must contain the complete original comparison exactly once")
    if existing["frames"] != addition["frames"] or existing["repeats"] != addition["repeats"]:
        raise ValueError("benchmark frame and repeat counts differ")
    scorer = addition["quality_scorer"]
    encoder = addition["nvenc"]["encoder"]
    sources = {record["fixture"]: record["sha256"] for record in addition["source_hashes"]}
    rows = [{**row, "measurement_date": addition["date"],
             "release": "FFmpeg " + encoder["version"].removeprefix("n").split("-")[0],
             "quality_scorer_sha256": scorer["sha256"], "encoding_build_sha256": encoder["sha256"],
             "source_sha256": sources[row["fixture"]]} for row in addition["rows"]]
    result = {**existing, "rows": [*existing["rows"], *rows],
              "nvenc": {**addition["nvenc"], "date": addition["date"], "source_hashes": addition["source_hashes"],
                        "calibration_measurement": addition["calibration_measurement"]}}
    moving = [(row, repeat) for row in result["rows"] if row["fixture"] != "smptebars"
              for repeat in row["measured_repeats"]]
    deviations = [abs(repeat["container_mbps"] / row["target_mbps"] - 1) * 100 for row, repeat in moving]
    result["original_file_budget_audit"] = existing["file_budget_audit"]
    result["file_budget_audit"] = {
        "measured_outputs": sum(len(row["measured_repeats"]) for row in result["rows"]),
        "moving_outputs": len(moving),
        "moving_outputs_within_2_percent_file_target": sum(deviation <= 2 for deviation in deviations),
        "moving_outputs_outside_2_percent_file_target": sum(deviation > 2 for deviation in deviations),
        "max_file_target_deviation_percent": max(deviations),
        "zero_filler_measured_outputs": sum(repeat["filler_mbps"] == 0 for row in result["rows"] for repeat in row["measured_repeats"]),
    }
    for key, records in (("builds", addition["builds"]), ("quality_scorers", [scorer])):
        result[key] = list(existing[key])
        for record in records:
            if record not in result[key]:
                result[key].append(record)
    return result


def append_mac_energy(existing, addition):
    """Attach independently measured Mac energy without relabelling prior results."""
    if "mac_power" not in addition or any(row["backend"] != "videotoolbox" for row in addition["rows"]):
        raise ValueError("Mac energy requires a complete exported VideoToolbox measurement")
    expected = set(itertools.product(FIXTURES, ("h264", "hevc"), ("1280x720", "1920x1080"), BACKENDS + NVENC_BACKENDS))
    identities = [(row["fixture"], row["codec"], row["size"], row["backend"]) for row in existing["rows"]]
    if len(identities) != len(expected) or set(identities) != expected:
        raise ValueError("Mac energy must be attached to the complete seven-pipeline comparison")
    if any(existing[key] != addition[key] for key in ("frames", "repeats", "warmup_frames", "vmaf_model")):
        raise ValueError("Mac energy and the retained comparison use different measurement settings")
    fixture_hashes = lambda records: {record["fixture"]: record["sha256"] for record in records}
    if fixture_hashes(existing["nvenc"]["source_hashes"]) != fixture_hashes(addition["source_hashes"]):
        raise ValueError("Mac energy and NVENC must use identical prepared inputs")
    fields = ("date", "frames", "repeats", "warmup_frames", "vmaf_model", "source_hashes",
              "builds", "quality_scorer", "calibration_measurement", "mac_power", "rows")
    return {**existing, "videotoolbox_energy": {key: addition[key] for key in fields}}


def identity(path):
    path = Path(path).resolve()
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path), "sha256": digest, "bytes": path.stat().st_size}


def capture(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def probe(ffprobe, path, count=False, pictures=False):
    command = [ffprobe, "-v", "error", "-select_streams", "v:0"]
    if count:
        command += ["-count_frames", "-count_packets"]
    if pictures:
        command += ["-show_frames", "-show_entries", "frame=key_frame,pict_type:stream:format"]
    command += ["-show_streams", "-show_format", "-of", "json", str(path)]
    return json.loads(capture(command))


def measure(command, log, env=None, gpu=None, mac_power=None):
    started = time.monotonic()
    with Path(log).open("w") as output:
        if gpu is not None:
            import pynvml
            energy_before = pynvml.nvmlDeviceGetTotalEnergyConsumption(gpu)
        process = subprocess.Popen(command, stdout=output, stderr=output, env=env)
        try:
            _, status, usage = os.wait4(process.pid, 0)
        except BaseException:
            process.terminate()
            process.wait()
            raise
        if gpu is not None:
            energy_after = pynvml.nvmlDeviceGetTotalEnergyConsumption(gpu)
    ended = time.monotonic()
    process.returncode = os.waitstatus_to_exitcode(status)
    result = {
        "elapsed_seconds": ended - started,
        "cpu_seconds": usage.ru_utime + usage.ru_stime,
        "peak_rss_bytes": usage.ru_maxrss * (1024 if platform.system() == "Linux" else 1),
        "exit_code": process.returncode,
    }
    if process.returncode:
        raise RuntimeError(f"command failed ({process.returncode}); inspect {log}")
    if gpu is not None:
        joules = (energy_after - energy_before) / 1000
        if joules <= 0:
            raise RuntimeError("GPU energy counter did not advance")
        result.update(gpu_board_joules=joules,
                      gpu_board_average_watts=joules / result["elapsed_seconds"])
    if mac_power is not None:
        result.update(mac_power.energy_between(started, ended))
    return result


def rapl():
    directory = Path("/sys/class/powercap/intel-rapl:0")
    if not directory.exists():
        return None
    return {"energy_uj": int((directory / "energy_uj").read_text()),
            "range_uj": int((directory / "max_energy_range_uj").read_text())}


def prepare(args):
    directory = args.workdir / "fixtures"
    directory.mkdir(exist_ok=False)
    archive = args.workdir / "downloads/bbb_sunflower_1080p_30fps_normal.mp4.zip"
    with zipfile.ZipFile(archive) as bundle:
        names = [name for name in bundle.namelist() if name.endswith(".mp4")]
        if len(names) != 1:
            raise RuntimeError("expected exactly one Big Buck Bunny MP4")
        # Extract the known media member only; do not unpack arbitrary paths.
        source = args.workdir / "downloads/big-buck-bunny.mp4"
        with source.open("xb") as output, bundle.open(names[0]) as media:
            import shutil
            shutil.copyfileobj(media, output)
    records = []
    for name in FIXTURES:
        output = directory / f"{name}.mkv"
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-v", "warning", "-xerror"]
        if name == "big-buck-bunny":
            command += ["-ss", "60", "-i", str(source), "-vf", "scale=1920:1080:flags=bicubic,format=yuv420p"]
        else:
            command += ["-f", "lavfi", "-i", f"{name}=size=1920x1080:rate=30"]
        command += ["-map", "0:v:0", "-an", "-sn", "-t", str(args.duration), "-r", "30",
                    "-c:v", "libx264", "-preset", "fast", "-crf", "10", "-pix_fmt", "yuv420p",
                    "-g", "60", "-bf", "2", "-color_range", "tv", "-colorspace", "bt709",
                    "-color_primaries", "bt709", "-color_trc", "bt709", str(output)]
        measure(command, directory / f"{name}.prepare.log")
        info = probe(args.ffprobe, output, count=True)
        frames = int(info["streams"][0]["nb_read_frames"])
        if frames != args.duration * 30:
            raise RuntimeError(f"fixture frame count mismatch: {name}: {frames}")
        records.append({"name": name, **identity(output), "frames": frames, "command": command,
                        "source": BBB_URL if name == "big-buck-bunny" else f"FFmpeg lavfi {name}",
                        "source_start_seconds": 60 if name == "big-buck-bunny" else 0})
    manifest = {"archive": identity(archive), "bbb_project": "https://peach.blender.org/",
                "credit": "Big Buck Bunny, Blender Foundation; Sunflower stereoscopic release, Blender Institute",
                "reference": "Software-decoded prepared H.264 High 8-bit fixtures, not uncompressed movie masters",
                "generator": identity(args.ffmpeg), "fixtures": records}
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest), flush=True)


def encoder_command(args, source, output):
    width, height = map(int, args.size.split("x"))
    bitrate = getattr(args, "bitrate", None) or BITRATES[(args.codec, height)]
    ffmpeg = args.remote_ffmpeg if args.backend == "videotoolbox-remote" else args.ffmpeg
    command = [ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-v", "info", "-xerror"]
    if args.backend == "intel-vaapi":
        command += ["-hwaccel", "vaapi", "-hwaccel_device", args.render_node,
                    "-hwaccel_output_format", "vaapi"]
    elif args.backend == "videotoolbox":
        command += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"]
    elif args.backend in NVENC_BACKENDS:
        command += ["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"]
    # Bound demuxing as well as output: older VA-API filter pools can exhaust
    # when downstream stops accepting frames but the input continues decoding.
    command += ["-t", str(args.frames / 30), "-i", str(source), "-map", "0:v:0", "-an", "-sn",
                "-frames:v", str(args.frames), "-fps_mode", "passthrough"]
    profile = "high" if args.codec == "h264" else "main"
    if args.backend == "videotoolbox-remote":
        bsf = (f"vtremote_transcode=vt_remote_host={args.server}:vt_remote_port={args.port}"
               f":vt_remote_out_codec={args.codec}:vt_remote_out_width={width}:vt_remote_out_height={height}"
               f":vt_remote_pix_fmt=1:vt_remote_bitrate={bitrate}:vt_remote_maxrate=0"
               f":vt_remote_gop=60:vt_remote_max_b_frames=0:vt_remote_constant_bit_rate=0"
               f":vt_remote_prio_speed=0:vt_remote_realtime=0:vt_remote_allow_sw=0"
               f":vt_remote_profile={100 if args.codec == 'h264' else 1}:vt_remote_inflight=32")
        command += ["-c:v", "copy", "-bsf:v", bsf]
    else:
        if args.backend == "intel-vaapi":
            command += ["-vf", f"scale_vaapi=w={width}:h={height}:format=nv12",
                        "-c:v", f"{args.codec}_vaapi", "-rc_mode", "VBR"]
        elif args.backend == "videotoolbox":
            command += ["-vf", f"scale_vt=w={width}:h={height}", "-c:v", f"{args.codec}_videotoolbox",
                        "-constant_bit_rate", "0", "-allow_sw", "0", "-realtime", "0", "-prio_speed", "0"]
        elif args.backend in NVENC_BACKENDS:
            command += ["-vf", f"scale_cuda=w={width}:h={height}:format=yuv420p:interp_algo=bicubic",
                        "-c:v", f"{args.codec}_nvenc", "-preset", args.backend.removeprefix("nvenc-"),
                        "-tune", "hq", "-rc", "vbr", "-multipass", "disabled"]
        else:
            preset = args.backend.removeprefix("cpu-")
            command += ["-vf", f"scale={width}:{height}:flags=bicubic,format=yuv420p",
                        "-c:v", "libx264" if args.codec == "h264" else "libx265", "-preset", preset,
                        "-pix_fmt", "yuv420p"]
            if args.codec == "h264":
                command += ["-x264-params", "scenecut=0:keyint=60:min-keyint=60"]
            else:
                command += ["-x265-params", "scenecut=0:keyint=60:min-keyint=60"]
        command += ["-profile:v", profile, "-b:v", str(bitrate), "-g", "60", "-bf", "0",
                    "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
    return command + [str(output)], bitrate


def quality(args, source, output, directory):
    width, height = map(int, args.size.split("x"))
    vmaf_log = directory / "vmaf.json"
    graph = (f"[0:v]trim=end_frame={args.frames},scale={width}:{height}:flags=bicubic,format=yuv420p,"
             "settb=AVTB,setpts=N/(30*TB),split=2[rv][rs];"
             "[1:v]format=yuv420p,settb=AVTB,setpts=N/(30*TB),split=2[dv][ds];"
             f"[dv][rv]libvmaf=model=version=vmaf_v0.6.1:n_threads=8:n_subsample=1:log_fmt=json:log_path={vmaf_log}[v];"
             "[ds][rs]ssim[s]")
    command = [args.quality_ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-v", "info", "-xerror",
               "-i", str(source), "-i", str(output), "-filter_complex", graph,
               "-map", "[v]", "-map", "[s]", "-f", "null", "-"]
    measure(command, directory / "quality.log")
    metrics = json.loads(vmaf_log.read_text())
    ssim = re.search(r"SSIM .* All:([0-9.]+)", (directory / "quality.log").read_text())
    if not ssim or len(metrics["frames"]) != args.frames:
        raise RuntimeError(f"quality metrics incomplete: {directory}")
    return {"vmaf": metrics["pooled_metrics"]["vmaf"]["mean"], "ssim": float(ssim[1]),
            "vmaf_frame_stride": 1, "vmaf_sampled_frames": len(metrics["frames"]),
            "model": "vmaf_v0.6.1", "command": command}


def filler_rate(args, output, directory, original_packets):
    """Diagnose filler on a separate copy; retain all bytes in reported output cost."""
    stripped = directory / "without-filler.mkv"
    bsf = "h264_metadata=delete_filler=1" if args.codec == "h264" else "filter_units=remove_types=38"
    measure([args.quality_ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-xerror",
             "-i", str(output), "-map", "0:v:0", "-c:v", "copy", "-bsf:v", bsf,
             str(stripped)], directory / "remove-filler.log")
    packets = json.loads(capture([args.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
                                 "-show_entries", "packet=size", "-of", "json", str(stripped)]))["packets"]
    before = sum(int(packet["size"]) for packet in original_packets)
    after = sum(int(packet["size"]) for packet in packets)
    if len(packets) != len(original_packets) or after > before:
        raise RuntimeError("filler removal changed packet counts or added encoded bytes")
    return (before - after) * 8 / (args.frames / 30)


def quality_worker(args):
    source = args.workdir / "fixtures" / f"{args.fixture}.mkv"
    directory = args.workdir / "quality" / args.run_id
    directory.mkdir(parents=True, exist_ok=False)
    if identity(args.input)["sha256"] != args.sha256:
        raise RuntimeError("copied output identity differs from the measured output")
    result = quality(args, source, args.input, directory)
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


def worker(args):
    source = args.workdir / "fixtures" / f"{args.fixture}.mkv"
    directory = args.workdir / "runs" / args.run_id
    directory.mkdir(parents=True, exist_ok=False)
    output = directory / "output.mkv"
    command, requested_bitrate = encoder_command(args, source, output)
    target_bitrate = BITRATES[(args.codec, int(args.size.split("x")[1]))]
    env = os.environ.copy()
    if args.backend == "intel-vaapi":
        env["LIBVA_DRIVER_NAME"] = "iHD"
    gpu = None
    if args.backend in NVENC_BACKENDS:
        import pynvml
        pynvml.nvmlInit()
        gpu = pynvml.nvmlDeviceGetHandleByIndex(0)
    before = rapl() if args.backend not in NVENC_BACKENDS else None
    try:
        if args.backend == "videotoolbox" and args.mac_power_tool:
            from mac_power import MacPowerSampler
            with MacPowerSampler(args.mac_power_tool, directory) as sampler:
                usage = measure(command, directory / "encode.log", env=env, mac_power=sampler)
            usage["mac_system_frames_per_joule"] = args.frames / usage["mac_system_joules"]
        else:
            usage = measure(command, directory / "encode.log", env=env, gpu=gpu)
    finally:
        if gpu is not None:
            pynvml.nvmlShutdown()
    if gpu is not None:
        usage["gpu_board_frames_per_joule"] = args.frames / usage["gpu_board_joules"]
    after = rapl() if args.backend not in NVENC_BACKENDS else None
    if before and after:
        usage["intel_package_joules"] = ((after["energy_uj"] - before["energy_uj"]) % before["range_uj"]) / 1_000_000
    info = probe(args.ffprobe, output, count=True, pictures=True)
    stream = info["streams"][0]
    packets = json.loads(capture([args.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_packets",
                                  "-show_entries", "packet=size,pts_time,dts_time", "-of", "json", str(output)]))["packets"]
    timestamps = [float(packet["dts_time"]) for packet in packets]
    frames = int(stream["nb_read_frames"])
    pictures = info["frames"]
    keyframes = [index for index, frame in enumerate(pictures) if frame["key_frame"]]
    b_pictures = sum(frame["pict_type"] == "B" for frame in pictures)
    longest_gop = max(second - first for first, second in zip(keyframes, [*keyframes[1:], frames])) if keyframes else frames
    intel_gpb = args.backend == "intel-vaapi" and args.codec == "hevc"
    width, height = map(int, args.size.split("x"))
    correct = (frames == args.frames and len(packets) == args.frames and stream["codec_name"] == args.codec
               and stream["width"] == width and stream["height"] == height
               and stream["profile"] == ("High" if args.codec == "h264" else "Main")
               and stream["pix_fmt"] == "yuv420p"
               and len(pictures) == frames and bool(keyframes) and keyframes[0] == 0 and longest_gop <= 60
               and stream["has_b_frames"] == 0 and (b_pictures == 0 or intel_gpb)
               and all(packet["pts_time"] == packet["dts_time"] for packet in packets)
               and all(second > first for first, second in zip(timestamps, timestamps[1:])))
    if not correct:
        raise RuntimeError(f"media validation failed: {directory}")
    measure([args.quality_ffmpeg, "-v", "error", "-nostdin", "-xerror", "-i", str(output), "-map", "0:v:0", "-f", "null", "-"], directory / "decode.log")
    delivered = sum(int(packet["size"]) for packet in packets) * 8 / (args.frames / 30)
    filler = filler_rate(args, output, directory, packets)
    container_bitrate = int(info["format"]["bit_rate"])
    result = {"backend": args.backend, "codec": args.codec, "fixture": args.fixture, "size": args.size,
              "run_id": args.run_id, "host": platform.node(), "frames": frames, "correct": correct,
              "b_picture_frames": b_pictures, "decoder_reorder_frames": stream["has_b_frames"],
              "gop_frames": longest_gop,
              "target_bitrate": target_bitrate, "requested_bitrate": requested_bitrate,
              "delivered_bitrate": delivered,
              "container_bitrate": container_bitrate, "duration_seconds": float(info["format"]["duration"]),
              "filler_bitrate": filler,
              "file_within_2_percent_target": abs(container_bitrate / target_bitrate - 1) <= 0.02,
              "fps": frames / usage["elapsed_seconds"], "usage": usage,
              "output": identity(output), "source": identity(source), "command": command,
              "output_stream": {key: stream.get(key) for key in ("codec_name", "profile", "pix_fmt", "color_range", "color_space", "color_transfer", "color_primaries")}}
    if args.quality:
        result["quality"] = quality(args, source, output, directory)
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


def serve(args):
    log_path = args.workdir / f"daemon-{time.time_ns()}.log"
    with log_path.open("x") as log:
        process = subprocess.Popen([args.daemon, "--listen", f"{args.server}:{args.port}", "--max-sessions", "2", "--log-level", "1"], stdout=log, stderr=log)
        import socket
        try:
            deadline = time.monotonic() + 10
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"benchmark daemon exited; inspect {log_path}")
                try:
                    with socket.create_connection((args.server, args.port), 0.2):
                        break
                except OSError:
                    if time.monotonic() > deadline:
                        raise RuntimeError("benchmark daemon did not listen")
                    time.sleep(0.1)
            print(json.dumps({"ready": True, "pid": process.pid, "log": str(log_path), "daemon": identity(args.daemon), "version": capture([args.daemon, "--version"])}), flush=True)
            sys.stdin.readline()
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                _, status, usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
                print(json.dumps({"cpu_seconds": usage.ru_utime + usage.ru_stime, "peak_rss_bytes": usage.ru_maxrss, "exit_code": process.returncode}), flush=True)


def remote_command(host, argv):
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, shlex.join(argv)]


def local_suite(args):
    """Measure local hardware pipelines; staging and SSH are outside timed work."""
    backends = args.local_backends
    args.output.mkdir(parents=True, exist_ok=False)
    common = [sys.executable, str(Path(__file__).resolve()), "--workdir", str(args.workdir)]
    tools = ["--ffmpeg", args.ffmpeg, "--remote-ffmpeg", args.ffmpeg,
             "--quality-ffmpeg", args.quality_ffmpeg, "--ffprobe", args.ffprobe]
    information = json.loads(capture([*common, "inventory", *tools, *(["--nvidia"] if backends == NVENC_BACKENDS else [])]))
    metadata = {"created_at": datetime.now(timezone.utc).isoformat(), "release": args.release,
                "hosts": {platform.node(): information}, "frames": args.frames,
                "repeats": args.repeats, "warmup_frames": args.warmup_frames,
                "fixtures": args.fixtures, "codecs": args.codecs, "sizes": args.sizes,
                "backends": list(backends), "quality_scorer": information["quality_ffmpeg"],
                "calibration_measurement": CALIBRATION_MEASUREMENT,
                "method": "Local NVDEC, bicubic scale_cuda, NVENC P4/P7 HQ VBR single-pass; zero B frames, 60-frame maximum GOP; whole-file calibration; sequential rotating repeats; full-frame VMAF/SSIM on first repeat",
                "power_scope": "NVML cumulative GPU-board energy during the complete FFmpeg transcode; includes board idle consumption; excludes CPU and other system components"}
    if backends == MAC_ENERGY_BACKENDS:
        metadata["method"] = "Local hardware VideoToolbox decode, scale_vt, hardware VBR encoding; zero B frames, 60-frame maximum GOP; whole-file calibration; sequential repeats; full-frame VMAF/SSIM on first repeat"
        metadata["power_scope"] = "SMC PSTR whole-Mac power integrated during the complete FFmpeg transcode, including idle consumption"
        metadata["mac_power_sampler"] = {**identity(args.mac_power_tool), "version": capture([args.mac_power_tool, "--version"])}
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    runs = []
    cases = list(itertools.product(args.fixtures, args.codecs, args.sizes))
    for case_index, (fixture, codec, size) in enumerate(cases):
        requested_rates = {backend: BITRATES[(codec, int(size.split("x")[1]))] for backend in backends}

        def run_job(backend, run_id, frames, with_quality=False):
            command = [*common, "worker", *tools, "--backend", backend, "--codec", codec,
                       "--fixture", fixture, "--size", size, "--frames", str(frames),
                       "--run-id", run_id, "--bitrate", str(requested_rates[backend])]
            if with_quality:
                command.append("--quality")
            if backends == MAC_ENERGY_BACKENDS:
                command += ["--mac-power-tool", args.mac_power_tool]
            with (args.output / f"{run_id}.worker.log").open("w") as log:
                return json.loads(capture(command, stderr=log))

        if fixture != "smptebars":
            for backend in backends:
                for attempt in range(4):
                    run_id = f"{args.output.name}-{fixture}-{codec}-{size}-{backend}-cal{attempt}"
                    print(f"PERFORMANCE calibration={case_index + 1}/{len(cases)} attempt={attempt + 1} {backend} {fixture} {codec} {size}", flush=True)
                    result = run_job(backend, run_id, args.frames)
                    with (args.output / "calibration.jsonl").open("a") as stream:
                        stream.write(json.dumps(result) + "\n")
                    ratio = result["container_bitrate"] / result["target_bitrate"]
                    if abs(ratio - 1) <= 0.02:
                        break
                    requested_rates[backend] = round(requested_rates[backend] / ratio)
                else:
                    raise RuntimeError(f"could not match whole-file bitrate: {fixture} {codec} {size} {backend}")
        for repeat in range(args.repeats + 1):
            order = list(backends)
            if (case_index + max(repeat - 1, 0)) % 2:
                order.reverse()
            for backend in order:
                run_id = f"{args.output.name}-{fixture}-{codec}-{size}-{backend}-r{repeat}"
                print(f"PERFORMANCE case={case_index + 1}/{len(cases)} repeat={repeat}/{args.repeats} {backend} {fixture} {codec} {size}", flush=True)
                result = run_job(backend, run_id, args.warmup_frames if repeat == 0 else args.frames, repeat == 1)
                if repeat and fixture != "smptebars" and not result["file_within_2_percent_target"]:
                    raise RuntimeError(f"whole-file bitrate outside 2% comparison tolerance: {run_id}")
                result["repeat"] = repeat
                with (args.output / "runs.jsonl").open("a") as stream:
                    stream.write(json.dumps(result) + "\n")
                if repeat:
                    runs.append(result)
    summary = summarize(metadata, runs)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"PERFORMANCE complete rows={len(summary['rows'])} all_correct={summary['all_correct']}", flush=True)


def suite(args):
    args.output.mkdir(parents=True, exist_ok=False)
    script = str(args.workdir / "performance.py")
    python_mac = "/opt/homebrew/bin/python3"
    binary = str(args.workdir / "bin" / "ffmpeg")
    native_linux = str(args.workdir / "native-bin" / "ffmpeg")
    common = [script, "--workdir", str(args.workdir), "--server", args.server, "--port", str(args.port)]
    server_log = (args.output / "server-ssh.log").open("w")
    server = subprocess.Popen(remote_command(args.mac_host, [python_mac, *common, "serve", "--daemon", str(args.workdir / "vtremoted/vtremoted")]), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=server_log, text=True)
    try:
        ready_line = server.stdout.readline()
        if not ready_line:
            raise RuntimeError("could not start Mac benchmark daemon; inspect server-ssh.log")
        ready = json.loads(ready_line)
        if ready["version"] != f"vtremoted {args.release.removeprefix('v')}":
            raise RuntimeError("daemon version does not match the requested benchmark release")
        host_info = {}
        for host, py in ((args.linux_host, "python3"), (args.mac_host, python_mac)):
            native_mac = "/opt/homebrew/bin/ffmpeg"
            host_info[host] = json.loads(capture(remote_command(host, [py, *common, "inventory", "--ffmpeg", native_linux if host == args.linux_host else "/opt/homebrew/bin/ffmpeg",
                                                                       "--remote-ffmpeg", binary if host == args.linux_host else native_mac,
                                                                       "--ffprobe", str(args.workdir / "bin/ffprobe") if host == args.linux_host else "/opt/homebrew/bin/ffprobe",
                                                                       "--quality-ffmpeg", binary if host == args.linux_host else "/opt/homebrew/bin/ffmpeg"])))
        fixture_hashes = [{item["name"]: item["sha256"] for item in info["fixture_manifest"]["fixtures"]} for info in host_info.values()]
        if fixture_hashes[0] != fixture_hashes[1]:
            raise RuntimeError("Intel and Mac fixtures differ; refusing the comparison")
        metadata = {"created_at": datetime.now(timezone.utc).isoformat(), "release": args.release, "server": ready,
                    "hosts": host_info, "method": f"Sequential full-video pipelines; average/VBR on every backend; common -bf 0 and zero frame reordering, with driver-required past-reference GPB slices on Intel HEVC; 60-frame maximum GOP; identical byte-only full-clip calibration for every moving-video backend; whole-file bitrate within 2%; {args.warmup_frames}-frame warm-up and {args.repeats} rotating measured repeats; static bars are a control; VMAF and SSIM over every frame on one common Linux scorer on the first measured repeat",
                    "calibration_measurement": CALIBRATION_MEASUREMENT,
                    "quality_scorer": host_info[args.linux_host]["quality_ffmpeg"],
                    "frames": args.frames, "warmup_frames": args.warmup_frames, "repeats": args.repeats,
                    "sizes": args.sizes, "fixtures": args.fixtures, "codecs": args.codecs, "backends": args.backends,
                    "power_scope": "Intel package RAPL includes other host work; no wall power or Mac power measurement"}
        (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        capture(remote_command(args.linux_host, ["mkdir", "-p", str(args.workdir / "quality")]))
        runs = []
        cases = list(itertools.product(args.fixtures, args.codecs, args.sizes))
        for case_index, (fixture, codec, size) in enumerate(cases):
            requested_rates = {backend: BITRATES[(codec, int(size.split("x")[1]))] for backend in args.backends}

            def run_job(backend, run_id, frames, with_quality=False):
                host = args.mac_host if backend == "videotoolbox" else args.linux_host
                py = python_mac if host == args.mac_host else "python3"
                command = [py, *common, "worker", "--backend", backend, "--codec", codec, "--fixture", fixture,
                           "--size", size, "--frames", str(frames), "--run-id", run_id,
                           "--bitrate", str(requested_rates[backend]),
                           "--ffmpeg", "/opt/homebrew/bin/ffmpeg" if host == args.mac_host else native_linux, "--remote-ffmpeg", binary,
                           "--ffprobe", str(args.workdir / "bin/ffprobe") if host == args.linux_host else "/opt/homebrew/bin/ffprobe",
                           "--quality-ffmpeg", "/opt/homebrew/bin/ffmpeg" if host == args.mac_host else binary]
                if with_quality and host == args.linux_host:
                    command += ["--quality"]
                with (args.output / f"{run_id}.ssh.log").open("w") as log:
                    result = json.loads(capture(remote_command(host, command), stderr=log))
                if with_quality and host == args.mac_host:
                    copied = args.workdir / "quality" / f"{run_id}.mkv"
                    subprocess.run(["scp", "-3", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                    f"{args.mac_host}:{result['output']['path']}",
                                    f"{args.linux_host}:{copied}"], check=True)
                    quality_command = ["python3", *common, "quality", "--input", str(copied),
                                       "--sha256", result["output"]["sha256"], "--fixture", fixture,
                                       "--size", size, "--frames", str(frames), "--run-id", run_id,
                                       "--quality-ffmpeg", binary]
                    with (args.output / f"{run_id}.quality.ssh.log").open("w") as log:
                        result["quality"] = json.loads(capture(remote_command(args.linux_host, quality_command), stderr=log))
                return result

            # Calibrate actual whole-file rate on the complete clip before timing.
            # Static bars are a control: sparse encoders may not fill a budget.
            if fixture != "smptebars":
                for backend in args.backends:
                    for attempt in range(4):
                        run_id = f"{args.output.name}-{fixture}-{codec}-{size}-{backend}-cal{attempt}"
                        print(f"PERFORMANCE calibration={case_index + 1}/{len(cases)} attempt={attempt + 1} {backend} {fixture} {codec} {size}", flush=True)
                        result = run_job(backend, run_id, args.frames)
                        with (args.output / "calibration.jsonl").open("a") as stream:
                            stream.write(json.dumps(result) + "\n")
                        ratio = result["container_bitrate"] / result["target_bitrate"]
                        if abs(ratio - 1) <= 0.02:
                            break
                        requested_rates[backend] = round(requested_rates[backend] / ratio)
                    else:
                        raise RuntimeError(f"could not match whole-file bitrate for {fixture} {codec} {size} {backend}")
            for repeat in range(args.repeats + 1):
                order = list(args.backends)
                offset = (case_index + max(repeat - 1, 0)) % len(order)
                order = order[offset:] + order[:offset]
                for backend in order:
                    run_id = f"{args.output.name}-{fixture}-{codec}-{size}-{backend}-r{repeat}"
                    print(f"PERFORMANCE case={case_index + 1}/{len(cases)} repeat={repeat}/{args.repeats} {backend} {fixture} {codec} {size}", flush=True)
                    result = run_job(backend, run_id, args.warmup_frames if repeat == 0 else args.frames, repeat == 1)
                    if repeat and fixture != "smptebars" and not result["file_within_2_percent_target"]:
                        raise RuntimeError(f"whole-file bitrate outside 2% comparison tolerance: {run_id}")
                    result["repeat"] = repeat
                    with (args.output / "runs.jsonl").open("a") as stream:
                        stream.write(json.dumps(result) + "\n")
                    if repeat:
                        runs.append(result)
        summary = summarize(metadata, runs)
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"PERFORMANCE complete rows={len(summary['rows'])} all_correct={summary['all_correct']} output={args.output}", flush=True)
    finally:
        if server.poll() is None:
            server.stdin.write("stop\n")
            server.stdin.flush()
            server.stdin.close()
        server.stdin = None
        server_output, _ = server.communicate(timeout=30)
        (args.output / "server-final.json").write_text(server_output)
        server_log.close()


def summarize(metadata, runs):
    """Aggregate validated measured runs, including preserved completed cases."""
    source_hashes = {fixture: {record["sha256"] for host in metadata["hosts"].values()
                               for record in host["fixture_manifest"]["fixtures"] if record["name"] == fixture}
                     for fixture in metadata["fixtures"]}
    if any(len(hashes) != 1 for hashes in source_hashes.values()):
        raise ValueError("fixture identities differ between the measured hosts")
    rows = []
    for fixture, codec, size, backend in itertools.product(metadata["fixtures"], metadata["codecs"], metadata["sizes"], metadata["backends"]):
        group = [run for run in runs if (run["fixture"], run["codec"], run["size"], run["backend"]) == (fixture, codec, size, backend)]
        if len(group) != metadata["repeats"] or {run["repeat"] for run in group} != set(range(1, metadata["repeats"] + 1)):
            raise ValueError("each case needs exactly the configured measured repeats")
        if any(run["frames"] != metadata["frames"] or not run["correct"] for run in group):
            raise ValueError("measured runs failed media validation")
        if any(run["source"]["sha256"] not in source_hashes[fixture] for run in group):
            raise ValueError("a measured run used a different input from the recorded fixture")
        rates = [run["fps"] for run in group]
        scored_run = next(run for run in group if run["repeat"] == 1)
        measured_quality = scored_run["quality"]
        repeats = [{"repeat": run["repeat"], "output_sha256": run["output"]["sha256"],
                    "file_bytes": run["output"]["bytes"], "duration_seconds": run["duration_seconds"],
                    "container_mbps": run["container_bitrate"] / 1_000_000,
                    "video_mbps": run["delivered_bitrate"] / 1_000_000,
                    "filler_mbps": run["filler_bitrate"] / 1_000_000, "fps": run["fps"],
                    "client_cpu_seconds": run["usage"]["cpu_seconds"], "correct": run["correct"]}
                   for run in sorted(group, key=lambda run: run["repeat"])]
        energy_keys = GPU_ENERGY_KEYS if backend in NVENC_BACKENDS else MAC_ENERGY_KEYS if "mac_system_joules" in group[0]["usage"] else ()
        if energy_keys:
            for repeat, run in zip(repeats, sorted(group, key=lambda run: run["repeat"])):
                repeat.update({key: run["usage"][key] for key in energy_keys})
        rows.append({"fixture": fixture, "codec": codec, "size": size, "backend": backend,
                     "median_fps": statistics.median(rates), "min_fps": min(rates), "max_fps": max(rates),
                     "fps_cv_percent": statistics.stdev(rates) / statistics.mean(rates) * 100 if len(rates) > 1 else 0,
                     "median_cpu_seconds": statistics.median(run["usage"]["cpu_seconds"] for run in group),
                     "median_peak_rss_bytes": statistics.median(run["usage"]["peak_rss_bytes"] for run in group),
                     "median_video_mbps": statistics.median(run["delivered_bitrate"] for run in group) / 1_000_000,
                     "median_file_bytes": statistics.median(run["output"]["bytes"] for run in group),
                     "median_container_mbps": statistics.median(run["container_bitrate"] for run in group) / 1_000_000,
                     "median_filler_mbps": statistics.median(run["filler_bitrate"] for run in group) / 1_000_000,
                     "target_mbps": group[0]["target_bitrate"] / 1_000_000,
                     "requested_mbps": group[0]["requested_bitrate"] / 1_000_000,
                     "all_correct": all(run["correct"] for run in group),
                     "all_file_within_2_percent_target": all(run["file_within_2_percent_target"] for run in group),
                     "max_file_target_deviation_percent": max(abs(run["container_bitrate"] / run["target_bitrate"] - 1) * 100 for run in group),
                     "max_b_picture_frames": max(run["b_picture_frames"] for run in group),
                     "max_decoder_reorder_frames": max(run["decoder_reorder_frames"] for run in group),
                     "max_gop_frames": max(run["gop_frames"] for run in group),
                     "scored_output": repeats[0], "measured_repeats": repeats,
                     **{key: measured_quality[key] for key in ("vmaf", "ssim", "vmaf_frame_stride", "vmaf_sampled_frames")}})
    return {"metadata": metadata, "rows": rows, "all_correct": all(row["all_correct"] for row in rows)}


def inventory(args):
    information = {"host": platform.node(), "platform": platform.platform(), "cpu_count": os.cpu_count(), "load_average": os.getloadavg()}
    if platform.system() == "Darwin":
        information["hardware"] = capture(["/usr/sbin/sysctl", "-n", "hw.model", "hw.memsize", "machdep.cpu.brand_string"])
    else:
        information["hardware"] = capture(["lscpu", "--json"])
        if args.nvidia:
            information["nvidia"] = capture(["nvidia-smi", "--query-gpu=name,driver_version,power.limit,power.default_limit",
                                              "--format=csv,noheader,nounits"])
        else:
            information["vaapi"] = capture(["vainfo", "--display", "drm", "--device", args.render_node], stderr=subprocess.STDOUT)
    for label, path in (("native_ffmpeg", args.ffmpeg), ("remote_ffmpeg", args.remote_ffmpeg), ("quality_ffmpeg", args.quality_ffmpeg), ("ffprobe", args.ffprobe)):
        information[label] = {**identity(path), "version": capture([path, "-version"])}
    information["fixture_manifest"] = json.loads((args.workdir / "fixtures/manifest.json").read_text())
    for fixture in information["fixture_manifest"]["fixtures"]:
        actual = identity(args.workdir / "fixtures" / f"{fixture['name']}.mkv")
        if actual["sha256"] != fixture["sha256"]:
            raise ValueError("prepared input no longer matches its recorded SHA-256")
    print(json.dumps(information), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workdir", type=Path, required=True)
    parser.add_argument("--server", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5569)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--duration", type=int, default=60)
    prepare_parser.add_argument("--ffmpeg", default="/usr/bin/ffmpeg")
    prepare_parser.add_argument("--ffprobe", default="/usr/bin/ffprobe")
    for name in ("worker", "inventory"):
        job = commands.add_parser(name)
        job.add_argument("--ffmpeg", required=True)
        job.add_argument("--remote-ffmpeg", required=True)
        job.add_argument("--quality-ffmpeg", required=True)
        job.add_argument("--ffprobe", default="/usr/bin/ffprobe")
        job.add_argument("--render-node", default="/dev/dri/renderD128")
        if name == "inventory":
            job.add_argument("--nvidia", action="store_true")
        if name == "worker":
            job.add_argument("--mac-power-tool", help="Installed mactop binary for SMC system-power sampling")
            job.add_argument("--backend", choices=BACKENDS + NVENC_BACKENDS, required=True)
            job.add_argument("--codec", choices=("h264", "hevc"), required=True)
            job.add_argument("--fixture", choices=FIXTURES, required=True)
            job.add_argument("--size", choices=("1280x720", "1920x1080"), required=True)
            job.add_argument("--frames", type=int, required=True)
            job.add_argument("--run-id", required=True)
            job.add_argument("--bitrate", type=int)
            job.add_argument("--quality", action="store_true")
    server = commands.add_parser("serve")
    server.add_argument("--daemon", required=True)
    quality_parser = commands.add_parser("quality")
    quality_parser.add_argument("--input", type=Path, required=True)
    quality_parser.add_argument("--sha256", required=True)
    quality_parser.add_argument("--fixture", choices=FIXTURES, required=True)
    quality_parser.add_argument("--size", choices=("1280x720", "1920x1080"), required=True)
    quality_parser.add_argument("--frames", type=int, required=True)
    quality_parser.add_argument("--run-id", required=True)
    quality_parser.add_argument("--quality-ffmpeg", required=True)
    run = commands.add_parser("suite")
    run.add_argument("--linux-host", required=True)
    run.add_argument("--mac-host", required=True)
    run.add_argument("--release", required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--frames", type=int, default=1800)
    run.add_argument("--warmup-frames", type=int, default=60)
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--fixtures", nargs="+", choices=FIXTURES, default=list(FIXTURES))
    run.add_argument("--codecs", nargs="+", choices=("h264", "hevc"), default=["h264", "hevc"])
    run.add_argument("--sizes", nargs="+", choices=("1280x720", "1920x1080"), default=["1280x720", "1920x1080"])
    run.add_argument("--backends", nargs="+", choices=BACKENDS, default=list(BACKENDS))
    for name, backends in (("nvenc-suite", NVENC_BACKENDS), ("videotoolbox-energy", MAC_ENERGY_BACKENDS)):
        local = commands.add_parser(name)
        local.set_defaults(local_backends=backends)
        local.add_argument("--ffmpeg", required=True)
        local.add_argument("--ffprobe", required=True)
        local.add_argument("--quality-ffmpeg", required=True)
        local.add_argument("--release", required=True)
        local.add_argument("--output", type=Path, required=True)
        local.add_argument("--frames", type=int, default=1800)
        local.add_argument("--warmup-frames", type=int, default=60)
        local.add_argument("--repeats", type=int, default=3)
        local.add_argument("--fixtures", nargs="+", choices=FIXTURES, default=list(FIXTURES))
        local.add_argument("--codecs", nargs="+", choices=("h264", "hevc"), default=["h264", "hevc"])
        local.add_argument("--sizes", nargs="+", choices=("1280x720", "1920x1080"), default=["1280x720", "1920x1080"])
        if backends == MAC_ENERGY_BACKENDS:
            local.add_argument("--mac-power-tool", required=True)
    public = commands.add_parser("public-results")
    public.add_argument("--input", type=Path, required=True)
    public.add_argument("--append-to", type=Path)
    public.add_argument("--output", type=Path)
    args = parser.parse_args()
    if getattr(args, "frames", 1) <= 0 or getattr(args, "repeats", 1) <= 0:
        parser.error("frames and repeats must be positive")
    if args.command == "public-results":
        result = public_results(json.loads(args.input.read_text()))
        if args.append_to:
            existing = json.loads(args.append_to.read_text())
            result = append_mac_energy(existing, result) if "mac_power" in result else append_nvenc_results(existing, result)
        serialized = json.dumps(result, indent=2) + "\n"
        if args.output:
            args.output.write_text(serialized)
        else:
            print(serialized, end="")
        return
    {"prepare": prepare, "worker": worker, "quality": quality_worker,
     "serve": serve, "suite": suite, "nvenc-suite": local_suite, "videotoolbox-energy": local_suite,
     "inventory": inventory}[args.command](args)


if __name__ == "__main__":
    main()
