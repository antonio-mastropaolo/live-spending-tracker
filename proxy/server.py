#!/usr/bin/env python3
"""
Reverse-proxy daemon that intercepts AI API calls, extracts token usage,
and records costs to ~/.ai-spending/state.json.

URL scheme: http://localhost:7778/{provider}/{rest_of_path}
"""
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
from state.manager import record_usage, STATE_DIR

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
    headers = _forward_headers(request.headers)

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
                        record_usage(provider, model, in_tok, out_tok,
                                     cache_creation=cache_create, cache_read=cache_read)
                except Exception as exc:
                    logger.warning("Failed to record usage: %s", exc)

            resp_headers = _forward_headers(resp.headers)
            return web.Response(
                status=resp.status,
                headers=resp_headers,
                body=resp_body,
            )


def run_server(host: str = "127.0.0.1", port: int = 7778):
    pid_file = STATE_DIR / "proxy.pid"
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    pid_file.write_text(str(os.getpid()))

    app = web.Application(client_max_size=50 * 1024 * 1024)  # 50 MB
    app.router.add_route("*", "/{path_info:.*}", proxy_handler)

    try:
        web.run_app(app, host=host, port=port, access_log=None, print=None)
    finally:
        pid_file.unlink(missing_ok=True)


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    run_server()
