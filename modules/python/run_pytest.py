# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Entry point for running pytest under Bazel's py_test rule."""

import sys

import pytest

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", "--tb=short", "--override-ini=rootdir=."] + sys.argv[1:]))
