# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Run all tests
pytest tests/

# Run a single test file
pytest tests/test_parsers.py -v

# Start the proxy daemon manually
python3 proxy/server.py

# Start the overlay manually (background)
python3 display/overlay.py &

# CLI
python3 cli/main.py status
python3 cli/main.py report
python3 cli/main.py reset

# One-shot install (registers daemon + injects shell vars)
bash install.sh
```

## Architecture

**Data flow:**
```
SDK call  →  localhost:7778/{provider}/...  →  real API
                        │
                 parsers.py extracts
                 (input_tokens, output_tokens, model)
                        │
              state/manager.py writes
              ~/.ai-spending/state.json (atomic, fcntl-locked)
                        │
              display/overlay.py reads every 0.5s
              → draws green box at terminal top-right via /dev/tty
```

**URL routing in the proxy:**
Every provider is a path prefix: `http://localhost:7778/anthropic/v1/messages` forwards to `https://api.anthropic.com/v1/messages`. Supported prefixes: `anthropic`, `openai`, `mistral`, `gemini`, `cohere`.

**Streaming:** The proxy buffers the full response body before parsing, even for SSE streams. Clients still receive chunks in real time via `web.Response(body=...)` after the buffer is complete. For OpenAI/Mistral streaming, the proxy injects `stream_options.include_usage=true` into the request JSON so the final SSE chunk carries token counts.

**Model matching in pricing:** `state/manager.py:_match_price` does exact match first, then longest-prefix match against `proxy/pricing.json`. This handles dated model IDs like `claude-sonnet-4-6-20251022` matching `claude-sonnet-4-6`.

**Daily reset:** `state/manager.py:load_state` compares `state["date"]` to `date.today().isoformat()` and returns a zeroed state if they differ — no cron job needed.

**Overlay rendering:** `display/overlay.py` writes directly to `/dev/tty` using ANSI cursor save/restore (`\033[s` / `\033[u`) so it doesn't interfere with stdout. Handles `SIGWINCH` for terminal resize and erases the box on exit.

**Daemon registration:** `install.sh` writes a launchd plist (macOS) or systemd user service (Linux) pointing at `proxy/server.py`. The proxy writes its PID to `~/.ai-spending/proxy.pid` on start and removes it on exit.

## Key files

| File | Purpose |
|------|---------|
| `proxy/server.py` | `aiohttp` reverse-proxy, entry point for the daemon |
| `proxy/parsers.py` | Per-provider token-usage extraction (JSON + SSE) |
| `proxy/pricing.json` | USD/1M-token rates, keyed by provider → model |
| `state/manager.py` | Atomic state read/write; cost calculation via pricing |
| `display/overlay.py` | ANSI floating overlay, reads state every 0.5 s |
| `cli/main.py` | `click` CLI: start/stop/status/reset/report |
| `install.sh` | One-shot setup: deps, shell rc injection, daemon registration |
