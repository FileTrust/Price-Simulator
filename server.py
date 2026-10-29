#!/usr/bin/env python3
# SPDX-License-Identifier: FSL-1.1-ALv2
"""Small configurable FTU/USDC quote API.

The response shape is intentionally DEX-like: Explorer can consume this today
from config, and later the config can point to real DEX contracts or an adapter
without changing the Explorer API contract.
"""

from __future__ import annotations

import argparse
import json
import ipaddress
import re
import time
from datetime import datetime
from decimal import Decimal, InvalidOperation, getcontext
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse, urlsplit


getcontext().prec = 48

APP_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = APP_DIR / "config.json"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def load_config(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def decimal_from(value: Any, fallback: str = "0") -> Decimal:
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal(fallback)


def decimal_string(value: Decimal, places: int | None = None) -> str:
    if places is not None:
        quantum = Decimal(1).scaleb(-places)
        value = value.quantize(quantum)
    text = format(value.normalize(), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def token(config: dict[str, Any], key: str, fallback_symbol: str) -> dict[str, Any]:
    supplied = config.get(key) or {}
    data = {field: supplied[field] for field in ("symbol", "name", "address", "decimals") if field in supplied}
    data.setdefault("symbol", fallback_symbol)
    data.setdefault("address", "0x0000000000000000000000000000000000000000")
    data.setdefault("decimals", 18 if fallback_symbol == "FTU" else 6)
    return data


def quote_payload(config: dict[str, Any], amount: Decimal) -> dict[str, Any]:
    price = decimal_from((config.get("price") or {}).get("ftu_usdc"), "0")
    amount_out = amount * price
    inverse = (Decimal(1) / price) if price > 0 else Decimal(0)
    base = token(config, "base_token", "FTU")
    quote = token(config, "quote_token", "USDC")
    dex = dict(config.get("dex") or {})
    dex.setdefault("name", "FileTrust Local Quote Feed")
    dex.setdefault("factory_address", "0x0000000000000000000000000000000000000000")
    dex.setdefault("router_address", "0x0000000000000000000000000000000000000000")
    dex.setdefault("pair_address", "0x0000000000000000000000000000000000000000")

    return {
        "schema": "filetrust.dex.quote.v1",
        "source": str(config.get("source") or "config"),
        "chainId": int(config.get("chain_id") or 31338),
        "dex": {
            "name": dex["name"],
            "factoryAddress": dex["factory_address"],
            "routerAddress": dex["router_address"],
            "pairAddress": dex["pair_address"],
        },
        "pair": f"{base['symbol']}/{quote['symbol']}",
        "baseToken": base,
        "quoteToken": quote,
        "amountIn": decimal_string(amount),
        "amountOut": decimal_string(amount_out, int(quote.get("decimals") or 6)),
        "price": decimal_string(price),
        "inversePrice": decimal_string(inverse),
        "priceImpactBps": "0",
        "route": [
            {
                "dex": dex["name"],
                "pairAddress": dex["pair_address"],
                "tokenIn": base["symbol"],
                "tokenOut": quote["symbol"],
            }
        ],
        "updatedAt": str((config.get("price") or {}).get("updated_at") or now_iso()),
        "servedAt": now_iso(),
        "ttlSeconds": int(config.get("ttl_seconds") or 30),
    }



def assert_public_content(value: Any) -> None:
    """Reject private material in response data; errors contain no input values."""
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = re.sub(r"[^a-z]", "", str(key).lower())
            if normalized in {"password", "privatekey", "signingkey", "mnemonic",
                              "seedphrase", "apikey", "apitoken", "accesstoken"} and item:
                raise ValueError("Private content is not publishable")
            assert_public_content(str(key))
            assert_public_content(item)
    elif isinstance(value, list):
        for item in value:
            assert_public_content(item)
    elif isinstance(value, str):
        candidates = re.findall(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])", value)
        candidates += re.findall(r"(?<![\w:])[0-9a-fA-F]*:[0-9a-fA-F:.%]+(?![\w:])", value)
        for candidate in candidates:
            try:
                ipaddress.ip_address(candidate)
            except ValueError:
                continue
            raise ValueError("IP literals are not publishable")
        if re.search(r"(?:/home/[^/\s]+/|/mnt/[A-Za-z]/)|-----BEGIN [A-Z ]*PRIVATE KEY-----", value):
            raise ValueError("Private infrastructure content is not publishable")
        for candidate in re.findall(r"https?://[^\s\"'<>]+", value):
            parsed = urlsplit(candidate)
            if parsed.username or parsed.password:
                raise ValueError("Credentials in URLs are not publishable")


class PriceHandler(BaseHTTPRequestHandler):
    server_version = "FileTrustFTUPrice/1.0"

    def _config(self) -> dict[str, Any]:
        return load_config(self.server.config_path)  # type: ignore[attr-defined]

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        try:
            assert_public_content(payload)
        except ValueError:
            status, payload = 500, {"ok": False, "error": "Price service is temporarily unavailable"}
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self._send_json(200, {"ok": True})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        try:
            config = self._config()
        except Exception as exc:
            self.log_error("configuration load failed: %s", exc)
            self._send_json(500, {"ok": False, "error": "Price service is temporarily unavailable"})
            return

        if path == "/health":
            self._send_json(200, {
                "ok": True,
                "service": "ftu-price-oracle",
                "pair": "FTU/USDC",
                "source": str(config.get("source") or "config"),
                "servedAt": now_iso(),
            })
            return

        if path in {"/", "/v1/price", "/v1/quote"}:
            params = parse_qs(parsed.query)
            base = (params.get("base") or ["FTU"])[0].upper()
            quote = (params.get("quote") or ["USDC"])[0].upper()
            if base != "FTU" or quote != "USDC":
                self._send_json(400, {"ok": False, "error": "only FTU/USDC is configured"})
                return
            amount = decimal_from((params.get("amount") or ["1"])[0], "1")
            if amount < 0:
                self._send_json(400, {"ok": False, "error": "amount must be non-negative"})
                return
            self._send_json(200, quote_payload(config, amount))
            return

        if path == "/v1/pairs":
            self._send_json(200, {"pairs": [quote_payload(config, Decimal(1))]})
            return

        self._send_json(404, {"ok": False, "error": "not found"})

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} {fmt % args}", flush=True)


def _start_own_logging(config: dict) -> None:
    """Keep this service's log inside its own folder, and archive it daily.

    Everything here is printed, so the file used to exist only because a runner
    redirected stdout. That is no good for a service meant to run on its own.
    """
    try:
        import log_archive

        log_dir = Path(__file__).resolve().parent / "log"
        log_archive.tee_stdout(log_dir, "ftu-price")
        log_archive.start_daily(log_dir, **log_archive.options_from_config(config))
    except Exception:
        pass  # tidying logs must never stop the server starting


def main() -> int:
    parser = argparse.ArgumentParser(description="Serve configurable FTU/USDC DEX-style quotes.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--host", default=None)
    parser.add_argument("--port", type=int, default=None)
    args = parser.parse_args()

    config = load_config(args.config)
    host = args.host or str(config.get("host") or DEFAULT_HOST)
    port = int(args.port or config.get("port") or DEFAULT_PORT)
    _start_own_logging(config)

    server = ThreadingHTTPServer((host, port), PriceHandler)
    server.config_path = args.config  # type: ignore[attr-defined]
    print(f"[ftu-price] serving FTU/USDC quotes at http://{host}:{port}", flush=True)
    print(f"[ftu-price] config: {args.config}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[ftu-price] stopping", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
