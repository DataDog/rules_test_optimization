"""Entry point for running pytest under Bazel's py_test rule."""

import sys

import pytest

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", "--tb=short", "--override-ini=rootdir=."] + sys.argv[1:]))
