#!/usr/bin/env python3
"""Measure bounded OBS pipeline under delayed replies and inject terminal faults."""

import argparse
import concurrent.futures
import json
from pathlib import Path
import queue
import shlex
import socket
import struct
import subprocess
import tempfile
import threading
import time
from run_transport_regressions import (
    ROOT,
    accept_h264_encoder,
    message,
    read_message,
    reset_on_close,
    string,
)


def run(probe, mode, fault="none", delay=0.04, count=120, fragmented=False):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(10)
        port = listener.getsockname()[1]
        errors = queue.Queue()

        def serve():
            try:
                with listener.accept()[0] as peer:
                    peer.settimeout(10)
                    peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    accept_h264_encoder(peer, "pipeline-test", "1")
                    replies = queue.Queue()
                    stop = threading.Event()

                    def output():
                        try:
                            while not stop.is_set():
                                item = replies.get()
                                if item is None:
                                    return
                                due, wire = item
                                if stop.wait(max(0, due - time.monotonic())):
                                    return
                                if fragmented:
                                    peer.sendall(wire[:17])
                                    time.sleep(0.01)
                                    peer.sendall(wire[17:])
                                else:
                                    peer.sendall(wire)
                        except OSError:
                            pass  # Client cancellation is expected in fault cases.

                    worker = threading.Thread(target=output, daemon=True)
                    worker.start()
                    try:
                        while True:
                            kind, body = read_message(peer)
                            if kind == 7:
                                replies.put((time.monotonic() + delay, message(8)))
                                replies.put(None)
                                worker.join(timeout=5)
                                break
                            assert kind == 5
                            pts = struct.unpack_from(">q", body)[0]
                            if pts == 3 and fault != "none":
                                if fault == "error":
                                    peer.sendall(
                                        message(
                                            9,
                                            struct.pack(">I", 2) + string("injected codec failure"),
                                        )
                                    )
                                elif fault == "reset":
                                    reset_on_close(peer)
                                elif fault == "truncated":
                                    peer.sendall(message(6, b"x" * 64)[:17])
                                elif fault == "malformed":
                                    peer.sendall(message(6, b"x"))
                                elif fault == "stalled":
                                    time.sleep(0.5)
                                break
                            nal = b"\0\0\0\1\x65\x88"
                            payload = struct.pack(">qqqII", pts, pts, 1, 0, len(nal)) + nal
                            replies.put((time.monotonic() + delay, message(6, payload)))
                    finally:
                        stop.set()
                        replies.put(None)
                        worker.join(timeout=1)
            except (EOFError, ConnectionError, BrokenPipeError):
                if fault == "none":
                    errors.put(RuntimeError("unexpected disconnect"))
            except Exception as error:
                errors.put(error)

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(serve)
            result = subprocess.run(
                [probe, str(port), mode, str(count)], capture_output=True, text=True, timeout=15
            )
            future.result(timeout=10)
        if not errors.empty():
            raise errors.get()
        assert not any(
            marker in result.stderr
            for marker in ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:")
        ), result.stderr
        expected_success = fault == "none"
        assert result.returncode == (0 if expected_success else 1), result.stderr + result.stdout
        record = json.loads(result.stdout)
        record.update(fault=fault, delay_ms=delay * 1000, fragmented=fragmented)
        if expected_success:
            assert record["frames"] == count and record["done"]
        if fault == "error":
            assert "injected codec failure" in result.stderr
        return record


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="obs-pipeline-") as build:
        probe = str(Path(build) / "probe")
        libraries = shlex.split(
            subprocess.check_output(
                ["pkg-config", "--cflags", "--libs", "liblz4", "libzstd"], text=True
            )
        )
        subprocess.run(
            [
                "c++",
                "-std=c++17",
                "-O2",
                "-pthread",
                "-I" + str(ROOT / "obs-plugin/src"),
                "-I" + str(ROOT / "tests/integration/obs_plugin_test_stubs"),
                str(ROOT / "obs-plugin/src/vtremoted-client.cpp"),
                str(ROOT / "obs-plugin/src/vtremoted-pipeline.cpp"),
                str(ROOT / "tests/integration/obs_pipeline_probe.cpp"),
                *libraries,
                "-o",
                probe,
            ],
            check=True,
        )
        records = []
        for repeat in range(3):
            for mode in ("sync", "pipeline") if repeat % 2 == 0 else ("pipeline", "sync"):
                record = run(probe, mode)
                record["repeat"] = repeat
                records.append(record)
                print(json.dumps(record), flush=True)
        for fault in ("error", "eof", "reset", "stalled", "truncated", "malformed"):
            record = run(probe, "pipeline", fault=fault)
            records.append(record)
            print(json.dumps(record), flush=True)
        if args.output:
            args.output.write_text(json.dumps(records, indent=2) + "\n")
