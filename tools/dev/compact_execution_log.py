#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Read the action fields needed from a Bazel compact execution log.

Bazel's compact format is a zstd-compressed stream of length-delimited
``ExecLogEntry`` protobuf messages.  The profile verifier only needs spawn
identity, action keys, and output digests, so this module intentionally avoids
reconstructing inputs and runfiles.  Keeping that projection small lets the
public repository validate Reprise's reproducibility contract without a
protobuf runtime or an internal Datadog dependency.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import shutil
import subprocess
from typing import Iterator


class CompactExecutionLogError(ValueError):
    """Raised when a compact execution log cannot be decoded safely."""


@dataclass(frozen=True)
class CompactAction:
    """Reprise-compatible projection of one executed Bazel spawn."""

    target_label: str
    mnemonic: str
    command_args: tuple[str, ...]
    environment_variables: tuple[tuple[str, str], ...]
    listed_outputs: tuple[str, ...]
    action_key: str
    actual_outputs: tuple[tuple[str, str], ...]

    @property
    def identity(self) -> tuple[str, str, tuple[str, ...]]:
        """Return the stable cross-run identity used by Reprise."""
        return (self.target_label, self.mnemonic, self.listed_outputs)


@dataclass(frozen=True)
class _Artifact:
    path: str
    files: tuple[tuple[str, str], ...]


def read_compact_actions(path: Path) -> list[CompactAction]:
    """Return executed spawns from one Bazel compact execution log."""
    zstd = shutil.which("zstd")
    if zstd is None:
        raise CompactExecutionLogError(
            "zstd is required to read Bazel compact execution logs"
        )
    result = subprocess.run(
        [zstd, "--decompress", "--stdout", path.as_posix()],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise CompactExecutionLogError(
            "failed to decompress %s: %s"
            % (path, result.stderr.decode("utf-8", errors="replace").strip())
        )
    return list(_decode_entries(result.stdout))


def _decode_entries(data: bytes) -> Iterator[CompactAction]:
    artifacts: dict[int, _Artifact] = {}
    offset = 0
    while offset < len(data):
        size, offset = _read_varint(data, offset)
        end = offset + size
        if end > len(data):
            raise CompactExecutionLogError("truncated ExecLogEntry message")
        fields = list(_fields(data[offset:end]))
        offset = end

        entry_id = _first_varint(fields, 1)
        payload = _first_bytes(fields, 3)
        if payload is not None:
            artifacts[entry_id] = _decode_file(payload)
            continue
        payload = _first_bytes(fields, 4)
        if payload is not None:
            artifacts[entry_id] = _decode_directory(payload)
            continue
        payload = _first_bytes(fields, 5)
        if payload is not None:
            artifacts[entry_id] = _decode_symlink(payload)
            continue
        payload = _first_bytes(fields, 7)
        if payload is not None:
            yield _decode_spawn(payload, artifacts)


def _decode_file(data: bytes, parent: str = "") -> _Artifact:
    fields = list(_fields(data))
    relative = _first_text(fields, 1)
    path = _join_path(parent, relative)
    return _Artifact(path=path, files=((path, _digest_hash(fields, 2)),))


def _decode_directory(data: bytes) -> _Artifact:
    fields = list(_fields(data))
    path = _first_text(fields, 1)
    files = []
    for child in _all_bytes(fields, 2):
        files.extend(_decode_file(child, path).files)
    return _Artifact(path=path, files=tuple(files))


def _decode_symlink(data: bytes) -> _Artifact:
    fields = list(_fields(data))
    path = _first_text(fields, 1)
    return _Artifact(path=path, files=((path, ""),))


def _decode_spawn(
    data: bytes, artifacts: dict[int, _Artifact]
) -> CompactAction:
    fields = list(_fields(data))
    listed_outputs: set[str] = set()
    actual_outputs: list[tuple[str, str]] = []
    for output in _all_bytes(fields, 6):
        output_fields = list(_fields(output))
        output_id = _optional_varint(output_fields, 5)
        if output_id is not None:
            artifact = artifacts.get(output_id)
            if artifact is None:
                raise CompactExecutionLogError(
                    "spawn references unknown output id %d" % output_id
                )
            listed_outputs.add(artifact.path)
            actual_outputs.extend(artifact.files)
            continue
        invalid_path = _optional_text(output_fields, 4)
        if invalid_path is not None:
            listed_outputs.add(invalid_path)

    return CompactAction(
        target_label=_first_text(fields, 7),
        mnemonic=_first_text(fields, 8),
        command_args=tuple(_all_text(fields, 1)),
        environment_variables=tuple(
            (_first_text(env, 1), _first_text(env, 2))
            for env in (list(_fields(value)) for value in _all_bytes(fields, 2))
        ),
        listed_outputs=tuple(sorted(listed_outputs)),
        action_key=_digest_hash(fields, 16),
        actual_outputs=tuple(sorted(actual_outputs)),
    )


def _digest_hash(fields: list[tuple[int, int, int | bytes]], field: int) -> str:
    digest = _first_bytes(fields, field)
    if digest is None:
        return ""
    return _first_text(list(_fields(digest)), 1)


def _join_path(parent: str, child: str) -> str:
    if not parent:
        return child
    return (PurePosixPath(parent) / child).as_posix()


def _fields(data: bytes) -> Iterator[tuple[int, int, int | bytes]]:
    offset = 0
    while offset < len(data):
        tag, offset = _read_varint(data, offset)
        number = tag >> 3
        wire_type = tag & 7
        if number == 0:
            raise CompactExecutionLogError("protobuf field number must be non-zero")
        if wire_type == 0:
            value, offset = _read_varint(data, offset)
        elif wire_type == 1:
            end = offset + 8
            value = data[offset:end]
            offset = end
        elif wire_type == 2:
            size, offset = _read_varint(data, offset)
            end = offset + size
            value = data[offset:end]
            offset = end
        elif wire_type == 5:
            end = offset + 4
            value = data[offset:end]
            offset = end
        else:
            raise CompactExecutionLogError(
                "unsupported protobuf wire type %d" % wire_type
            )
        if offset > len(data):
            raise CompactExecutionLogError("truncated protobuf field")
        yield number, wire_type, value


def _read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise CompactExecutionLogError("truncated protobuf varint")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
    raise CompactExecutionLogError("protobuf varint exceeds 64 bits")


def _all_bytes(
    fields: list[tuple[int, int, int | bytes]], number: int
) -> Iterator[bytes]:
    for field_number, wire_type, value in fields:
        if field_number == number:
            if wire_type != 2 or not isinstance(value, bytes):
                raise CompactExecutionLogError(
                    "protobuf field %d is not length-delimited" % number
                )
            yield value


def _first_bytes(
    fields: list[tuple[int, int, int | bytes]], number: int
) -> bytes | None:
    return next(_all_bytes(fields, number), None)


def _first_text(
    fields: list[tuple[int, int, int | bytes]], number: int
) -> str:
    return (_first_bytes(fields, number) or b"").decode("utf-8")


def _optional_text(
    fields: list[tuple[int, int, int | bytes]], number: int
) -> str | None:
    value = _first_bytes(fields, number)
    return None if value is None else value.decode("utf-8")


def _all_text(
    fields: list[tuple[int, int, int | bytes]], number: int
) -> Iterator[str]:
    for value in _all_bytes(fields, number):
        yield value.decode("utf-8")


def _optional_varint(
    fields: list[tuple[int, int, int | bytes]], number: int
) -> int | None:
    for field_number, wire_type, value in fields:
        if field_number == number:
            if wire_type != 0 or not isinstance(value, int):
                raise CompactExecutionLogError(
                    "protobuf field %d is not a varint" % number
                )
            return value
    return None


def _first_varint(
    fields: list[tuple[int, int, int | bytes]], number: int
) -> int:
    return _optional_varint(fields, number) or 0
