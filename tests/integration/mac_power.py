"""Read the installed mactop SMC system-power sampler during local encodes."""

import json
import math
from pathlib import Path
import subprocess
import threading
import time


def integrate_energy(samples, start, end, max_gap=0.8):
    """Integrate sampled watts, interpolating the exact measurement boundaries."""
    if not math.isfinite(start) or not math.isfinite(end) or end <= start:
        raise ValueError("invalid energy measurement window")
    if len(samples) < 2 or samples[0][0] > start or samples[-1][0] < end:
        raise ValueError("power samples must bracket the complete transcode")
    joules = 0.0
    covered = 0.0
    for (ta, wa), (tb, wb) in zip(samples, samples[1:]):
        if not all(math.isfinite(value) for value in (ta, wa, tb, wb)) or tb <= ta or min(wa, wb) <= 0:
            raise ValueError("invalid power samples")
        left, right = max(start, ta), min(end, tb)
        if right <= left:
            continue
        if tb - ta > max_gap:
            raise ValueError("power sample gap exceeds the measured cadence allowance")
        left_watts = wa + (wb - wa) * (left - ta) / (tb - ta)
        right_watts = wa + (wb - wa) * (right - ta) / (tb - ta)
        joules += (left_watts + right_watts) * 0.5 * (right - left)
        covered += right - left
    if not math.isclose(covered, end - start, rel_tol=1e-9, abs_tol=1e-9):
        raise ValueError("power samples do not cover the complete transcode")
    return {"mac_system_joules": joules, "mac_system_average_watts": joules / (end - start)}


class MacPowerSampler:
    def __init__(self, binary, directory):
        self.binary = binary
        self.directory = Path(directory)
        self.samples = []
        self.error = None
        self.condition = threading.Condition()

    def __enter__(self):
        self.stderr = (self.directory / "power-sampler.stderr.log").open("w")
        try:
            self.process = subprocess.Popen([self.binary, "--headless", "--format", "json", "--interval", "100"],
                                            stdout=subprocess.PIPE, stderr=self.stderr, text=True)
        except BaseException:
            self.stderr.close()
            raise
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        try:
            with self.condition:
                if not self.condition.wait_for(lambda: len(self.samples) >= 2 or self.error, timeout=15):
                    raise RuntimeError("Mac power sampler did not become ready")
                if self.error:
                    raise RuntimeError("Mac power sampler failed") from self.error
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def _read(self):
        try:
            with (self.directory / "power-samples.jsonl").open("w") as output:
                for line in self.process.stdout:
                    received = time.monotonic()
                    record = json.loads(line)
                    metrics = record["soc_metrics"]
                    watts = float(metrics["total_power"])
                    # mactop uses SMC system total when it exceeds the component
                    # estimate. Exclude ambiguous samples; the integration still
                    # requires complete boundary coverage and a gap below 0.8 s.
                    available = math.isfinite(watts) and watts > 0 and metrics["system_power"] > 0
                    output.write(json.dumps({"received_monotonic": received, "smc_available": available,
                                             "sample": record}) + "\n")
                    output.flush()
                    if not available:
                        continue
                    with self.condition:
                        self.samples.append((received, watts))
                        self.condition.notify_all()
            if self.process.poll() is not None and self.process.returncode:
                raise RuntimeError("Mac power sampler exited unsuccessfully")
        except BaseException as error:
            with self.condition:
                self.error = error
                self.condition.notify_all()

    def energy_between(self, start, end):
        with self.condition:
            ready = self.condition.wait_for(lambda: self.error or (self.samples and self.samples[-1][0] >= end), timeout=5)
            if self.error:
                raise RuntimeError("Mac power sampling failed during the transcode") from self.error
            if not ready:
                raise RuntimeError("Mac power samples did not bracket the transcode end")
            return integrate_energy(list(self.samples), start, end)

    def __exit__(self, *unused):
        try:
            if self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        finally:
            self.thread.join(timeout=5)
            self.process.stdout.close()
            self.stderr.close()
