import json
from typing import Optional, Tuple

# (input_tokens, output_tokens, model, cache_creation_tokens, cache_read_tokens)
UsageResult = Tuple[int, int, str, int, int]


def extract_usage(
    provider: str, body: bytes, is_streaming: bool = False
) -> Optional[UsageResult]:
    """Parse a response body and return usage 5-tuple or None."""
    if is_streaming:
        return _extract_streaming(provider, body)
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    try:
        if provider == "anthropic":
            usage = data["usage"]
            return (
                usage["input_tokens"],
                usage["output_tokens"],
                data.get("model", "unknown"),
                usage.get("cache_creation_input_tokens", 0),
                usage.get("cache_read_input_tokens", 0),
            )
        if provider in ("openai", "mistral", "huggingface"):
            return (
                data["usage"]["prompt_tokens"],
                data["usage"]["completion_tokens"],
                data.get("model", "unknown"),
                0, 0,
            )
        if provider == "gemini":
            meta = data.get("usageMetadata", {})
            model = data.get("modelVersion") or data.get("model", "unknown")
            return (
                meta.get("promptTokenCount", 0),
                meta.get("candidatesTokenCount", 0),
                model,
                0, 0,
            )
        if provider == "cohere":
            meta = data.get("meta", {}).get("tokens", {})
            return (
                meta.get("input_tokens", 0),
                meta.get("output_tokens", 0),
                data.get("model", "unknown"),
                0, 0,
            )
    except (KeyError, TypeError):
        return None
    return None


def _extract_streaming(provider: str, body: bytes) -> Optional[UsageResult]:
    """Parse a buffered SSE stream for token usage."""
    text = body.decode("utf-8", errors="replace")

    if provider == "anthropic":
        input_tokens = 0
        output_tokens = 0
        cache_creation = 0
        cache_read = 0
        model = "unknown"
        for line in text.splitlines():
            if not line.startswith("data:"):
                continue
            try:
                data = json.loads(line[5:].strip())
                t = data.get("type")
                if t == "message_start":
                    usage = data.get("message", {}).get("usage", {})
                    input_tokens = usage.get("input_tokens", input_tokens)
                    cache_creation = usage.get("cache_creation_input_tokens", cache_creation)
                    cache_read = usage.get("cache_read_input_tokens", cache_read)
                    model = data.get("message", {}).get("model", model)
                elif t == "message_delta":
                    output_tokens = data.get("usage", {}).get("output_tokens", output_tokens)
            except (json.JSONDecodeError, KeyError):
                continue
        if input_tokens or output_tokens:
            return (input_tokens, output_tokens, model, cache_creation, cache_read)

    elif provider in ("openai", "mistral", "huggingface"):
        # Walk lines in reverse to find the last chunk that has a usage field
        model = "unknown"
        for line in reversed(text.splitlines()):
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                continue
            try:
                data = json.loads(payload)
                if not model or model == "unknown":
                    model = data.get("model", "unknown")
                usage = data.get("usage")
                if usage:
                    return (
                        usage.get("prompt_tokens", 0),
                        usage.get("completion_tokens", 0),
                        model,
                        0, 0,
                    )
            except (json.JSONDecodeError, KeyError):
                continue

    return None
