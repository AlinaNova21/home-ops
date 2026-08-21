"""Local Extract — self-hosted web extraction provider.

Fetches pages with httpx and extracts clean content locally via the
trafilatura library. No cloud API, no API key. Extract-only; pair with a
search backend (e.g. SearXNG) for web_search.
"""

from __future__ import annotations

from .provider import LocalExtractWebSearchProvider


def register(ctx) -> None:
    """Register the local-extract provider with the plugin context."""
    ctx.register_web_search_provider(LocalExtractWebSearchProvider())