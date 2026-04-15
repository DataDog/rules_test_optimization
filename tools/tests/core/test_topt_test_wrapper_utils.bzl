"""Unit tests for the shared non-Go test wrapper helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//tools/core:topt_test_wrapper.bzl",
    "render_windows_wrapper_content_for_tests",
)

def _windows_wrapper_uses_runfiles_resolution_test(ctx):
    """Validate Windows wrappers resolve raw executables via runfiles."""
    env = unittest.begin(ctx)
    content = render_windows_wrapper_content_for_tests("src/dotnet-project/hello_test__raw_dotnet_test.dll.bat")

    asserts.true(env, 'set "ACTUAL_RLOC=src/dotnet-project/hello_test__raw_dotnet_test.dll.bat"' in content)
    asserts.true(env, 'call :resolve_runfile "%ACTUAL_RLOC%"' in content)
    asserts.true(env, 'if not "%RUNFILES_DIR%"=="" if exist "%RUNFILES_DIR%\\%CAND_PATH%"' in content)
    asserts.true(env, 'if not "%RUNFILES_MANIFEST_FILE%"=="" if exist "%RUNFILES_MANIFEST_FILE%"' in content)
    asserts.true(env, 'call :try_runfile "_main/%INPUT%"' in content)
    asserts.true(env, 'if /I "%ACTUAL_EXT%"==".bat" goto :run_batch' in content)
    asserts.true(env, 'call "%ACTUAL%" %*' in content)
    return unittest.end(env)

windows_wrapper_uses_runfiles_resolution_test = unittest.make(_windows_wrapper_uses_runfiles_resolution_test)
