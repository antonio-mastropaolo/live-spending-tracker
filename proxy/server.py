#!/usr/bin/env python3
"""
Reverse-proxy daemon that intercepts AI API calls, extracts token usage,
and records costs to ~/.ai-spending/state.json.

URL scheme: http://localhost:7778/{provider}/{rest_of_path}
"""
import asyncio
import json
import logging
import os
import sys
from pathlib import Path

import aiohttp
from aiohttp import web

# Allow running as a standalone script
sys.path.insert(0, str(Path(__file__).parent.parent))

from proxy.parsers import extract_usage
from proxy.keys import fingerprint as fingerprint_key
from state.manager import record_usage, record_today_estimate, load_state, STATE_DIR
from state.reconciler import reconciler_loop, load_admin_keys
from registry.loader import REGISTRY_FILE
from registry.reconciler import reconciler_loop as registry_reconciler_loop

PROVIDERS = {
    "anthropic":   "https://api.anthropic.com",
    "openai":      "https://api.openai.com",
    "gemini":      "https://generativelanguage.googleapis.com",
    "mistral":     "https://api.mistral.ai",
    "cohere":      "https://api.cohere.ai",
    "huggingface": "https://router.huggingface.co",
}

_HOP_BY_HOP = frozenset(
    ["host", "transfer-encoding", "connection", "keep-alive",
     "proxy-authenticate", "proxy-authorization", "te", "trailers", "upgrade"]
)

# aiohttp auto-decompresses response bodies on `resp.read()`, so the bytes we
# forward are plaintext. We must drop the upstream Content-Encoding (or the
# client will try to gunzip plain bytes → ZlibError) and the upstream
# Content-Length (which described the compressed payload).
_RESP_STRIP = frozenset(["content-encoding", "content-length"])

logger = logging.getLogger(__name__)


def _forward_headers(headers: "aiohttp.CIMultiDictProxy") -> dict:
    return {k: v for k, v in headers.items() if k.lower() not in _HOP_BY_HOP}


def _inject_stream_usage(provider: str, body: bytes) -> bytes:
    """For OpenAI/Mistral streaming requests, ensure usage is included in the last chunk."""
    if provider not in ("openai", "mistral", "huggingface") or not body:
        return body
    try:
        data = json.loads(body)
        if data.get("stream"):
            data.setdefault("stream_options", {})["include_usage"] = True
            return json.dumps(data).encode()
    except (json.JSONDecodeError, AttributeError):
        pass
    return body


async def proxy_handler(request: web.Request) -> web.Response:
    path = request.path.lstrip("/")
    parts = path.split("/", 1)
    if len(parts) < 2 or not parts[1]:
        raise web.HTTPBadRequest(text="Path must be /{provider}/{api_path}")

    provider, api_path = parts
    base_url = PROVIDERS.get(provider)
    if base_url is None:
        raise web.HTTPNotFound(text=f"Unknown provider '{provider}'. "
                               f"Known: {', '.join(PROVIDERS)}")

    target_url = f"{base_url}/{api_path}"
    if request.query_string:
        target_url += f"?{request.query_string}"

    body = await request.read()
    body = _inject_stream_usage(provider, body)
    key_fp_tail = fingerprint_key(provider, request.headers, request.query_string)
    headers = _forward_headers(request.headers)
    # Force upstream to send uncompressed bodies. Otherwise we may receive
    # brotli/zstd which aiohttp won't auto-decompress without extra deps,
    # and we'd forward compressed bytes after stripping Content-Encoding.
    headers["Accept-Encoding"] = "identity"

    async with aiohttp.ClientSession() as session:
        async with session.request(
            method=request.method,
            url=target_url,
            headers=headers,
            data=body,
            allow_redirects=False,
            ssl=True,
        ) as resp:
            resp_body = await resp.read()
            content_type = resp.headers.get("Content-Type", "")
            is_streaming = "event-stream" in content_type

            if 200 <= resp.status < 300:
                try:
                    usage = extract_usage(provider, resp_body, is_streaming=is_streaming)
                    if usage:
                        in_tok, out_tok, model, cache_create, cache_read = usage
                        kfp, ktail = (key_fp_tail or (None, None))
                        record_usage(provider, model, in_tok, out_tok,
                                     cache_creation=cache_create, cache_read=cache_read,
                                     key_fp=kfp, key_tail=ktail)
                        # v2 today-estimate hook. Mirror the v1 total into the
                        # `today_estimate` field so the menu bar can render it
                        # as a quiet ghost row alongside vendor-truth yesterday.
                        # Cheap (one extra fcntl write) and isolated from v2
                        # account state — never touches accounts.* fields.
                        if REGISTRY_FILE.exists():
                            try:
                                record_today_estimate(load_state().get("total_usd", 0.0))
                            except Exception as inner:
                                logger.warning("today_estimate hook failed: %s", inner)
                except Exception as exc:
                    logger.warning("Failed to record usage: %s", exc)

            resp_headers = {
                k: v for k, v in _forward_headers(resp.headers).items()
                if k.lower() not in _RESP_STRIP
            }
            return web.Response(
                status=resp.status,
                headers=resp_headers,
                body=resp_body,
            )


async def _start_reconciler(app: web.Application):
    """If admin keys exist, run the v1 vendor-truth reconciliation loop
    alongside the proxy. No keys → no-op (proxy-only mode, legacy behavior).

    Independent of the v2 registry reconciler (started in
    ``_start_registry_reconciler``). Both can run, neither blocks the other.
    """
    if not load_admin_keys():
        logger.info("reconciler v1: no admin keys at ~/.ai-spending/admin_keys.json — skipping")
        return
    app["reconciler_task"] = asyncio.create_task(reconciler_loop())
    logger.info("reconciler v1: loop started")


async def _start_registry_reconciler(app: web.Application):
    """v2: if ~/.ai-spending/registry.json exists, run the multi-account
    reconciler. No registry → no-op (additive-mode opt-in)."""
    if not REGISTRY_FILE.exists():
        logger.info("reconciler v2: no registry.json — skipping (proxy-only mode)")
        return
    app["registry_reconciler_task"] = asyncio.create_task(registry_reconciler_loop())
    logger.info("reconciler v2: registry-driven loop started")


async def _stop_reconciler(app: web.Application):
    for key in ("reconciler_task", "registry_reconciler_task"):
        task = app.get(key)
        if task is not None:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass


def run_server(host: str = "127.0.0.1", port: int = 7778):
    pid_file = STATE_DIR / "proxy.pid"
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    pid_file.write_text(str(os.getpid()))

    app = web.Application(client_max_size=50 * 1024 * 1024)  # 50 MB
    app.router.add_route("*", "/{path_info:.*}", proxy_handler)
    app.on_startup.append(_start_reconciler)
    app.on_startup.append(_start_registry_reconciler)
    app.on_cleanup.append(_stop_reconciler)

    try:
        web.run_app(app, host=host, port=port, access_log=None, print=None)
    finally:
        pid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    run_server()
