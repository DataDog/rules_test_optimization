# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Provide one cross-platform process lock per Bazel workspace.

Serializing invocations prevents races over source deletion and staging cleanup.
"""

from __future__ import annotations

from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import tempfile
import time
from typing import BinaryIO, Callable, Iterator


DEFAULT_LOCK_ATTEMPTS = 3
DEFAULT_LOCK_RETRY_SECONDS = 1.0
DEFAULT_INCOMPLETE_LOCK_STALE_SECONDS = 30.0


class WorkspaceLockError(RuntimeError):
    """The uploader could not safely acquire its workspace lock."""


def workspace_lock_name(workspace: str | Path) -> str:
    """Return the legacy lock name for an exact workspace path string."""
    # Keep the legacy digest so Python and the Bash/PowerShell uploaders
    # contend on the same lock during rollout. The digest only names a local
    # lock; it is not used for a security purpose.
    digest = hashlib.md5(
        str(workspace).encode("utf-8"),
        usedforsecurity=False,
    ).hexdigest()[:8]
    return f"dd_upload_payloads_{digest}.lock"


def _default_process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


class WorkspaceLock:
    """Own one uploader lock until explicitly released or context exit.

    Unix uses the legacy atomic directory plus PID metadata and serializes
    acquisition/reclamation with a small advisory guard lock. Windows holds a
    non-blocking byte-range lock for the lifetime of the process, matching the
    lifetime semantics of PowerShell's exclusive file handle without requiring
    .NET or third-party packages.
    """

    def __init__(
        self,
        workspace: str | Path,
        *,
        temp_root: Path | None = None,
        attempts: int = DEFAULT_LOCK_ATTEMPTS,
        retry_seconds: float = DEFAULT_LOCK_RETRY_SECONDS,
        incomplete_stale_seconds: float = DEFAULT_INCOMPLETE_LOCK_STALE_SECONDS,
        sleeper: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.time,
        process_alive: Callable[[int], bool] = _default_process_alive,
        platform: str = os.name,
    ) -> None:
        if attempts <= 0:
            raise ValueError("lock attempts must be positive")
        if retry_seconds < 0:
            raise ValueError("lock retry seconds must be non-negative")
        self.workspace = str(workspace)
        self.temp_root = Path(temp_root or tempfile.gettempdir()).resolve()
        self.path = self.temp_root / workspace_lock_name(self.workspace)
        self.attempts = attempts
        self.retry_seconds = retry_seconds
        self.incomplete_stale_seconds = incomplete_stale_seconds
        self._sleeper = sleeper
        self._clock = clock
        self._process_alive = process_alive
        self._platform = platform
        self._owned = False
        self._windows_lock_file: BinaryIO | None = None

    @property
    def acquired(self) -> bool:
        return self._owned

    def acquire(self) -> "WorkspaceLock":
        if self._owned:
            raise WorkspaceLockError(f"workspace lock is already acquired: {self.path}")
        if not self.temp_root.is_dir():
            raise WorkspaceLockError(
                f"temporary root for workspace lock is not a directory: {self.temp_root}"
            )
        if self._platform == "nt":
            self._acquire_windows()
        else:
            self._acquire_unix()
        return self

    def release(self) -> None:
        if not self._owned:
            return
        if self._platform == "nt":
            self._release_windows()
        else:
            self._release_unix()
        self._owned = False

    def __enter__(self) -> "WorkspaceLock":
        return self.acquire()

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.release()

    def _acquire_unix(self) -> None:
        # Stale inspection and removal must be one Python-process critical
        # section. Otherwise a contender can replace the stale directory after
        # inspection and have its newly acquired lock removed by this process.
        with self._unix_guard():
            self._acquire_unix_guarded()

    def _acquire_unix_guarded(self) -> None:
        last_detail = "lock remained unavailable"
        for attempt in range(self.attempts):
            try:
                self.path.mkdir()
            except FileExistsError:
                lock_state = self._inspect_unix_lock()
                if lock_state == "dead":
                    last_detail = "stale lock could not be removed"
                    self._remove_unix_lock_if_simple()
                    continue
                if lock_state == "alive":
                    raise WorkspaceLockError(
                        f"another uploader is already running (lock: {self.path})"
                    )
                last_detail = "lock has fresh or unreadable PID metadata"
                if attempt + 1 < self.attempts:
                    self._sleeper(self.retry_seconds)
                continue
            except OSError as exc:
                raise WorkspaceLockError(
                    f"failed to create workspace lock {self.path}: {exc}"
                ) from exc

            try:
                pid_path = self.path / "pid"
                with pid_path.open("x", encoding="ascii") as pid_file:
                    pid_file.write(f"{os.getpid()}\n")
            except OSError as exc:
                self._remove_unix_lock_if_simple()
                raise WorkspaceLockError(
                    f"failed to initialize workspace lock metadata at {self.path / 'pid'}: {exc}"
                ) from exc
            self._owned = True
            return

        raise WorkspaceLockError(
            f"could not acquire workspace lock {self.path}: {last_detail}"
        )

    def _inspect_unix_lock(self) -> str:
        """Return ``alive``, ``dead``, or ``incomplete`` for an existing lock."""
        if self.path.is_symlink() or not self.path.is_dir():
            return "incomplete"
        try:
            pid_text = (self.path / "pid").read_text(encoding="ascii").strip()
        except (FileNotFoundError, OSError, UnicodeError):
            return "dead" if self._incomplete_lock_is_stale() else "incomplete"
        if not pid_text.isdecimal() or int(pid_text) <= 0:
            return "dead" if self._incomplete_lock_is_stale() else "incomplete"
        return "alive" if self._process_alive(int(pid_text)) else "dead"

    def _incomplete_lock_is_stale(self) -> bool:
        try:
            age = self._clock() - self.path.stat().st_mtime
        except OSError:
            return False
        return age > self.incomplete_stale_seconds

    def _remove_unix_lock_if_simple(self) -> bool:
        """Remove only the exact lock and expected PID file, never a tree."""
        if self.path.is_symlink() or not self.path.is_dir():
            return False
        try:
            if any(child.name != "pid" for child in self.path.iterdir()):
                return False
            (self.path / "pid").unlink(missing_ok=True)
            self.path.rmdir()
            return True
        except FileNotFoundError:
            return True
        except OSError:
            return False

    def _release_unix(self) -> None:
        try:
            with self._unix_guard():
                self._release_unix_guarded()
        except WorkspaceLockError:
            # Failure to enter the cleanup guard must not replace an already
            # completed upload result. The PID directory remains recoverable as
            # a stale lock on the next invocation.
            return

    def _release_unix_guarded(self) -> None:
        # Only an instance that successfully created the lock reaches this
        # method. Refuse to remove it if PID metadata no longer identifies us.
        if self.path.is_symlink() or not self.path.is_dir():
            return
        try:
            pid_text = (self.path / "pid").read_text(encoding="ascii").strip()
        except (OSError, UnicodeError):
            return
        if pid_text != str(os.getpid()):
            return
        self._remove_unix_lock_if_simple()

    @contextmanager
    def _unix_guard(self) -> Iterator[None]:
        """Serialize Python lock lifecycle changes without changing lock parity."""
        try:
            import fcntl
        except ImportError as exc:  # pragma: no cover - guarded by Unix CI
            raise WorkspaceLockError("Unix locking support is unavailable") from exc

        guard_path = self.path.with_name(self.path.name + ".guard")
        guard_file: BinaryIO | None = None
        try:
            guard_file = guard_path.open("a+b")
            fcntl.flock(guard_file.fileno(), fcntl.LOCK_EX)
            yield
        except OSError as exc:
            raise WorkspaceLockError(
                f"failed to coordinate workspace lock {self.path}: {exc}"
            ) from exc
        finally:
            if guard_file is not None:
                try:
                    fcntl.flock(guard_file.fileno(), fcntl.LOCK_UN)
                finally:
                    guard_file.close()

    def _acquire_windows(self) -> None:
        try:
            import msvcrt
        except ImportError as exc:  # pragma: no cover - guarded by Windows CI
            raise WorkspaceLockError("Windows locking support is unavailable") from exc

        last_lock_error: OSError | None = None
        for attempt in range(self.attempts):
            lock_file: BinaryIO | None = None
            try:
                lock_file = self.path.open("a+b")
                lock_file.seek(0, os.SEEK_END)
                if lock_file.tell() == 0:
                    lock_file.write(b"\0")
                    lock_file.flush()
                lock_file.seek(0)
                msvcrt.locking(lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                last_lock_error = exc
                if lock_file is not None:
                    lock_file.close()
                if attempt + 1 < self.attempts:
                    self._sleeper(self.retry_seconds)
                continue
            self._windows_lock_file = lock_file
            self._owned = True
            return

        raise WorkspaceLockError(
            "another uploader is already running "
            f"(lock: {self.path}): {last_lock_error}"
        )

    def _release_windows(self) -> None:
        try:
            import msvcrt
        except ImportError:  # pragma: no cover - guarded by Windows CI
            return
        lock_file = self._windows_lock_file
        self._windows_lock_file = None
        if lock_file is None:
            return
        try:
            lock_file.seek(0)
            msvcrt.locking(lock_file.fileno(), msvcrt.LK_UNLCK, 1)
        finally:
            lock_file.close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            # Another process may already have opened the persistent lock file.
            pass
