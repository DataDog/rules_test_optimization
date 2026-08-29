# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Endpoint and DD_SITE normalization shared by every worker."""

from __future__ import annotations

from dataclasses import dataclass
import re
from urllib.parse import urlsplit

from .config import ConfigError, UploaderConfig


_VALID_HOSTNAME_RE = re.compile(
    r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"
)


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


def _validated_base_url(raw_url: str, variable_name: str) -> str:
    """Validate an endpoint override without echoing sensitive URL components."""
    base = raw_url.rstrip("/")
    try:
        parsed = urlsplit(base)
        hostname = parsed.hostname or ""
        # Accessing port performs urllib's numeric and range validation.
        _ = parsed.port
        valid = (
            parsed.scheme.lower() in {"http", "https"}
            and bool(hostname)
            and not any(
                ord(character) <= 32 or ord(character) == 127
                for character in hostname
            )
        )
    except (TypeError, ValueError):
        valid = False
        parsed = None
    if not valid:
        raise ConfigError(f"{variable_name} must be an absolute HTTP(S) URL")
    if parsed is not None and (
        parsed.username is not None or parsed.password is not None
    ):
        raise ConfigError(f"{variable_name} must not contain credentials/userinfo")
    if parsed is not None and (parsed.query or parsed.fragment):
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
