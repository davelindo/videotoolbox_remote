#!/usr/bin/env python3
import plistlib
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LaunchdPlistTests(unittest.TestCase):
    def test_values_round_trip_through_xml(self):
        label = "org.example.encoder<&>"
        logs = ["/tmp/output<&>.log", "/tmp/error<&>.log"]
        arguments = ["/opt/encoder & tools/vtremoted", "--token", "<&>\"'café\n", "--listen", "127.0.0.1:5555"]
        encoded = subprocess.check_output([
            "bash", str(ROOT / "vtremoted/launchd_plist.sh"), label, *logs, *arguments
        ])
        plist = plistlib.loads(encoded)
        self.assertEqual(plist["Label"], label)
        self.assertEqual(plist["ProgramArguments"], arguments)
        self.assertEqual(plist["StandardOutPath"], logs[0])
        self.assertEqual(plist["StandardErrorPath"], logs[1])
        self.assertTrue(plist["RunAtLoad"])
        self.assertTrue(plist["KeepAlive"])


if __name__ == "__main__":
    unittest.main()
