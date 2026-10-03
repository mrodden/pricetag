#!/usr/bin/env python3
import csv
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).with_name("enmaas-key-load-test.py")
SPEC = importlib.util.spec_from_file_location("enmaas_key_load_test", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class HarnessTest(unittest.TestCase):
    def write_csv(self, rows, mode=0o600):
        tmp = tempfile.NamedTemporaryFile(mode="w", newline="", delete=False)
        with tmp:
            writer = csv.DictWriter(
                tmp, fieldnames=["sequence", "user_id", "email", "key", "gateway_status"]
            )
            writer.writeheader()
            writer.writerows(rows)
        path = Path(tmp.name)
        path.chmod(mode)
        self.addCleanup(path.unlink, missing_ok=True)
        return path

    def row(self, sequence="001", user_id="4c8a089d-e5e6-4632-99c6-1413f79fc7bf"):
        return {
            "sequence": sequence,
            "user_id": user_id,
            "email": f"user{sequence}@example.invalid",
            "key": f"sk-test-{sequence}-not-a-real-secret",
            "gateway_status": "200",
        }

    def test_load_keys_accepts_secure_unique_rows(self):
        rows = [self.row(), self.row("002", "123e4567-e89b-12d3-a456-426614174000")]
        records = MODULE.load_keys(self.write_csv(rows))
        self.assertEqual(2, len(records))
        self.assertEqual(12, len(records[0].fingerprint))

    def test_load_keys_rejects_loose_permissions(self):
        with self.assertRaisesRegex(MODULE.ConfigurationError, "chmod 600"):
            MODULE.load_keys(self.write_csv([self.row()], 0o644))

    def test_load_keys_rejects_duplicate_key(self):
        rows = [self.row(), self.row("002", "123e4567-e89b-12d3-a456-426614174000")]
        rows[1]["key"] = rows[0]["key"]
        with self.assertRaisesRegex(MODULE.ConfigurationError, "duplicates key"):
            MODULE.load_keys(self.write_csv(rows))

    def test_parse_ramp_requires_ascending_unique_values(self):
        self.assertEqual([5, 10, 25], MODULE.parse_ramp("5,10,25", 1))
        with self.assertRaises(MODULE.ConfigurationError):
            MODULE.parse_ramp("10,5", 1)
        with self.assertRaises(MODULE.ConfigurationError):
            MODULE.parse_ramp("5,5", 1)

    def test_percentile_uses_nearest_rank(self):
        self.assertEqual(4, MODULE.percentile([1, 2, 3, 4], 0.95))

    def test_run_batch_sends_distinct_keys_behind_barrier(self):
        seen = []
        seen_lock = threading.Lock()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                with seen_lock:
                    seen.append(self.headers.get("Authorization"))
                body = b'{"object":"list","data":[]}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format, *_args):
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        records = [
            MODULE.UserKey(
                sequence=f"{i:03d}",
                user_id=str(uuid),
                email=f"user{i}@example.invalid",
                key=f"sk-test-{i}",
            )
            for i, uuid in enumerate(
                [
                    "123e4567-e89b-12d3-a456-426614174000",
                    "123e4567-e89b-12d3-a456-426614174001",
                    "123e4567-e89b-12d3-a456-426614174002",
                    "123e4567-e89b-12d3-a456-426614174003",
                    "123e4567-e89b-12d3-a456-426614174004",
                ],
                start=1,
            )
        ]
        results = MODULE.run_batch(
            records,
            base_url=f"http://127.0.0.1:{server.server_port}",
            mode="auth",
            model=MODULE.DEFAULT_MODEL,
            run_id="unit-test",
            timeout=5,
        )
        self.assertTrue(all(result.success for result in results))
        self.assertEqual(
            {f"Bearer sk-test-{i}" for i in range(1, 6)},
            set(seen),
        )
        self.assertLess(MODULE.summarize(results)["launch_spread_ms"], 1000)


if __name__ == "__main__":
    unittest.main()
