"""Privacy-preserving API-key fingerprinting.

We never store or log the raw key. Instead each request is tagged with:
  - fp:   first 8 hex chars of sha256(salt || key) — stable per key, opaque
  - tail: last 4 chars of the key — lets a human recognize their own keys
          in the UI without exposing the secret

The salt is generated once at ~/.ai-spending/salt (mode 0600) so that the
fingerprints can't be brute-forced from a known key list without also
stealing the salt file.
"""
import hashlib
import os
import secrets
from pathlib import Path
from typing import Optional, Tuple
from urllib.parse import parse_qs

_SALT_FILE = Path.home() / ".ai-spending" / "salt"
_salt_cache: Optional[bytes] = None


def _salt() -> bytes:
    global _salt_cache
    if _salt_cache is not None:
        return _salt_cache
    _SALT_FILE.parent.mkdir(parents=True, exist_ok=True)
    if _SALT_FILE.exists():
        _salt_cache = _SALT_FILE.read_bytes()
    else:
        _salt_cache = secrets.token_bytes(32)
        _SALT_FILE.write_bytes(_salt_cache)
        os.chmod(_SALT_FILE, 0o600)
    return _salt_cache


def _extract_raw_key(provider: str, headers, query_string: str) -> Optional[str]:
    """Pull the raw key out of the request headers/query for the given provider.

    Header lookups are case-insensitive (aiohttp uses CIMultiDict).
    """
    def auth_bearer() -> Optional[str]:
        v = headers.get("Authorization") or headers.get("authorization")
        if v and v.lower().startswith("bearer "):
            return v[7:].strip() or None
        return None

    if provider == "anthropic":
        return headers.get("x-api-key") or headers.get("X-Api-Key")
    if provider == "gemini":
        v = headers.get("x-goog-api-key") or headers.get("X-Goog-Api-Key")
        if v:
            return v
        if query_string:
            qs = parse_qs(query_string)
            keys = qs.get("key")
            if keys:
                return keys[0]
        return None
    # openai, mistral, cohere, huggingface — all bearer
    return auth_bearer()


def fingerprint(provider: str, headers, query_string: str) -> Optional[Tuple[str, str]]:
    """Return (fp, tail) for the request, or None if no key was present."""
    key = _extract_raw_key(provider, headers, query_string)
    if not key:
        return None
    fp = hashlib.sha256(_salt() + key.encode()).hexdigest()[:8]
    tail = key[-4:] if len(key) >= 4 else key
    return fp, tail
