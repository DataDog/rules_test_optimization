# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Severity policy for host-side Test Optimization diagnostics, not test output."""

import os
from typing import Mapping

LEVELS = {"DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40}
ENVIRONMENT_VARIABLE = "DD_TEST_OPTIMIZATION_LOG_LEVEL"


def resolve_log_level(environ: Mapping[str, str] | None = None, *, debug: bool = False) -> str:
    """An explicit level overrides legacy debug settings; empty means unset."""
    env = os.environ if environ is None else environ
    level = env.get(ENVIRONMENT_VARIABLE, "").strip().upper()
    if level:
        if level not in LEVELS:
            # Do not echo an arbitrary environment value: it might be a secret.
            raise ValueError(f"{ENVIRONMENT_VARIABLE} must be ERROR, WARN, INFO, or DEBUG")
        return level
    legacy_debug = env.get("DD_TEST_OPTIMIZATION_DEBUG", "").strip().lower() in {
        "1", "true", "yes", "on",
    }
    return "DEBUG" if debug or legacy_debug else "INFO"


def enabled(severity: str, *, level: str | None = None, debug: bool = False) -> bool:
    """Test a diagnostic's severity without affecting its associated operation."""
    return LEVELS[severity] >= LEVELS[level or resolve_log_level(debug=debug)]
