"""Public WORKSPACE macro for configuring the Orchestrion tool repository."""

load(
    "//go/private/orchestrion:extensions.bzl",
    "DEFAULT_DD_TRACE_GO_VERSION",
    "orchestrion_build_repository",
)

_DEFAULT_TOOL_REPO_NAME = "rules_go_orchestrion_tool"

def go_orchestrion_tool_repo(
        name = _DEFAULT_TOOL_REPO_NAME,
        version = "",
        dd_trace_go_version = "",
        dd_trace_go_versions = None,
        enabled_by_env = False,
        go_sdk_root = "",
        go_sdk_version = "",
        log_timing = False):
    """Create the `rules_go_orchestrion_tool` repository in WORKSPACE mode.

    Args:
      name: Repository name to create. Must remain
        `rules_go_orchestrion_tool` because the current fork's public aliases
        resolve that repository name internally.
      version: Required Orchestrion version tag to build from source.
      dd_trace_go_version: Shared dd-trace-go version to validate against the
        target module when instrumentation is enabled.
      dd_trace_go_versions: Optional per-module dd-trace-go version mapping.
        Mutually exclusive with `dd_trace_go_version`.
      enabled_by_env: Gate repository materialization on the Test Optimization
        repository environment. Generic Orchestrion callers should keep the
        default.
      go_sdk_root: Optional label string for a hermetic Go SDK ROOT marker.
        When set, the enabled repository builds Orchestrion with that SDK
        instead of searching for Go on the host.
      go_sdk_version: Optional declared version for `go_sdk_root`. When set,
        bootstrap can restore an existing cache entry before materializing the
        SDK and verifies the declared value on cache miss.
      log_timing: Emit structured bootstrap timing probes while building the
        Orchestrion tool repository.
    """
    if name != _DEFAULT_TOOL_REPO_NAME:
        fail(
            "go_orchestrion_tool_repo: name must be rules_go_orchestrion_tool because this rules_go fork resolves that repository name internally",
        )

    if dd_trace_go_versions == None:
        dd_trace_go_versions = {}

    if dd_trace_go_version and dd_trace_go_versions:
        fail("go_orchestrion_tool_repo: dd_trace_go_version and dd_trace_go_versions cannot both be set")

    if not version:
        fail("go_orchestrion_tool_repo: version is required in WORKSPACE mode")

    if not dd_trace_go_version and not dd_trace_go_versions:
        dd_trace_go_version = DEFAULT_DD_TRACE_GO_VERSION

    orchestrion_build_repository(
        name = name,
        version = version,
        dd_trace_go_version = dd_trace_go_version,
        dd_trace_go_versions = dd_trace_go_versions,
        enabled_by_env = enabled_by_env,
        go_sdk_root = go_sdk_root,
        go_sdk_version = go_sdk_version,
        log_timing = log_timing,
    )
