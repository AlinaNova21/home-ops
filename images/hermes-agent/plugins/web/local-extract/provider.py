"""Local, self-hosted web extraction via trafilatura.

A WebSearchProvider that fetches a URL with httpx and extracts clean
article/main content locally with the trafilatura library. No cloud API,
no API key, no our-gateway — just a direct GET and local boilerplate
stripping. This is the "web_extract" complement to a self-hosted SearXNG
search: search stays on SearXNG, extraction stays local too.

Extract-only (``supports_extract()`` True, ``supports_search()`` False),
so it never tries to service ``web_search`` — that stays on SearXNG (or
another search backend).

Config keys this provider responds to::

    web:
      extract_backend: "local-extract"   # explicit per-capability
      backend: "local-extract"           # shared fallback

Optional env tuning (all read at call time, so they can live in .env):

    LOCAL_EXTRACT_TIMEOUT_MS   per-request timeout (default 30000)
    LOCAL_EXTRACT_UA           User-Agent string override

The extract() response shape follows the WebSearchProvider contract: a
per-URL list of dicts with ``url``/``title``/``content``/``raw_content``/
``metadata``/``error``. Per-URL failures (HTTP error, trafilatura finding
nothing, policy block, interruption) become an item with an ``error``
field rather than raising.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, List

from agent.web_search_provider import WebSearchProvider

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_MS = 30000
DEFAULT_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"
)


def _env(name: str, default: str = "") -> str:
    """Config-aware env read (falls back to process env)."""
    try:
        from hermes_cli.config import get_env_value

        val = get_env_value(name)
    except Exception:  # noqa: BLE001
        val = None
    if val is None:
        val = os.getenv(name, "")
    return (val or default).strip()


def _request_timeout() -> float:
    try:
        return max(1.0, float(_env("LOCAL_EXTRACT_TIMEOUT_MS", str(DEFAULT_TIMEOUT_MS))) / 1000.0)
    except ValueError:
        return DEFAULT_TIMEOUT_MS / 1000.0


class LocalExtractWebSearchProvider(WebSearchProvider):
    """Fetch + locally extract page content with httpx + trafilatura."""

    @property
    def name(self) -> str:
        return "local-extract"

    @property
    def display_name(self) -> str:
        return "Local Extract (trafilatura)"

    def is_available(self) -> bool:
        """True when trafilatura is importable (cheap, no network)."""
        try:
            import trafilatura  # noqa: F401
        except Exception:  # noqa: BLE001
            return False
        return True

    def supports_search(self) -> bool:
        return False

    def supports_extract(self) -> bool:
        return True

    async def extract(self, urls: List[str], **kwargs: Any) -> List[Dict[str, Any]]:
        """Extract content from one or more URLs locally.

        Accepts the ``format`` kwarg (``markdown`` or ``html``; default
        markdown). Returns the per-URL list-of-dicts shape. Per-URL
        failures become items with an ``error`` field.
        """
        import asyncio

        from tools.interrupt import is_interrupted as _is_interrupted

        if _is_interrupted():
            return [{"url": u, "error": "Interrupted", "title": ""} for u in urls]

        fmt = kwargs.get("format") or "markdown"
        as_html = str(fmt).lower().strip() == "html"
        timeout = _request_timeout()

        results: List[Dict[str, Any]] = []
        for url in urls:
            if _is_interrupted():
                results.append({"url": url, "error": "Interrupted", "title": ""})
                continue

            try:
                item = await asyncio.wait_for(
                    asyncio.to_thread(self._extract_one, url, timeout, as_html),
                    timeout=timeout + 30,
                )
            except asyncio.TimeoutError:
                item = {"url": url, "title": "", "content": "", "raw_content": "", "error": f"Local extract timeout after {timeout:.0f}s"}
            except Exception as exc:  # noqa: BLE001
                item = {"url": url, "title": "", "content": "", "raw_content": "", "error": f"Local extract error: {exc}"}
            results.append(item)

        return results

    def _extract_one(self, url: str, timeout: float, as_html: bool) -> Dict[str, Any]:
        """Synchronous fetch+extract for a single URL (threaded by caller)."""
        import httpx
        import trafilatura
        from courlan import extract_domain

        logger.info("Local extract: %s", url)

        # Pre-scrape website policy gate (same UX as firecrawl provider).
        try:
            from tools.website_policy import check_website_access

            blocked = check_website_access(url)
        except Exception:  # noqa: BLE001
            blocked = None
        if blocked:
            return {
                "url": url,
                "title": "",
                "content": "",
                "raw_content": "",
                "error": blocked.get("message", "Blocked by website policy"),
            }

        try:
            headers = {"User-Agent": _env("LOCAL_EXTRACT_UA", DEFAULT_UA)}
            resp = httpx.get(url, headers=headers, timeout=timeout, follow_redirects=True)
            resp.raise_for_status()
        except httpx.HTTPStatusError as exc:
            return {
                "url": url, "title": "", "content": "", "raw_content": "",
                "error": f"HTTP {exc.response.status_code} from {url}",
            }
        except (httpx.RequestError, httpx.TransportError) as exc:
            return {
                "url": url, "title": "", "content": "", "raw_content": "",
                "error": f"Fetch error for {url}: {exc}",
            }

        html = resp.text
        if not html:
            return {
                "url": url, "title": "", "content": "", "raw_content": "",
                "error": "Empty response body",
            }

        try:
            if as_html:
                content = trafilatura.extract(html, output_format="html", include_links=True)
            else:
                content = trafilatura.extract(html, output_format="markdown", include_links=True)
        except Exception as exc:  # noqa: BLE001
            return {
                "url": url, "title": "", "content": "", "raw_content": "",
                "error": f"trafilatura extraction failed: {exc}",
            }

        title = ""
        try:
            meta = trafilatura.extract_metadata(html)
            if meta is not None:
                title = (meta.title or "").strip()
        except Exception:  # noqa: BLE001
            title = ""

        if not (content and content.strip()):
            return {
                "url": url, "title": title, "content": "", "raw_content": "",
                "error": "No extractable article/main content found",
            }

        metadata: Dict[str, Any] = {}
        try:
            dom = extract_domain(url, strict=True)
            if dom:
                metadata["hostname"] = str(dom)
        except Exception:  # noqa: BLE001
            pass

        return {
            "url": url,
            "title": title,
            "content": content,
            "raw_content": content,
            "metadata": metadata,
        }

    def get_setup_schema(self) -> Dict[str, Any]:
        return {
            "name": "Local Extract",
            "badge": "free · self-hosted",
            "tag": "Local httpx + trafilatura extraction. No API key or cloud service.",
            "env_vars": [],
        }