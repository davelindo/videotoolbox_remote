#!/usr/bin/env python3
"""Protect benchmark publication boundaries and complete measured matrices."""

import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("performance", ROOT / "tests/integration/performance.py")
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.existing = json.loads((ROOT / "docs/_data/performance.json").read_text())
        original = [row for row in self.existing["rows"] if row["backend"] == "intel-vaapi"]
        rows = []
        for backend in performance.NVENC_BACKENDS:
            for reference in original:
                row = copy.deepcopy(reference)
                row["backend"] = backend
                for repeat in row["measured_repeats"]:
                    repeat.update(gpu_board_joules=100.0, gpu_board_average_watts=25.0,
                                  gpu_board_frames_per_joule=18.0)
                    repeat["private_path"] = "/PRIVATE_INFRASTRUCTURE/output.mkv"
                row["scored_output"] = copy.deepcopy(row["measured_repeats"][0])
                rows.append(row)
        build = {"version": "ffmpeg version n8.1.3-24-g92611900bb-20261025 Copyright", "sha256": "a" * 64,
                 "path": "/PRIVATE_INFRASTRUCTURE/ffmpeg"}
        host = {key: copy.deepcopy(build) for key in ("native_ffmpeg", "remote_ffmpeg", "quality_ffmpeg")}
        host.update(fixture_manifest={"fixtures": [{"name": item["fixture"], "sha256": item["sha256"]}
                                                   for item in self.existing["source_hashes"]]},
                    nvidia="NVIDIA GeForce RTX 3070 Ti, 580.178.04, 200.00, 310.00")
        self.summary = {"all_correct": True, "rows": rows, "private_host": "PRIVATE_INFRASTRUCTURE",
                        "metadata": {"created_at": "2026-10-25T00:00:00+00:00", "release": "v0.10.0",
                                     "frames": 1800, "repeats": 3, "warmup_frames": 60,
                                     "backends": list(performance.NVENC_BACKENDS),
                                     "hosts": {"PRIVATE_INFRASTRUCTURE": host},
                                     "quality_scorer": build,
                                     "calibration_measurement": performance.CALIBRATION_MEASUREMENT}}

    def export(self):
        return performance.public_results(self.summary)

    def test_private_fields_cannot_escape_at_any_exported_depth(self):
        result = self.export()
        self.assertEqual(len(result["rows"]), 24)
        self.assertNotIn("PRIVATE_INFRASTRUCTURE", json.dumps(result))
        self.assertEqual(result["rows"][0]["median_gpu_board_joules"], 100)

    def test_calibration_description_cannot_publish_raw_metadata_text(self):
        self.summary["metadata"]["calibration_measurement"] = "PRIVATE_INFRASTRUCTURE"
        with self.assertRaises(ValueError):
            self.export()

    def test_committed_data_excludes_raw_inventory_and_personal_identifiers(self):
        raw_keys = {"host", "hosts", "hostname", "username", "email", "pid", "processes",
                    "command", "commands", "path", "private_path", "private_host", "server",
                    "linux_host", "mac_host", "load_average", "cpu_count"}
        private_strings = re.compile(
            r"/(?:Users|home|Volumes)/|[A-Z]:\\Users\\|(?:ssh|scp)://|"
            r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|"
            r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b|"
            r"\b[A-Z0-9-]+\.local\b", re.IGNORECASE)

        def inspect(value):
            if isinstance(value, dict):
                self.assertFalse(raw_keys.intersection(value), "raw capture keys in published data")
                for child in value.values():
                    inspect(child)
            elif isinstance(value, list):
                for child in value:
                    inspect(child)
            elif isinstance(value, str):
                self.assertFalse(private_strings.search(value), "personal identifier in published data")

        inspect(self.existing)

    def test_append_retains_original_measurements(self):
        old_rows = [row for row in self.existing["rows"] if row["backend"] in performance.BACKENDS]
        original_audit = self.existing.get("original_file_budget_audit", self.existing["file_budget_audit"])
        baseline = {**self.existing, "rows": old_rows, "file_budget_audit": original_audit}
        result = performance.append_nvenc_results(baseline, self.export())
        self.assertEqual(result["rows"][:60], old_rows)
        self.assertEqual(len(result["rows"]), 84)
        self.assertEqual(result["rows"][-1]["quality_scorer_sha256"], "a" * 64)
        self.assertEqual(result["file_budget_audit"]["measured_outputs"], 252)
        self.assertEqual(result["file_budget_audit"]["moving_outputs"], 168)
        self.assertEqual(result["original_file_budget_audit"], original_audit)

    def test_missing_or_duplicate_case_is_rejected(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                altered = copy.deepcopy(self.summary)
                if duplicate:
                    altered["rows"][-1] = copy.deepcopy(altered["rows"][0])
                else:
                    altered["rows"].pop()
                with self.assertRaises(ValueError):
                    performance.public_results(altered)

    def test_incomplete_sampling_repeats_or_warmup_is_rejected(self):
        for field, value in (("frames", 60), ("repeats", 1), ("warmup_frames", 1)):
            with self.subTest(field=field):
                self.summary["metadata"][field] = value
                with self.assertRaises(ValueError):
                    self.export()
                self.setUp()
        self.summary["rows"][0]["vmaf_sampled_frames"] = 60
        with self.assertRaises(ValueError):
            self.export()

    def test_quality_is_bound_to_first_measured_file(self):
        self.summary["rows"][0]["scored_output"]["output_sha256"] = "b" * 64
        with self.assertRaises(ValueError):
            self.export()

    def test_invalid_repeat_or_energy_is_rejected(self):
        for key, value in (("gpu_board_joules", float("nan")), ("gpu_board_joules", 0),
                           ("gpu_board_average_watts", -1), ("fps", float("inf")), ("correct", False)):
            with self.subTest(key=key, value=value):
                self.summary["rows"][0]["measured_repeats"][1][key] = value
                with self.assertRaises(ValueError):
                    self.export()
                self.setUp()

    def test_gpu_inventory_cannot_publish_arbitrary_strings(self):
        host = next(iter(self.summary["metadata"]["hosts"].values()))
        host["nvidia"] = "PRIVATE_INFRASTRUCTURE, 580.178.04, 200, 310"
        with self.assertRaises(ValueError):
            self.export()

    def test_moving_outputs_must_match_file_budget(self):
        self.summary["rows"][0]["all_file_within_2_percent_target"] = False
        with self.assertRaises(ValueError):
            self.export()

    def mac_summary(self):
        summary = copy.deepcopy(self.summary)
        summary["metadata"]["backends"] = list(performance.MAC_ENERGY_BACKENDS)
        summary["metadata"]["mac_power_sampler"] = {
            "version": "mactop version: v2.1.6", "sha256": "c" * 64,
            "path": "/PRIVATE_INFRASTRUCTURE/mactop"}
        summary["rows"] = summary["rows"][:12]
        for row in summary["rows"]:
            row["backend"] = "videotoolbox"
            for repeat in [*row["measured_repeats"], row["scored_output"]]:
                for gpu_key, mac_key in zip(performance.GPU_ENERGY_KEYS, performance.MAC_ENERGY_KEYS):
                    repeat[mac_key] = repeat.pop(gpu_key)
        return summary

    def test_mac_energy_export_and_attachment_preserve_measurements(self):
        # Match the regenerated inputs used by the appended NVENC measurement.
        host = next(iter(self.summary["metadata"]["hosts"].values()))
        host["fixture_manifest"]["fixtures"] = [
            {"name": item["fixture"], "sha256": item["sha256"]}
            for item in self.existing["nvenc"]["source_hashes"]]
        addition = performance.public_results(self.mac_summary())
        self.assertNotIn("PRIVATE_INFRASTRUCTURE", json.dumps(addition))
        self.assertEqual(addition["mac_power"]["sensor"], "SMC PSTR")
        self.assertEqual(addition["rows"][0]["median_mac_system_joules"], 100)
        result = performance.append_mac_energy(self.existing, addition)
        self.assertEqual(result["rows"], self.existing["rows"])
        self.assertEqual(len(result["videotoolbox_energy"]["rows"]), 12)
        addition["source_hashes"][0]["sha256"] = "f" * 64
        with self.assertRaises(ValueError):
            performance.append_mac_energy(self.existing, addition)

    def test_mac_energy_rejects_missing_cases_invalid_energy_and_sampler(self):
        for mutation in ("missing", "nonfinite", "sampler"):
            with self.subTest(mutation=mutation):
                summary = self.mac_summary()
                if mutation == "missing":
                    summary["rows"].pop()
                elif mutation == "nonfinite":
                    summary["rows"][0]["measured_repeats"][1]["mac_system_joules"] = float("nan")
                else:
                    summary["metadata"]["mac_power_sampler"]["version"] = "PRIVATE_INFRASTRUCTURE"
                with self.assertRaises(ValueError):
                    performance.public_results(summary)

    def activity_audit(self):
        return {"created_at": "2026-10-25T00:00:00+00:00", "telemetry_samples": 2000,
                "encoder_activity_samples": 100, "unrelated_active_samples": 0,
                "private_path": "/PRIVATE_INFRASTRUCTURE/capture.jsonl",
                "output_sha256": [repeat["output_sha256"] for row in self.summary["rows"]
                    if row["fixture"] == "big-buck-bunny" and row["codec"] == "hevc"
                    and row["size"] == "1920x1080" for repeat in row["measured_repeats"]]}

    def test_activity_audit_is_allowlisted_and_bound_to_reference_outputs(self):
        self.summary["metadata"]["reference_gpu_activity_validation"] = self.activity_audit()
        result = self.export()
        self.assertNotIn("PRIVATE_INFRASTRUCTURE", json.dumps(result))
        self.assertEqual(result["nvenc"]["reference_activity_validation"]["monitored_repeats"], 6)
        self.summary["metadata"]["reference_gpu_activity_validation"]["output_sha256"][0] = "b" * 64
        with self.assertRaises(ValueError):
            self.export()

    def test_activity_audit_rejects_interference_or_missing_observations(self):
        for key, value in (("unrelated_active_samples", 1), ("encoder_activity_samples", 0),
                           ("telemetry_samples", 0), ("telemetry_samples", True)):
            with self.subTest(key=key, value=value):
                audit = self.activity_audit()
                audit[key] = value
                self.summary["metadata"]["reference_gpu_activity_validation"] = audit
                with self.assertRaises(ValueError):
                    self.export()


if __name__ == "__main__":
    unittest.main()
