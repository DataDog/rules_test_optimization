"""Dev-only stub repo for rules_go Orchestrion integration."""

def _orchestrion_stub_repo_impl(ctx):
    ctx.file("BUILD.bazel", """filegroup(
    name = "orchestrion",
    srcs = ["orchestrion"],
    visibility = ["//visibility:public"],
)""")
    ctx.file("orchestrion", """#!/bin/sh
set -eu

cmd="${1:-}"
case "$cmd" in
  toolexec)
    shift
    exec "$@"
    ;;
  server)
    shift
    url_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -url-file)
          url_file="${2:-}"
          shift 2
          ;;
        -url-file=*)
          url_file="${1#*=}"
          shift
          ;;
        *)
          shift
          ;;
      esac
    done
    if [ -n "$url_file" ]; then
      printf "stub://orchestrion\n" > "$url_file"
    fi
    trap 'exit 0' INT TERM
    while true; do
      sleep 1
    done
    ;;
  version)
    echo "stub-orchestrion"
    ;;
  *)
    echo "stub-orchestrion: unsupported command '$cmd'" >&2
    exit 1
    ;;
esac
""", executable = True)

orchestrion_stub_repo = repository_rule(
    implementation = _orchestrion_stub_repo_impl,
)

def _orchestrion_stub_extension_impl(module_ctx):
    for mod in module_ctx.modules:
        for call in mod.tags.stub_orchestrion:
            orchestrion_stub_repo(name = call.name)

orchestrion_stub_extension = module_extension(
    implementation = _orchestrion_stub_extension_impl,
    tag_classes = {
        "stub_orchestrion": tag_class(attrs = {
            "name": attr.string(mandatory = True),
        }),
    },
)
