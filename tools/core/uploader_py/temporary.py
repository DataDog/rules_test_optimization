# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Owned temporary directories for one uploader invocation and its tasks."""

from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
import tempfile
from typing import Callable, Iterator


class TemporaryDirectoryError(RuntimeError):
    """The uploader could not create its owned temporary directory."""


@contextmanager
def invocation_temporary_directory(
    *,
    temp_root: Path | None = None,
    on_cleanup_error: Callable[[str], None] | None = None,
) -> Iterator[Path]:
    """Create and best-effort clean one native invocation temporary root."""
    try:
        owned_directory = tempfile.TemporaryDirectory(
            prefix="dd_topt_payloads.",
            dir=str(temp_root) if temp_root is not None else None,
        )
    except OSError as exc:
        location = (
            str(temp_root)
            if temp_root is not None
            else "the platform temporary directory"
        )
        raise TemporaryDirectoryError(
            f"failed to create uploader temporary directory under {location}: {exc}"
        ) from exc
    try:
        yield Path(owned_directory.name)
    finally:
        _cleanup_owned_directory(owned_directory, on_cleanup_error)


@contextmanager
def task_temporary_directory(
    invocation_root: Path,
    task_id: str,
    *,
    on_cleanup_error: Callable[[str], None] | None = None,
) -> Iterator[Path]:
    """Create and clean a task-local child without exposing source filenames."""
    safe_task_id = "".join(
        ch if ch.isalnum() or ch in "-_" else "_" for ch in task_id
    )
    prefix = f"task_{safe_task_id or 'unknown'}."
    try:
        owned_directory = tempfile.TemporaryDirectory(
            prefix=prefix,
            dir=str(invocation_root),
        )
    except OSError as exc:
        raise TemporaryDirectoryError(
            f"failed to create task temporary directory under {invocation_root}: {exc}"
        ) from exc
    try:
        yield Path(owned_directory.name)
    finally:
        _cleanup_owned_directory(owned_directory, on_cleanup_error)


def _cleanup_owned_directory(
    owned_directory: tempfile.TemporaryDirectory,
    on_cleanup_error: Callable[[str], None] | None,
) -> None:
    """Keep cleanup failure from changing an already-known upload outcome."""
    try:
        owned_directory.cleanup()
    except OSError as exc:
        if on_cleanup_error is not None:
            on_cleanup_error(type(exc).__name__)
