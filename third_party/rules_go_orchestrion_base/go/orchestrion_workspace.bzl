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
        log_timing = log_timing,
    )
