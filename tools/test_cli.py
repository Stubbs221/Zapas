#!/usr/bin/env python3
"""Exercise the public JSON v1 CLI contract with a separate offline runtime."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

class CLIContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        local = Path(__file__).resolve().parents[1] / ".local"
        local.mkdir(exist_ok=True)
        cls.runtime = tempfile.TemporaryDirectory(prefix="cli-contract-", dir=local)
        cls.environment = {**os.environ, "ZAPAS_RUNTIME": cls.runtime.name}

    @classmethod
    def tearDownClass(cls):
        cls.runtime.cleanup()

    def invoke(self, *arguments, code=0, environment=None):
        env = {**self.environment, **(environment or {}), "ZAPAS_RUNTIME": self.runtime.name}
        result = subprocess.run([str(BINARY), *arguments], capture_output=True, text=True, env=env, timeout=10)
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(len(result.stdout.strip().splitlines()), 1)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["schemaVersion"], 1)
        self.assertTrue(envelope["generatedAt"].endswith("Z"))
        self.assertIn(envelope["status"], ("available", "partial", "error"))
        self.assertIsInstance(envelope["errors"], list)
        return envelope

    def assert_metric(self, metric, unit):
        self.assertEqual(set(metric), {"value", "unit", "source", "measuredAt", "status", "error"})
        self.assertEqual(metric["unit"], unit)
        self.assertTrue(metric["source"])
        self.assertTrue(metric["measuredAt"].endswith("Z"))
        if metric["value"] is None:
            self.assertEqual(metric["status"], "unknown")
            self.assertTrue(metric["error"]["code"])
        else:
            self.assertIsInstance(metric["value"], (float, int))
            self.assertGreaterEqual(metric["value"], 0)
            self.assertEqual(metric["status"], "available")
            self.assertIsNone(metric["error"])

    def test_status_sources_units_unknown_first_interval(self):
        envelope = self.invoke("status", "--json")
        data = envelope["data"]
        for key in ("physical", "wired", "compressed", "swapUsed", "swapTotal"):
            self.assert_metric(data[key], "bytes")
        for key in ("swapReadRate", "swapWriteRate"):
            self.assert_metric(data[key], "bytes/second")
            self.assertIsNone(data[key]["value"])
            self.assertEqual(data[key]["error"]["code"], "first_sample")
        self.assertIsNone(data["intervalSeconds"])
        self.assertEqual(data["pressure"]["state"], "unknown")
        self.assertIsNone(data["pressure"]["measuredAt"])
        self.assertEqual(envelope["status"], "partial")

    def test_process_identity_limit_sort_and_separate_rss(self):
        data = self.invoke("processes", "--sort", "memory", "--limit", "3", "--json")["data"]
        self.assertLessEqual(len(data["processes"]), 3)
        self.assertGreater(data["totalObserved"], 0)
        self.assertIn("not unique physical RAM", data["accounting"])
        values = []
        for process in data["processes"]:
            self.assertEqual(set(process["identity"]), {"pid", "startSeconds", "startMicroseconds"})
            self.assertGreater(process["identity"]["pid"], 0)
            self.assert_metric(process["footprint"], "bytes")
            self.assert_metric(process["rss"], "bytes")
            values.append(process["footprint"]["value"] if process["footprint"]["value"] is not None else -1)
        self.assertEqual(values, sorted(values, reverse=True))

    def test_default_process_limit(self):
        self.assertLessEqual(len(self.invoke("processes", "--json")["data"]["processes"]), 20)

    def test_invalid_arguments_have_one_error_json_and_exit_two(self):
        for arguments in (("status",), ("tabs", "--json"), ("status", "--apply", "--json"),
                          ("processes", "--limit", "0", "--json"), ("processes", "--limit", "10001", "--json"),
                          ("processes", "--limit", "nan", "--json"), ("processes", "--sort", "rss", "--json"),
                          ("status", "--json", "--json"), ("processes", "--limit"), ("status", "--limit", "1", "--json")):
            with self.subTest(arguments=arguments):
                envelope = self.invoke(*arguments, code=2)
                self.assertEqual(envelope["status"], "error")
                self.assertIsNone(envelope["data"])
                self.assertEqual(envelope["errors"][0]["code"], "invalid_arguments")

    def test_no_xcode_path_or_chrome_integration_required(self):
        environment = {**os.environ, "PATH": "", "DEVELOPER_DIR": "/nonexistent/zapas-no-xcode", "ZAPAS_SOCKET": "/nonexistent/socket"}
        self.assertGreater(self.invoke("status", "--json", environment=environment)["data"]["physical"]["value"], 0)
        self.assertIsNotNone(self.invoke("processes", "--json", environment=environment)["data"])

    def test_help_documents_read_only_diagnostics_and_explicit_actions(self):
        result = subprocess.run([str(BINARY), "--help"], capture_output=True, text=True, env=self.environment, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("read-only", result.stdout)
        self.assertIn("tabs preview", result.stdout)
        self.assertIn("--apply", result.stdout)

    def test_failed_stdout_delivery_exits_one(self):
        # A real, read-only stdout descriptor makes delivery fail without changing system APIs.
        with open(os.devnull, "rb") as output:
            result = subprocess.run([str(BINARY), "status", "--json"], stdout=output,
                                    stderr=subprocess.PIPE, text=True, env=self.environment, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")
        read_descriptor, write_descriptor = os.pipe()
        os.close(read_descriptor)
        try:
            result = subprocess.run([str(BINARY), "status", "--json"], stdout=write_descriptor,
                                    stderr=subprocess.PIPE, text=True, env=self.environment, timeout=10)
        finally:
            os.close(write_descriptor)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] / ".local/StageC/Zapas.app/Contents/MacOS/zapas")
    args = parser.parse_args()
    BINARY = args.binary.resolve()
    unittest.main(argv=[__file__], verbosity=2)
