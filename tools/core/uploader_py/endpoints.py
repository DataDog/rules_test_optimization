# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Normalize and validate intake endpoints before workers start.

One endpoint policy keeps agentless and EVP routing consistent across payload types.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from urllib.parse import SplitResult, urlsplit

from .config import ConfigError, UploaderConfig


_VALID_HOSTNAME_RE = re.compile(
    r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"
)
_INVALID_PERCENT_ESCAPE_RE = re.compile(r"%(?![0-9A-Fa-f]{2})")


@dataclass(frozen=True)
class EndpointSet:
    """Resolved upload endpoints for one invocation."""

    agentless: bool
    site: str
    test_url: str
    coverage_url: str
    telemetry_url: str


def normalize_dd_site(raw_site: str) -> str:
    """Normalize legacy DD_SITE forms while rejecting unsafe host input."""
    site = raw_site.strip()
    if not site:
        return "datadoghq.com"
    if "://" in site:
        site = site.split("://", 1)[1]
    site = site.split("/", 1)[0]
    site = site.split("?", 1)[0]
    site = site.split("#", 1)[0]
    if site.lower().startswith("app."):
        site = site[4:]
    if site.lower().startswith("api."):
        site = site[4:]
    site = site.strip().lower()

    if not site:
        raise ConfigError("DD_SITE resolved to an empty hostname")
    if "@" in site:
        raise ConfigError("DD_SITE must not include credentials/userinfo")
    if ":" in site:
        raise ConfigError("DD_SITE must be a hostname without an explicit port")
    if site.startswith(".") or site.endswith(".") or ".." in site:
        raise ConfigError("DD_SITE must be a valid hostname")
    if not _VALID_HOSTNAME_RE.fullmatch(site):
        raise ConfigError("DD_SITE contains unsupported hostname characters")
    return site


def parse_http_url(raw_url: str) -> SplitResult:
    """Parse one network-ready absolute HTTP(S) URL.

    urllib accepts some values during parsing that ``http.client`` rejects only
    when it starts a request. Keeping this small preflight shared by endpoint
    configuration and request preparation makes dry-run reject those values too.
    """
    if not isinstance(raw_url, str) or not raw_url:
        raise ValueError("HTTP URL must be a non-empty string")
    if any(ord(character) < 33 or ord(character) > 126 for character in raw_url):
        raise ValueError("HTTP URL must contain only printable ASCII characters")
    if _INVALID_PERCENT_ESCAPE_RE.search(raw_url):
        raise ValueError("HTTP URL contains an invalid percent escape")

    parsed = urlsplit(raw_url)
    hostname = parsed.hostname or ""
    # Accessing port performs urllib's numeric and range validation.
    _ = parsed.port
    if parsed.scheme.lower() not in {"http", "https"} or not hostname:
        raise ValueError("HTTP URL must be absolute")
    return parsed


def _validated_base_url(raw_url: str, variable_name: str) -> str:
    """Validate an endpoint override without echoing sensitive URL components."""
    base = raw_url.rstrip("/")
    try:
        parsed = parse_http_url(base)
    except (TypeError, ValueError):
        parsed = None
    if parsed is None:
        raise ConfigError(f"{variable_name} must be an absolute HTTP(S) URL")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigError(f"{variable_name} must not contain credentials/userinfo")
    if parsed.query or parsed.fragment:
        raise ConfigError(f"{variable_name} must not contain a query or fragment")
    return base


def build_endpoints(config: UploaderConfig) -> EndpointSet:
    """Build immutable agentless or EVP endpoint URLs."""
    site = normalize_dd_site(config.site)
    if config.agentless:
        if config.agentless_url:
            base = _validated_base_url(
                config.agentless_url,
                "DD_TEST_OPTIMIZATION_AGENTLESS_URL",
            )
            return EndpointSet(
                agentless=True,
                site=site,
                test_url=f"{base}/api/v2/citestcycle",
                coverage_url=f"{base}/api/v2/citestcov",
                telemetry_url=f"{base}/api/v2/apmtelemetry",
            )
        return EndpointSet(
            agentless=True,
            site=site,
            test_url=f"https://citestcycle-intake.{site}/api/v2/citestcycle",
            coverage_url=f"https://citestcov-intake.{site}/api/v2/citestcov",
            telemetry_url=(
                f"https://instrumentation-telemetry-intake.{site}/api/v2/apmtelemetry"
            ),
        )

    base = _validated_base_url(
        config.agent_url,
        "DD_TEST_OPTIMIZATION_AGENT_URL",
    )
    return EndpointSet(
        agentless=False,
        site=site,
        test_url=f"{base}/evp_proxy/v2/api/v2/citestcycle",
        coverage_url=f"{base}/evp_proxy/v2/api/v2/citestcov",
        telemetry_url=f"{base}/telemetry/proxy/api/v2/apmtelemetry",
    )
