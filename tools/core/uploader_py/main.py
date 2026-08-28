# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Command entrypoint for the Python uploader runtime."""

from __future__ import annotations

import sys
from typing import Sequence


MINIMUM_PYTHON = (3, 10)


def python_version_is_supported(major: int, minor: int) -> bool:
    """Return whether an interpreter satisfies the uploader runtime contract."""
    return (major, minor) >= MINIMUM_PYTHON


def main(argv: Sequence[str] | None = None) -> int:
    """Validate startup and configuration before entering uploader preflight."""
    if not python_version_is_supported(sys.version_info.major, sys.version_info.minor):
        print(
            "[dd-uploader] error: Python 3.10 or newer is required "
            f"(found {sys.version_info.major}.{sys.version_info.minor})",
            file=sys.stderr,
        )
        return 2

    from .config import ConfigError, parse_uploader_config, validate_upload_credentials
    from .endpoints import build_endpoints
    from .logging_utils import configure_logging
    from topt_runtime.runfiles import RunfileResolutionError, RunfilesResolver

    try:
        config = parse_uploader_config(sys.argv[1:] if argv is None else argv)
        validate_upload_credentials(config)
        endpoints = build_endpoints(config)
    except ConfigError as exc:
        print(f"[dd-uploader] error: {exc}", file=sys.stderr)
        return 2

    logger = configure_logging(debug=config.debug, secrets=(config.api_key,))
    try:
        resolver = RunfilesResolver.from_environment(argv0=sys.argv[0])
    except RunfileResolutionError as exc:
        logger.error("%s", exc)
        return 2
    from .application import run_uploader

    try:
        return run_uploader(
            config,
            resolver=resolver,
            endpoints=endpoints,
            logger=logger,
        )
    except KeyboardInterrupt:
        logger.error("interrupted")
        return 130
