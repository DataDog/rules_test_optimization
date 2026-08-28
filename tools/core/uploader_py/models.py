# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Small immutable values shared by uploader coordinator and workers."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path


MAX_TEST_PAYLOAD_BYTES = 4_718_592
DEFAULT_WORKERS = 4


class PayloadType(str, Enum):
    """Payload protocols supported by every uploader worker."""

    TEST = "test"
    COVERAGE = "coverage"
    TELEMETRY = "telemetry"


class FileStatus(str, Enum):
    """Terminal source-file outcomes returned to the coordinator."""

    SUCCEEDED = "succeeded"
    FAILED = "failed"
    SKIPPED = "skipped"


@dataclass(frozen=True)
class FileTask:
    """One source file owned by exactly one worker."""

    task_id: str
    source_path: Path
    display_path: str
    payload_type: PayloadType
    test_outputs_dir: Path | None = None
    output_key: str | None = None
    target_label: str | None = None


@dataclass(frozen=True)
class FileResult:
    """Immutable worker result aggregated by the coordinator."""

    task_id: str
    source_path: str
    payload_type: PayloadType
    status: FileStatus
    events: int = 0
    chunks_created: int = 0
    chunks_uploaded: int = 0
    chunks_failed: int = 0
    requests_planned: int = 0
    requests_attempted: int = 0
    requests_succeeded: int = 0
    requests_failed: int = 0
    retries: int = 0
    source_deleted: bool = False
    warning_codes: tuple[str, ...] = ()
    failure_code: str | None = None
    failure_message: str | None = None
