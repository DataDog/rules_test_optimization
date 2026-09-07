#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Bootstrap the shared uploader package from a stable Bazel entrypoint.

Keeping this file behavior-free lets both platform launchers invoke one runtime.
"""

from uploader_py.main import main


raise SystemExit(main())
