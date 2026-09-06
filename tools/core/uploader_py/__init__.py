# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Expose the stable public surface of the cross-platform uploader package.

The narrow package boundary prevents callers from depending on internal stages.
"""

from .models import MAX_TEST_PAYLOAD_BYTES

__all__ = ["MAX_TEST_PAYLOAD_BYTES"]
