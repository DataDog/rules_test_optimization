# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Measure phases owned by one invocation or one file worker.

Worker elapsed sums can overlap; they are never an invocation wall duration.
"""

from __future__ import annotations

from contextlib import contextmanager
import time
from typing import Callable, Iterator


class PhaseRecorder:
    """Owned phase totals; transfer between threads only with no phase active."""

    def __init__(
        self,
        clock: Callable[[], float] = time.monotonic,
        cpu_clock: Callable[[], float] = time.thread_time,
    ) -> None:
        self._clock = clock
        self._cpu_clock = cpu_clock
        self._totals: dict[str, tuple[float, float]] = {}
        self._bytes: dict[str, int] = {}

    @contextmanager
    def phase(self, name: str) -> Iterator[None]:
        started, cpu_started = self._clock(), self._cpu_clock()
        try:
            yield
        finally:
            wall, cpu = self._totals.get(name, (0.0, 0.0))
            self._totals[name] = (
                wall + max(0.0, self._clock() - started),
                cpu + max(0.0, self._cpu_clock() - cpu_started),
            )

    def snapshot(self) -> tuple[tuple[str, float, float], ...]:
        return tuple((name, wall, cpu) for name, (wall, cpu) in sorted(self._totals.items()))

    def add_bytes(self, name: str, amount: int) -> None:
        self._bytes[name] = self._bytes.get(name, 0) + amount

    def byte_counts(self) -> tuple[tuple[str, int], ...]:
        return tuple(sorted(self._bytes.items()))


def execution_environment() -> dict[str, object]:
    """Cold-path host observations; an observed cgroup is not an effective limit.

    Containers may inherit stricter ancestor quotas. Keep the mount-root values
    as observations and leave unavailable measurements explicit.
    """
    import os
    import platform
    from pathlib import Path

    def read_observation(path: str) -> str | None:
        try:
            return Path(path).read_text(encoding="ascii").strip()
        except (OSError, UnicodeError):
            return None

    affinity = None
    if hasattr(os, "sched_getaffinity"):
        try:
            affinity = len(os.sched_getaffinity(0))
        except OSError:
            pass
    return {
        "python_implementation": platform.python_implementation(),
        "python_version": platform.python_version(),
        "host_logical_cpus": os.cpu_count(),
        "affinity_cpus": affinity,
        "cgroup_v2_mount_cpu_max": read_observation("/sys/fs/cgroup/cpu.max"),
        "cgroup_v2_mount_cpu_stat": read_observation("/sys/fs/cgroup/cpu.stat"),
        "effective_cpu_quota": None,
    }
