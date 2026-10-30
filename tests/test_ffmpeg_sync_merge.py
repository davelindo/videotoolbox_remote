#!/usr/bin/env python3
"""Check that upstream maintenance edits merge with the local FFmpeg integration."""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FFmpegSyncMergeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.anchor = subprocess.check_output(
            ["bash", "scripts/check_ffmpeg_subtree.sh"], cwd=ROOT, text=True
        ).strip()

    def upstream(self, path):
        return subprocess.check_output(
            ["git", "show", f"{self.anchor}:{path}"], cwd=ROOT
        )

    def merge(self, path, upstream):
        with tempfile.TemporaryDirectory() as directory:
            inputs = [Path(directory) / name for name in ("local", "base", "upstream")]
            contents = [
                (ROOT / "ffmpeg" / path).read_bytes(),
                self.upstream(path),
                upstream,
            ]
            for filename, content in zip(inputs, contents):
                filename.write_bytes(content)
            result = subprocess.run(
                ["git", "merge-file", "--stdout", *map(str, inputs)], capture_output=True
            )
        self.assertEqual(result.returncode, 0, f"Upstream edit conflicts in {path}")
        return result.stdout

    def test_upstream_test_program_addition(self):
        base = self.upstream("libavcodec/Makefile")
        programs = re.search(rb"(?m)^TESTPROGS =[^\n]*(?:\n[ \t]+[^\n]*)*", base)
        self.assertIsNotNone(programs)
        block = programs.group()
        if not block.endswith(b"\\"):
            block += b" \\"
        marker = b"vtremote_upstream_merge_test"
        upstream = (
            base[: programs.start()]
            + block
            + b"\n            "
            + marker
            + b" \\"
            + base[programs.end() :]
        )
        merged = self.merge("libavcodec/Makefile", upstream)
        for entry in (
            marker,
            b"vtremote_proto",
            b"vtremote_h264.o",
            b"vtremote_hevc.o",
            b"vtremote_h264_dec.o",
            b"vtremote_hevc_dec.o",
        ):
            self.assertIn(entry, merged)

    def test_upstream_library_version_update(self):
        base = self.upstream("configure")
        upstream, count = re.subn(
            rb'("lcevc_dec >= )[^"\n]+', rb'\g<1>999.0.0', base, count=1
        )
        self.assertEqual(count, 1)
        merged = self.merge("configure", upstream)
        for entry in (b'lcevc_dec >= 999.0.0', b"LZ4_compress_default", b"ZSTD_compress"):
            self.assertIn(entry, merged)


if __name__ == "__main__":
    unittest.main()
