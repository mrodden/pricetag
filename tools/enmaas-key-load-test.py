#!/usr/bin/env python3
"""Concurrent, per-key EnMaaS gateway validation.

The harness launches one fresh TLS request per selected user behind a shared
barrier, approximating distinct users arriving simultaneously. Keys are read
only from a mode-0600 CSV and are never printed, written to results, or passed
through argv.

Examples:

  # Parse and validate all rows; sends no traffic.
  ./tools/enmaas-key-load-test.py --keys ~/Downloads/Pertest-users.csv \
      --validate-only

  # Auth-only ramp. /v1/models does not call a provider or create usage.
  ./tools/enmaas-key-load-test.py --keys ~/Downloads/Pertest-users.csv \
      --base-url https://api.enmaas.devshift.net --mode auth \
      --ramp 5,10,25,50,100,200 --confirm-prod

  # Inference is deliberately harder to invoke; run against stage first.
  ./tools/enmaas-key-load-test.py --keys ~/Downloads/Pertest-users.csv \
      --base-url https://stage-gateway.example --mode inference \
      --concurrency 25 --confirm-provider-traffic
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import ssl
import statistics
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timezone


PROD_HOST = "api.enmaas.devshift.net"
REQUIRED_COLUMNS = {"sequence", "user_id", "email", "key"}
KEY_PREFIXES = ("sk-", "pk-")
DEFAULT_MODEL = "rits/zai-org/glm-5-3"


class ConfigurationError(ValueError):
    """Unsafe or invalid test configuration."""


@dataclass(frozen=True)
class UserKey:
    sequence: str
    user_id: str
    email: str
    key: str

    @property
    def fingerprint(self) -> str:
        return hashlib.sha256(self.key.encode()).hexdigest()[:12]


@dataclass
class RequestResult:
    sequence: str
    user_id: str
    key_fingerprint: str
    status: int
    success: bool
    started_offset_ms: float
    ttfb_ms: float | None
    total_ms: float
    response_bytes: int
    error: str | None


def parse_ramp(raw: str | None, concurrency: int) -> list[int]:
    if not raw:
        return [concurrency]
    try:
        values = [int(part.strip()) for part in raw.split(",") if part.strip()]
    except ValueError as exc:
        raise ConfigurationError("--ramp must be comma-separated integers") from exc
    if not values or any(value < 1 for value in values):
        raise ConfigurationError("--ramp values must be positive")
    if values != sorted(set(values)):
        raise ConfigurationError("--ramp values must be unique and ascending")
    return values


def load_keys(path: Path) -> list[UserKey]:
    try:
        mode = path.stat().st_mode & 0o777
    except FileNotFoundError as exc:
        raise ConfigurationError(f"key file does not exist: {path}") from exc
    if mode & 0o077:
        raise ConfigurationError(
            f"key file mode is {mode:03o}; run chmod 600 {path} before testing"
        )

    with path.open(newline="", encoding="utf-8-sig") as stream:
        reader = csv.DictReader(stream)
        headers = set(reader.fieldnames or [])
        missing = sorted(REQUIRED_COLUMNS - headers)
        if missing:
            raise ConfigurationError(f"key file is missing columns: {', '.join(missing)}")
        raw_rows = list(reader)

    if not raw_rows:
        raise ConfigurationError("key file has no user rows")

    records: list[UserKey] = []
    seen: dict[str, set[str]] = {
        "sequence": set(),
        "user_id": set(),
        "email": set(),
        "key": set(),
    }
    for line_number, row in enumerate(raw_rows, start=2):
        values = {name: (row.get(name) or "").strip() for name in REQUIRED_COLUMNS}
        empty = sorted(name for name, value in values.items() if not value)
        if empty:
            raise ConfigurationError(
                f"line {line_number} has empty fields: {', '.join(empty)}"
            )
        try:
            normalized_id = str(uuid.UUID(values["user_id"]))
        except ValueError as exc:
            raise ConfigurationError(f"line {line_number} has invalid user_id") from exc
        if not values["key"].startswith(KEY_PREFIXES):
            raise ConfigurationError(f"line {line_number} has an unexpected key prefix")
        for name, value in values.items():
            if value in seen[name]:
                raise ConfigurationError(f"line {line_number} duplicates {name}")
            seen[name].add(value)
        records.append(
            UserKey(
                sequence=values["sequence"],
                user_id=normalized_id,
                email=values["email"],
                key=values["key"],
            )
        )
    return records


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(quantile * len(ordered)) - 1))
    return ordered[index]


def request_body(mode: str, model: str, run_id: str, sequence: str) -> bytes | None:
    if mode == "auth":
        return None
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": f"Reply with exactly: loadtest-{run_id}-{sequence}",
            }
        ],
    }
    # OpenAI's gpt-5 family rejects max_tokens. Hosted/Anthropic-compatible
    # models use the older spelling. Keep the cap identical so provider
    # comparisons have the same bounded output budget.
    token_parameter = "max_completion_tokens" if model.startswith("gpt-5") else "max_tokens"
    payload[token_parameter] = 64
    return json.dumps(payload).encode()


def fire_request(
    record: UserKey,
    *,
    barrier: threading.Barrier,
    batch_started: float,
    base_url: str,
    mode: str,
    model: str,
    run_id: str,
    timeout: float,
) -> RequestResult:
    try:
        barrier.wait(timeout=30)
    except threading.BrokenBarrierError:
        return RequestResult(
            record.sequence,
            record.user_id,
            record.fingerprint,
            0,
            False,
            0,
            None,
            0,
            0,
            "start barrier failed",
        )

    started = time.monotonic()
    body = request_body(mode, model, run_id, record.sequence)
    path = "/v1/models" if mode == "auth" else "/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {record.key}",
        "Accept": "application/json",
        "User-Agent": "enmaas-key-load-test/1",
        "X-EnMaaS-Test-Run": run_id,
    }
    method = "GET"
    if body is not None:
        method = "POST"
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=body,
        headers=headers,
        method=method,
    )

    status = 0
    response_bytes = 0
    error: str | None = None
    ttfb_ms: float | None = None
    try:
        with urllib.request.urlopen(
            request,
            timeout=timeout,
            context=ssl.create_default_context(),
        ) as response:
            ttfb_ms = (time.monotonic() - started) * 1000
            status = response.status
            response_bytes = len(response.read())
    except urllib.error.HTTPError as exc:
        ttfb_ms = (time.monotonic() - started) * 1000
        status = exc.code
        detail = exc.read(256).decode("utf-8", "replace").replace("\n", " ")
        error = detail.replace(record.key, "<redacted>") or f"HTTP {exc.code}"
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as exc:
        error = f"{type(exc).__name__}: {str(exc).replace(record.key, '<redacted>')}"

    finished = time.monotonic()
    return RequestResult(
        sequence=record.sequence,
        user_id=record.user_id,
        key_fingerprint=record.fingerprint,
        status=status,
        success=status == 200,
        started_offset_ms=(started - batch_started) * 1000,
        ttfb_ms=ttfb_ms,
        total_ms=(finished - started) * 1000,
        response_bytes=response_bytes,
        error=error,
    )


def run_batch(
    records: list[UserKey],
    *,
    base_url: str,
    mode: str,
    model: str,
    run_id: str,
    timeout: float,
) -> list[RequestResult]:
    # One worker per selected key is intentional: if the pool were smaller than
    # the barrier party count, queued tasks could never reach the barrier.
    barrier = threading.Barrier(len(records) + 1)
    batch_started = time.monotonic()
    results: list[RequestResult] = []
    with ThreadPoolExecutor(max_workers=len(records), thread_name_prefix="enmaas-user") as pool:
        futures = [
            pool.submit(
                fire_request,
                record,
                barrier=barrier,
                batch_started=batch_started,
                base_url=base_url,
                mode=mode,
                model=model,
                run_id=run_id,
                timeout=timeout,
            )
            for record in records
        ]
        try:
            barrier.wait(timeout=30)
        except threading.BrokenBarrierError:
            pass
        for future in as_completed(futures):
            results.append(future.result())
    return sorted(results, key=lambda result: result.sequence)


def summarize(results: list[RequestResult]) -> dict[str, float | int]:
    latencies = [result.total_ms for result in results]
    starts = [result.started_offset_ms for result in results]
    success = sum(result.success for result in results)
    return {
        "requests": len(results),
        "success": success,
        "failed": len(results) - success,
        "p50_ms": percentile(latencies, 0.50),
        "p95_ms": percentile(latencies, 0.95),
        "p99_ms": percentile(latencies, 0.99),
        "max_ms": max(latencies, default=math.nan),
        "launch_spread_ms": max(starts, default=0) - min(starts, default=0),
    }


def write_results(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2)
        stream.write("\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keys", required=True, type=Path, help="mode-0600 user CSV")
    parser.add_argument("--base-url", default="https://api.enmaas.devshift.net")
    parser.add_argument("--mode", choices=("auth", "inference"), default="auth")
    parser.add_argument("--concurrency", type=int, default=5)
    parser.add_argument("--ramp", help="ascending levels, e.g. 5,10,25,50,100,200")
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--round-delay", type=float, default=0)
    parser.add_argument("--cooldown", type=float, default=10, help="seconds between ramp levels")
    parser.add_argument("--timeout", type=float, default=0, help="request timeout; mode default when 0")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-p95", type=float, default=0, help="seconds; 0 uses mode default")
    parser.add_argument("--max-p99", type=float, default=0, help="seconds; 0 uses mode default")
    parser.add_argument("--max-error-rate", type=float, default=0, help="fraction, default 0")
    parser.add_argument("--confirm-prod", action="store_true")
    parser.add_argument("--confirm-provider-traffic", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        records = load_keys(args.keys.expanduser().resolve())
        ramp = parse_ramp(args.ramp, args.concurrency)
        if args.concurrency < 1:
            raise ConfigurationError("--concurrency must be positive")
        if max(ramp) > len(records):
            raise ConfigurationError(
                f"requested concurrency {max(ramp)} exceeds {len(records)} keys"
            )
        if args.rounds < 1:
            raise ConfigurationError("--rounds must be positive")
        if args.cooldown < 0 or args.round_delay < 0:
            raise ConfigurationError("delays must not be negative")
        if args.timeout < 0 or args.max_p95 < 0 or args.max_p99 < 0:
            raise ConfigurationError("timeouts and latency thresholds must not be negative")
        if not 0 <= args.max_error_rate <= 1:
            raise ConfigurationError("--max-error-rate must be between 0 and 1")
        parsed_url = urllib.parse.urlparse(args.base_url)
        if parsed_url.scheme != "https" or not parsed_url.hostname:
            raise ConfigurationError("--base-url must be a valid HTTPS URL")
        if parsed_url.hostname == PROD_HOST and not args.confirm_prod and not args.validate_only:
            raise ConfigurationError("production target requires --confirm-prod")
        if args.mode == "inference" and not args.confirm_provider_traffic and not args.validate_only:
            raise ConfigurationError("inference mode requires --confirm-provider-traffic")
    except ConfigurationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    print(
        f"validated {len(records)} unique keys from {args.keys}; "
        f"mode={args.mode} target={args.base_url}"
    )
    if args.validate_only:
        print("validation only: no requests sent")
        return 0

    run_id = args.run_id or (
        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6]
    )
    timeout = args.timeout or (15 if args.mode == "auth" else 120)
    max_p95 = (args.max_p95 or (1 if args.mode == "auth" else math.inf)) * 1000
    max_p99 = (args.max_p99 or (2 if args.mode == "auth" else math.inf)) * 1000
    output = args.output or Path(f"/tmp/enmaas-key-load-{run_id}.json")

    runs = []
    failed_gate = False
    for level_index, level in enumerate(ramp):
        for round_number in range(1, args.rounds + 1):
            batch_id = f"{run_id}-c{level}-r{round_number}"
            print(f"\nlaunching {level} simultaneous users ({batch_id})")
            results = run_batch(
                records[:level],
                base_url=args.base_url,
                mode=args.mode,
                model=args.model,
                run_id=batch_id,
                timeout=timeout,
            )
            summary = summarize(results)
            error_rate = summary["failed"] / summary["requests"]
            gate_errors = []
            if error_rate > args.max_error_rate:
                gate_errors.append(
                    f"error rate {error_rate:.2%} > {args.max_error_rate:.2%}"
                )
            if summary["p95_ms"] > max_p95:
                gate_errors.append(f"p95 {summary['p95_ms']:.0f}ms > {max_p95:.0f}ms")
            if summary["p99_ms"] > max_p99:
                gate_errors.append(f"p99 {summary['p99_ms']:.0f}ms > {max_p99:.0f}ms")
            summary["error_rate"] = error_rate
            summary["gate_errors"] = gate_errors
            print(
                "requests={requests} success={success} failed={failed} "
                "p50={p50_ms:.0f}ms p95={p95_ms:.0f}ms p99={p99_ms:.0f}ms "
                "max={max_ms:.0f}ms launch_spread={launch_spread_ms:.1f}ms".format(
                    **summary
                )
            )
            for result in results:
                if not result.success:
                    print(
                        f"  FAIL sequence={result.sequence} "
                        f"fingerprint={result.key_fingerprint} status={result.status} "
                        f"error={result.error or '-'}"
                    )
            if gate_errors:
                failed_gate = True
                print("GATE FAILED: " + "; ".join(gate_errors))
            runs.append(
                {
                    "concurrency": level,
                    "round": round_number,
                    "batch_id": batch_id,
                    "summary": summary,
                    "results": [asdict(result) for result in results],
                }
            )
            if failed_gate:
                break
            if round_number < args.rounds and args.round_delay:
                time.sleep(args.round_delay)
        if failed_gate:
            break
        if level_index < len(ramp) - 1 and args.cooldown:
            time.sleep(args.cooldown)

    payload = {
        "run_id": run_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "target": args.base_url,
        "mode": args.mode,
        "model": args.model if args.mode == "inference" else None,
        "key_count": len(records),
        "runs": runs,
    }
    write_results(output, payload)
    print(f"\nsanitized results: {output} (mode 0600)")
    return 1 if failed_gate else 0


if __name__ == "__main__":
    raise SystemExit(main())
