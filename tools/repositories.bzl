# WORKSPACE helper: dd_test_opt_repositories
#
# Call this from your WORKSPACE to instantiate the Datadog Test Optimization
# sync repository with sensible defaults.

load("//tools:test_optimization_sync.bzl", "test_optimization_sync")

def dd_test_opt_repositories(
        name = "test_optimization_data",
        out_dir = None,
        service = None,
        runtime_name = None,
        runtime_version = None,
        runtime_arch = None,
        knowntests = True,
        test_management = True,
        debug = False):
    """Installs the sync repository via WORKSPACE.

    Mirror of the repository rule attributes with defaults. See README for env
    variables that affect fetching (DD_API_KEY, DD_SITE, etc.).
    """
    test_optimization_sync(
        name = name,
        out_dir = out_dir,
        service = service,
        runtime_name = runtime_name,
        runtime_version = runtime_version,
        runtime_arch = runtime_arch,
        knowntests = knowntests,
        test_management = test_management,
        debug = debug,
    )


