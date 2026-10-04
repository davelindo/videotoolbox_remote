#!/usr/bin/env python3
"""Publication privacy and completeness gates for measured performance data."""

import copy
import importlib.util
import itertools
import json
import math
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

SOURCE = Path(__file__).parent / "integration/performance.py"
SPEC = importlib.util.spec_from_file_location("performance", SOURCE)
performance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(performance)


def measured_summary():
    rows = []
    for fixture, codec, size, backend in itertools.product(
        ("big-buck-bunny", "testsrc2", "smptebars"), ("h264", "hevc"),
        ("1280x720", "1920x1080"),
        ("intel-vaapi", "cpu-fast", "cpu-medium", "videotoolbox", "videotoolbox-remote")
    ):
        rows.append({"fixture": fixture, "codec": codec, "size": size, "backend": backend,
                     "median_fps": 120.0, "min_fps": 118.0, "max_fps": 122.0, "fps_cv_percent": 1.5,
                     "median_cpu_seconds": 2.0, "median_peak_rss_bytes": 104857600,
                     "median_delivered_mbps": 4.0, "target_mbps": 4.0, "all_correct": True,
                     "all_within_10_percent_target": True, "vmaf": 90.0, "ssim": 0.99,
                     "vmaf_frame_stride": 5, "vmaf_sampled_frames": 360,
                     "host": "private-machine.example", "command": ["ssh", "private-account@private-machine.example"]})
    build = {"path": "/home/private-account/bin/ffmpeg", "sha256": "a" * 64,
             "version": "ffmpeg version 9.0.2 Copyright (c) the developers\nconfiguration: private-data"}
    host = {"host": "private-machine.example", "address": "192.0.2.123",
            "native_ffmpeg": build, "remote_ffmpeg": build, "quality_ffmpeg": build,
            "fixture_manifest": {"fixtures": [{"name": name, "sha256": digit * 64, "path": "/home/private-account/media"}
                                               for name, digit in zip(("big-buck-bunny", "testsrc2", "smptebars"), "123")]}}
    return {"metadata": {"frames": 1800, "repeats": 3, "release": "v1.2.3",
                         "created_at": "2026-01-01T12:00:00+00:00", "hosts": {"private-machine.example": host},
                         "server": {"address": "192.0.2.123", "user": "private-account"}},
            "rows": rows, "all_correct": True}


class PublicationTests(unittest.TestCase):
    def test_checked_in_results_have_only_public_fields(self):
        data = json.loads((SOURCE.parents[2] / "docs/_data/performance.json").read_text())
        expected = performance.public_results(measured_summary())
        self.assertEqual(set(data), set(expected))
        self.assertRegex(data["date"], r"^\d{4}-\d{2}-\d{2} UTC$")
        self.assertRegex(data["release"], r"^v\d+\.\d+\.\d+$")
        self.assertEqual(data["fixtures"], expected["fixtures"])
        self.assertEqual(data["outputs"], expected["outputs"])
        self.assertEqual(len(data["rows"]), 60)
        cases = set()
        expected_cases = {tuple(item[key] for key in ("fixture", "codec", "size", "backend")) for item in expected["rows"]}
        text_keys = {"fixture", "codec", "size", "backend", "label"}
        boolean_keys = {"all_correct", "all_within_10_percent_target"}
        for row in data["rows"]:
            self.assertEqual(set(row), set(expected["rows"][0]))
            case = tuple(row[key] for key in ("fixture", "codec", "size", "backend"))
            self.assertIn(case, expected_cases)
            self.assertNotIn(case, cases)
            cases.add(case)
            self.assertEqual(row["label"], performance.LABELS[row["backend"]])
            self.assertIs(row["all_correct"], True)
            for key in boolean_keys:
                self.assertIs(type(row[key]), bool)
            for key in set(row) - text_keys - boolean_keys:
                self.assertIn(type(row[key]), (int, float))
                self.assertTrue(math.isfinite(row[key]))
            self.assertEqual(row["vmaf_sampled_frames"], 360)
            self.assertEqual(row["vmaf_frame_stride"], 5)
        self.assertEqual(len(data["source_hashes"]), 3)
        for item in data["source_hashes"]:
            self.assertEqual(set(item), {"fixture", "sha256"})
            self.assertIn(item["fixture"], performance.FIXTURES)
            self.assertRegex(item["sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(data["builds"])
        for item in data["builds"]:
            self.assertEqual(set(item), {"version", "sha256"})
            self.assertRegex(item["version"], r"^(git-\d{4}-\d{2}-\d{2}-[0-9a-f]+|\d+\.\d+(?:\.\d+|\.git)?(?:-\d+ubuntu[0-9.+a-z]+)?)$")
            self.assertRegex(item["sha256"], r"^[0-9a-f]{64}$")

    def test_private_inventory_and_commands_are_excluded(self):
        result = performance.public_results(measured_summary())
        encoded = json.dumps(result)
        for value in ("private-machine", "private-account", "192.0.2.123", "/home/", "configuration:"):
            self.assertNotIn(value, encoded)
        self.assertEqual(len(result["rows"]), 60)
        self.assertEqual(len(result["builds"]), 1)

    def test_incomplete_comparison_is_rejected(self):
        data = measured_summary()
        data["rows"].pop()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            performance.public_results(data)

    def test_duplicate_case_is_rejected(self):
        data = measured_summary()
        data["rows"][-1] = copy.deepcopy(data["rows"][0])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            performance.public_results(data)

    def test_failed_media_cannot_be_published(self):
        data = measured_summary()
        data["rows"][0]["all_correct"] = False
        with self.assertRaises(ValueError):
            performance.public_results(data)

    def test_smoke_results_cannot_be_published(self):
        data = measured_summary()
        data["metadata"]["frames"] = 60
        with self.assertRaisesRegex(ValueError, "complete"):
            performance.public_results(data)

    def test_text_in_numeric_field_is_rejected(self):
        data = measured_summary()
        data["rows"][0]["median_fps"] = "private-machine.example"
        with self.assertRaisesRegex(ValueError, "finite numbers"):
            performance.public_results(data)

    def test_nonfinite_measurement_is_rejected(self):
        data = measured_summary()
        data["rows"][0]["vmaf"] = float("nan")
        with self.assertRaisesRegex(ValueError, "finite numbers"):
            performance.public_results(data)

    def test_private_capture_inside_git_checkout_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(["git", "init", "--quiet", directory], check=True)
            with self.assertRaisesRegex(ValueError, "outside"):
                performance.require_private_directory(Path(directory) / "private-captures")

    def test_private_capture_outside_git_checkout_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            performance.require_private_directory(Path(directory) / "private-captures")

    def test_worker_run_id_cannot_capture_inside_git(self):
        with tempfile.TemporaryDirectory() as workdir, tempfile.TemporaryDirectory() as checkout:
            subprocess.run(["git", "init", "--quiet", checkout], check=True)
            args = SimpleNamespace(workdir=Path(workdir), fixture="testsrc2",
                                   run_id=str(Path(checkout) / "private-captures"))
            with self.assertRaisesRegex(ValueError, "outside"):
                performance.worker(args)
            self.assertFalse((Path(checkout) / "private-captures").exists())


if __name__ == "__main__":
    unittest.main()
