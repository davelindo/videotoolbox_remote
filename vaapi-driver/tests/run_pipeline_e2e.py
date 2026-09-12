#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
from run_obs_pipeline import run

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--test", type=Path, help="Use the CMake-built probe, including its sanitizer flags"
    )
    args = parser.parse_args()
    records = []
    with tempfile.TemporaryDirectory(prefix="vtr-sdk-pipeline-") as directory:
        probe = str(args.test.resolve()) if args.test else str(Path(directory) / "probe")
        if not args.test:
            libraries = shlex.split(
                subprocess.check_output(
                    ["pkg-config", "--cflags", "--libs", "liblz4", "libzstd"], text=True
                )
            )
            subprocess.run(
                [
                    "cc",
                    "-std=c11",
                    "-O2",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I" + str(ROOT / "vaapi-driver/include"),
                    str(ROOT / "vaapi-driver/src/protocol.c"),
                    str(ROOT / "vaapi-driver/src/client.c"),
                    str(ROOT / "vaapi-driver/tests/pipeline_probe.c"),
                    *libraries,
                    "-o",
                    probe,
                ],
                check=True,
            )
        for repeat in range(3):
            for mode in ("sync", "pipeline") if repeat % 2 == 0 else ("pipeline", "sync"):
                result = run(probe, mode, count=120)
                result["repeat"] = repeat
                records.append(result)
                print(json.dumps(result), flush=True)
        for fault in ("error", "eof", "reset", "truncated", "malformed"):
            result = run(probe, "pipeline", fault=fault)
            records.append(result)
            print(json.dumps(result), flush=True)
        result = run(probe, "poll", count=20, fragmented=True)
        records.append(result)
        print(json.dumps(result), flush=True)
    if args.output:
        args.output.write_text(json.dumps(records, indent=2) + "\n")
