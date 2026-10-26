#!/usr/bin/env python3
"""Verify power integration and reject incomplete or invalid measurements."""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

module_path = Path(__file__).resolve().parent / "integration/mac_power.py"
spec = importlib.util.spec_from_file_location("mac_power", module_path)
power = importlib.util.module_from_spec(spec)
spec.loader.exec_module(power)


class EnergyIntegrationTests(unittest.TestCase):
    def test_constant_power(self):
        result = power.integrate_energy([(0, 10), (0.5, 10), (1, 10)], 0.1, 0.9)
        self.assertAlmostEqual(result["mac_system_joules"], 8)
        self.assertAlmostEqual(result["mac_system_average_watts"], 10)

    def test_linear_ramp_with_fractional_boundaries(self):
        result = power.integrate_energy([(0, 10), (0.5, 20), (1, 30)], 0.25, 0.75)
        self.assertAlmostEqual(result["mac_system_joules"], 10)
        self.assertAlmostEqual(result["mac_system_average_watts"], 20)

    def test_missing_boundaries_or_large_gap_are_rejected(self):
        for samples, start, end in (([(0, 10), (0.5, 10)], -0.1, 0.4),
                                     ([(0, 10), (0.5, 10)], 0.1, 0.6),
                                     ([(0, 10), (1, 10)], 0, 1)):
            with self.subTest(samples=samples, start=start, end=end):
                with self.assertRaises(ValueError):
                    power.integrate_energy(samples, start, end)

    def test_invalid_samples_and_windows_are_rejected(self):
        for samples, start, end in (([(0, 10), (0.5, float("nan"))], 0, 0.5),
                                     ([(0, 10), (0.5, -1)], 0, 0.5),
                                     ([(0, 10), (0, 10)], 0, 0.5),
                                     ([(0, 10), (0.5, 10)], 0.5, 0.5)):
            with self.subTest(samples=samples, start=start, end=end):
                with self.assertRaises(ValueError):
                    power.integrate_energy(samples, start, end)

    def test_sampler_that_ignores_termination_is_reaped_and_closed(self):
        sampler = power.MacPowerSampler('unused', '.')
        sampler.process = Mock()
        sampler.process.poll.return_value = None
        sampler.process.wait.side_effect = [power.subprocess.TimeoutExpired('mactop', 10), 0]
        sampler.thread = Mock()
        sampler.stderr = Mock()
        sampler.__exit__()
        sampler.process.kill.assert_called_once_with()
        self.assertEqual(sampler.process.wait.call_count, 2)
        sampler.process.stdout.close.assert_called_once_with()
        sampler.stderr.close.assert_called_once_with()

    def test_component_estimate_is_excluded_and_dropout_is_retained(self):
        records = [{'soc_metrics': {'total_power': watts, 'system_power': remainder}}
                   for watts, remainder in ((10, 8), (100, 0), (10, 8))]
        with tempfile.TemporaryDirectory() as directory:
            sampler = power.MacPowerSampler('unused', directory)
            sampler.process = Mock()
            sampler.process.stdout = io.StringIO('\n'.join(json.dumps(record) for record in records))
            sampler.process.poll.return_value = None
            with patch.object(power.time, 'monotonic', side_effect=[0, 0.25, 0.5]):
                sampler._read()
            self.assertIsNone(sampler.error)
            self.assertAlmostEqual(power.integrate_energy(sampler.samples, 0, 0.5)['mac_system_joules'], 5)
            retained = [json.loads(line) for line in (Path(directory) / 'power-samples.jsonl').read_text().splitlines()]
            self.assertEqual([item['smc_available'] for item in retained], [True, False, True])


if __name__ == "__main__":
    unittest.main()
