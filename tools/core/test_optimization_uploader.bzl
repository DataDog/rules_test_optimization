"""Uploader rule implementation for Datadog CI Visibility payloads.

This file generates platform-specific uploader entrypoints (Bash + PowerShell)
at analysis time and exposes them via a normal Bazel rule (`bazel run`).

Operational model:
- Tests run hermetically and write JSON payloads to `TEST_UNDECLARED_OUTPUTS_DIR`.
- Bazel collects those files under `bazel-testlogs/**/test.outputs`.
- The uploader runs post-test and performs:
  1) payload discovery
  2) optional metadata enrichment (context + CODEOWNERS)
  3) upload to agentless or EVP endpoints
  4) cleanup of successfully uploaded files

Why generated scripts:
- Upload logic needs host-specific tooling (`bash/curl` on Unix,
  PowerShell/.NET HttpClient on Windows).
- Keeping scripts generated from one Starlark source preserves parity while
  avoiding separate hand-maintained script files.

Developer navigation:
- Starlark test helpers (manifest/CODEOWNERS parsing parity) near the top.
- `_uploader_impl` builds both script templates and wires rule outputs.
- Script templates contain the runtime behavior for discovery, enrichment,
  uploads, retries, and locking.
"""

# Usage pattern:
#   bazel test //... || test_status=$?; test_status=${test_status:-0}; DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads; exit $test_status
#
# Key features:
# - Discovers all test.outputs/ directories in bazel-testlogs automatically
# - Supports sharded tests (shard_N_of_M/) and retries (run_N_of_M/)
# - Uploads test payloads to CI Test Cycle intake
# - Uploads coverage payloads to Code Coverage intake
# - Deletes payloads after successful upload (unless DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1)
# - Uses workspace-level lock to prevent concurrent uploaders
# - Enriches payloads with context.json metadata

load(
    "//tools/core:common_utils.bzl",
    "RULES_VERSION",
    "UPLOADER_VERSION",
    "fail_with_prefix",
    "log_debug",
    "log_info",
)
load(
    "//tools/core:test_optimization_context_utils.bzl",
    _shared_apparent_repo_key_from_label_text_or_fail = "apparent_repo_key_from_label_text_or_fail",
    _context_manifest_content = "context_manifest_content",
    _context_manifest_entries_or_fail_shared = "context_manifest_entries_or_fail",
    _legacy_single_context_entry_or_fail_shared = "legacy_single_context_entry_or_fail",
)

# NOTE: `UPLOADER_VERSION` and `RULES_VERSION` are intentionally independent.
# Uploader runtime behavior can evolve without forcing a rules contract bump,
# while payload metadata still carries both for observability.

def _render_template(template, substitutions):
    """Render script template placeholders with literal-brace support."""

    # Single-pass renderer:
    # - Supports {key} placeholders.
    # - Supports escaped literal braces via {{ and }}.
    # - Avoids recursive substitutions when values contain "{other_key}".
    out = []
    n = len(template)
    skip = {}
    for i in range(n):
        if skip.get(i):
            continue
        ch = template[i]
        if ch == "{":
            # Escaped opening brace.
            if i + 1 < n and template[i + 1] == "{":
                out.append("{")
                skip[i + 1] = True
                continue

            # Placeholder candidate: {key}
            close = -1
            for j in range(i + 1, n):
                if template[j] == "}":
                    close = j
                    break
            if close > i:
                key = template[i + 1:close]
                if key in substitutions:
                    out.append(str(substitutions[key]))
                    for j in range(i + 1, close + 1):
                        skip[j] = True
                    continue

        if ch == "}" and i + 1 < n and template[i + 1] == "}":
            # Escaped closing brace.
            out.append("}")
            skip[i + 1] = True
            continue

        out.append(ch)
    return "".join(out)

# Helper to keep template booleans consistent across bash/PowerShell.
def _bool_to_str(value):
    """Return Starlark bool as lowercase string for template injection."""
    return "true" if value else "false"

def _base_template_substitutions(
        quiescent_sec,
        max_wait_sec,
        fail_on_error,
        debug,
        keep_payloads,
        filter_prefix_enabled,
        gzip_payloads,
        context_manifest_rloc,
        context_manifest_path,
        context_json_rloc,
        context_json_path,
        telemetry_facts_manifest_rloc,
        telemetry_facts_manifest_path,
        schema_json_rloc,
        schema_json_path,
        schema_validator_rloc,
        schema_validator_path):
    """Build shared template substitutions for Bash/PowerShell scripts."""
    return {
        "quiescent_sec": quiescent_sec,
        "max_wait_sec": max_wait_sec,
        "fail_on_error": _bool_to_str(fail_on_error),
        "debug": _bool_to_str(debug),
        "keep_payloads": _bool_to_str(keep_payloads),
        "filter_prefix": _bool_to_str(filter_prefix_enabled),
        "gzip_payloads": _bool_to_str(gzip_payloads),
        "uploader_version": UPLOADER_VERSION,
        "context_manifest_rloc": context_manifest_rloc,
        "context_manifest_path": context_manifest_path,
        "context_json_rloc": context_json_rloc,
        "context_json_path": context_json_path,
        "telemetry_facts_manifest_rloc": telemetry_facts_manifest_rloc,
        "telemetry_facts_manifest_path": telemetry_facts_manifest_path,
        "schema_json_rloc": schema_json_rloc,
        "schema_json_path": schema_json_path,
        "schema_validator_rloc": schema_validator_rloc,
        "schema_validator_path": schema_validator_path,
        "rules_version": RULES_VERSION,
    }

def _tokenize_template_substitutions(substitutions):
    """Convert logical substitution keys to template token placeholders."""
    tokenized = {}
    for key, value in substitutions.items():
        value_str = str(value)
        for forbidden in ["\n", "\r", "\t"]:
            if forbidden in value_str:
                fail_with_prefix("test_optimization_uploader", "template substitution '%s' contains control characters" % key)

        # Guard against shell/script-breaking interpolation primitives.
        for forbidden in ["\"", "$", "`"]:
            if forbidden in value_str:
                fail_with_prefix("test_optimization_uploader", "template substitution '%s' contains unsupported character '%s'" % (key, forbidden))
        tokenized["__DDTPL_%s__" % key.upper()] = value_str
    return tokenized

def _bash_curl_retry_flags_for_tests():
    """Expose uploader curl retry defaults for unit tests."""

    # Keep the baseline retry behavior compatible with older curl releases.
    return ["--retry", "3", "--retry-delay", "2", "--retry-connrefused"]

# Public alias for tests (avoid importing private symbols)
render_template_for_tests = _render_template
bash_curl_retry_flags_for_tests = _bash_curl_retry_flags_for_tests

def _context_manifest_content_for_tests(entries):
    """Render deterministic context-manifest content from repo/path entries."""
    return _context_manifest_content(entries)

context_manifest_content_for_tests = _context_manifest_content_for_tests

def _apparent_repo_key_from_label_text_or_fail(label_text, owner):
    """Return the apparent external repo name from external label text."""
    return _shared_apparent_repo_key_from_label_text_or_fail(label_text, owner, "test_optimization_uploader")

def _apparent_repo_key_or_fail(label):
    """Return the apparent external repo name from the attribute label text."""
    return _apparent_repo_key_from_label_text_or_fail(str(label), label)

apparent_repo_key_from_label_text_or_fail_for_tests = _apparent_repo_key_from_label_text_or_fail

def _legacy_single_context_entry_or_fail(data_files):
    """Return a single fallback entry for legacy direct context.json inputs.

    Older single-service workspaces may pass `context.json` directly, or
    wrap it in a local alias/filegroup, instead of depending on a
    `:test_optimization_context` target. That shape cannot support multi-context
    repo matching, but it should continue to work when exactly one bundled
    `context.json` exists.
    """
    return _legacy_single_context_entry_or_fail_shared(data_files, "test_optimization_uploader")

def _context_manifest_entries_or_fail(data_targets, data_files):
    """Collect bundled context.json files keyed by the source sync repo name.

    Under bzlmod, Bazel exposes canonical repo names in analysis, while payload
    metadata stores the apparent sync-repo name exported by companion macros
    (for example `test_optimization_data_python`). The generated runtime
    templates match those apparent repo names directly.

    Legacy single-context call sites may still pass `context.json` directly in
    `data` instead of a `:test_optimization_context` target. Keep that shape
    working when there is exactly one bundled `context.json`, but require
    explicit context targets for multi-context uploaders.
    """
    return _context_manifest_entries_or_fail_shared(data_targets, data_files, "test_optimization_uploader")

legacy_single_context_entry_or_fail_for_tests = _legacy_single_context_entry_or_fail

def _codeowners_glob_to_regex_for_tests(pattern):
    """Translate CODEOWNERS glob expression to regex fragment."""
    out = []
    plen = len(pattern)
    skip = {}
    for i in range(plen):
        if skip.get(i):
            continue
        ch = pattern[i]
        if ch == "\\":
            if i + 1 < plen:
                esc = pattern[i + 1]
                if esc in [".", "+", "(", ")", "{", "}", "^", "$", "|", "\\", "[", "]", "*", "?"]:
                    out.append("\\" + esc)
                else:
                    out.append(esc)
                skip[i + 1] = True
            else:
                out.append("\\\\")
            continue
        if ch == "*" and i + 1 < plen and pattern[i + 1] == "*":
            if i + 2 < plen and pattern[i + 2] == "/":
                # `**/` matches zero or more directories.
                out.append("(.*/)?")
                skip[i + 1] = True
                skip[i + 2] = True
            else:
                out.append(".*")
                skip[i + 1] = True
            continue
        if ch == "[":
            j = i + 1
            class_parts = []
            if j < plen and pattern[j] == "!":
                class_parts.append("^")
                j += 1
            elif j < plen and pattern[j] == "^":
                class_parts.append("\\^")
                j += 1
            if j < plen and pattern[j] == "]":
                class_parts.append("\\]")
                j += 1

            closed_at = -1
            for k in range(j, plen):
                class_ch = pattern[k]
                if class_ch == "]":
                    closed_at = k
                    break
                if class_ch == "\\":
                    class_parts.append("\\\\")
                elif class_ch == "^":
                    class_parts.append("\\^")
                elif class_ch == "[":
                    class_parts.append("\\[")
                else:
                    class_parts.append(class_ch)

            if closed_at >= 0:
                out.append("[" + "".join(class_parts) + "]")
                for k in range(i + 1, closed_at + 1):
                    skip[k] = True
                continue
            out.append("\\[")
            continue
        if ch == "*":
            out.append("[^/]*")
        elif ch == "?":
            out.append("[^/]")
        elif ch in [".", "+", "(", ")", "{", "}", "^", "$", "|", "\\", "]"]:
            out.append("\\" + ch)
        else:
            out.append(ch)
    return "".join(out)

def _compile_codeowners_regex_for_tests(pattern):
    """Compile one CODEOWNERS pattern into full-match regex text."""
    anchored = pattern.startswith("/")
    dir_only = pattern.endswith("/")
    if anchored:
        pattern = pattern[1:]
    if dir_only:
        pattern = pattern[:-1]
    if not pattern:
        return ""

    has_slash = "/" in pattern
    body = _codeowners_glob_to_regex_for_tests(pattern)
    prefix = "^" if (anchored or has_slash) else "(^|.*/)"
    suffix = "/.*$" if dir_only else "($|/.*)"
    return prefix + body + suffix

def _build_codeowners_lookup_order_for_tests(context_workspace, workspace_root, script_dir):
    """Return ordered CODEOWNERS candidate paths used by runtime lookup."""
    candidates = []
    if context_workspace:
        candidates.extend([
            context_workspace + "/CODEOWNERS",
            context_workspace + "/.github/CODEOWNERS",
            context_workspace + "/.gitlab/CODEOWNERS",
            context_workspace + "/docs/CODEOWNERS",
            context_workspace + "/.docs/CODEOWNERS",
        ])
    if workspace_root:
        candidates.extend([
            workspace_root + "/CODEOWNERS",
            workspace_root + "/.github/CODEOWNERS",
            workspace_root + "/.gitlab/CODEOWNERS",
            workspace_root + "/docs/CODEOWNERS",
            workspace_root + "/.docs/CODEOWNERS",
        ])
    candidates.append("./CODEOWNERS")
    candidates.append((script_dir + "/CODEOWNERS") if script_dir else "CODEOWNERS")
    return candidates

def _is_ascii_whitespace_for_tests(ch):
    """ASCII-only whitespace check used by parser helpers."""
    return ch in [" ", "\t", "\n", "\r", "\f", "\v"]

def _is_alnum_for_tests(ch):
    """Return True for ASCII alphanumeric char."""
    return (ch in "abcdefghijklmnopqrstuvwxyz") or (ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ") or (ch in "0123456789")

def _is_lower_or_digit_for_tests(ch):
    """Return True for lowercase ASCII letters and digits."""
    return (ch in "abcdefghijklmnopqrstuvwxyz") or (ch in "0123456789")

def _is_gitlab_section_header_pattern_for_tests(pattern):
    """Detect GitLab CODEOWNERS section header syntax for one pattern token."""
    if not pattern or not pattern.startswith("[") or not pattern.endswith("]"):
        return False
    inner = pattern[1:-1]
    if not inner or ("[" in inner) or ("]" in inner):
        return False
    for i in range(len(inner)):
        ch = inner[i:i + 1]
        if _is_ascii_whitespace_for_tests(ch):
            return True
    if ("-" in inner) or ("!" in inner) or ("^" in inner) or ("\\" in inner):
        return False

    # Preserve all-uppercase/digit class sets such as [ABCD] and [A1B2C3].
    all_upper_or_digit = True
    for i in range(len(inner)):
        ch = inner[i:i + 1]
        if not ((ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ") or (ch in "0123456789")):
            all_upper_or_digit = False
            break
    if all_upper_or_digit:
        return False

    # Preserve short alnum bracket classes (for example [xy], [ABC], [Abc]).
    if len(inner) <= 3:
        all_alnum = True
        for i in range(len(inner)):
            ch = inner[i:i + 1]
            if not _is_alnum_for_tests(ch):
                all_alnum = False
                break
        if all_alnum:
            return False

    # Preserve plain lowercase/digit class sets such as [abc] and [a1b2].
    all_lower_or_digit = True
    for i in range(len(inner)):
        ch = inner[i:i + 1]
        if not _is_lower_or_digit_for_tests(ch):
            all_lower_or_digit = False
            break
    if all_lower_or_digit:
        return False
    return True

def _is_gitlab_section_header_line_for_tests(line):
    """Detect GitLab section header from an entire CODEOWNERS line."""
    if not line or not line.startswith("["):
        return False
    close_idx = line.find("]")
    if close_idx <= 0:
        return False
    pattern = line[:close_idx + 1]
    rest = line[close_idx + 1:]
    if rest and not _is_ascii_whitespace_for_tests(rest[0]):
        return False
    return _is_gitlab_section_header_pattern_for_tests(pattern)

def _skip_derived_source_candidate_for_tests(candidate):
    """Return True when derived source path should be skipped."""
    if not candidate:
        return False
    main_external_prefix = "_main/" + "external/"
    return candidate.startswith("external/") or candidate.startswith(main_external_prefix)

def _is_gitlab_section_header_pattern_powershell_for_tests(pattern):
    """PowerShell-parity variant of section header pattern detection."""
    if not pattern or not pattern.startswith("[") or not pattern.endswith("]"):
        return False
    inner = pattern[1:-1]
    if not inner or ("[" in inner) or ("]" in inner):
        return False

    # Keep PowerShell behavior aligned with script implementation: section
    # headers are detected via space/tab within bracket content.
    if (" " in inner) or ("\t" in inner):
        return True
    if ("-" in inner) or ("!" in inner) or ("^" in inner) or ("\\" in inner):
        return False

    # Preserve all-uppercase/digit class sets such as [ABCD] and [A1B2C3].
    all_upper_or_digit = True
    for i in range(len(inner)):
        ch = inner[i:i + 1]
        if not ((ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ") or (ch in "0123456789")):
            all_upper_or_digit = False
            break
    if all_upper_or_digit:
        return False
    if len(inner) <= 3:
        all_alnum = True
        for i in range(len(inner)):
            ch = inner[i:i + 1]
            if not _is_alnum_for_tests(ch):
                all_alnum = False
                break
        if all_alnum:
            return False
    all_lower_or_digit = True
    for i in range(len(inner)):
        ch = inner[i:i + 1]
        if not _is_lower_or_digit_for_tests(ch):
            all_lower_or_digit = False
            break
    if all_lower_or_digit:
        return False
    return True

def _strip_workspace_prefix_bash_for_tests(path_norm, root_norm):
    """Strip normalized workspace root prefix (Bash behavior)."""
    if not path_norm or not root_norm:
        return None
    if path_norm == root_norm:
        return ""
    prefix = root_norm + "/"
    if path_norm.startswith(prefix):
        return path_norm[len(prefix):]
    return None

def _strip_workspace_prefix_powershell_for_tests(path_norm, root_norm, is_windows):
    """Strip normalized workspace root prefix (PowerShell behavior)."""
    if not path_norm or not root_norm:
        return None
    path_cmp = path_norm.lower() if is_windows else path_norm
    root_cmp = root_norm.lower() if is_windows else root_norm
    if path_cmp == root_cmp:
        return ""
    root_prefix = root_cmp + "/"
    if path_cmp.startswith(root_prefix):
        return path_norm[len(root_norm) + 1:]
    return None

def _first_ascii_whitespace_index_for_tests(value):
    """Return index of first ASCII whitespace char, or -1."""
    for i in range(len(value)):
        if _is_ascii_whitespace_for_tests(value[i:i + 1]):
            return i
    return -1

def _first_space_or_tab_index_for_tests(value):
    """Return index of first space/tab char, or -1."""
    for i in range(len(value)):
        ch = value[i:i + 1]
        if ch == " " or ch == "\t":
            return i
    return -1

def _list_contains_for_tests(items, value):
    """Deterministic list membership helper for Starlark tests."""
    for item in items:
        if item == value:
            return True
    return False

def _trim_ascii_whitespace_for_tests(value):
    """Trim leading/trailing ASCII whitespace without regex."""
    if not value:
        return ""
    start = 0
    found_start = False
    for i in range(len(value)):
        if not _is_ascii_whitespace_for_tests(value[i:i + 1]):
            start = i
            found_start = True
            break
    if not found_start:
        return ""
    end = len(value)
    for i in range(len(value)):
        idx = len(value) - 1 - i
        if not _is_ascii_whitespace_for_tests(value[idx:idx + 1]):
            end = idx + 1
            break
    if end <= start:
        return ""
    return value[start:end]

def _strip_bom_prefix_for_tests(value):
    """Remove UTF-8 BOM marker used in manifest parser test fixtures."""

    # Tests use an ASCII marker to represent UTF-8 BOM-prefixed manifest keys.
    bom_marker = "\\ufeff"
    if value.startswith(bom_marker):
        return value[len(bom_marker):]
    return value

def _resolve_runfile_manifest_bash_for_tests(manifest_lines, key, existing_paths):
    """Resolve runfile path from manifest using Bash parser semantics."""
    for idx in range(len(manifest_lines)):
        line = manifest_lines[idx]
        sep_idx = _first_ascii_whitespace_index_for_tests(line)
        if sep_idx <= 0:
            continue
        line_key = line[:sep_idx]
        if idx == 0:
            line_key = _strip_bom_prefix_for_tests(line_key)
        if line_key != key:
            continue
        path = _trim_ascii_whitespace_for_tests(line[sep_idx + 1:])
        if _list_contains_for_tests(existing_paths, path):
            return path

    for idx in range(len(manifest_lines)):
        line = manifest_lines[idx]
        sep_idx = _first_ascii_whitespace_index_for_tests(line)
        if sep_idx <= 0:
            continue
        line_key = line[:sep_idx]
        if idx == 0:
            line_key = _strip_bom_prefix_for_tests(line_key)
        if len(line_key) <= len(key):
            continue
        if not line_key.endswith(key):
            continue
        sep_pos = len(line_key) - len(key) - 1
        sep = line_key[sep_pos:sep_pos + 1]
        if sep != "/" and sep != "\\":
            continue
        path = _trim_ascii_whitespace_for_tests(line[sep_idx + 1:])
        if _list_contains_for_tests(existing_paths, path):
            return path
    return ""

def _resolve_runfile_manifest_powershell_for_tests(manifest_lines, key, existing_paths):
    """Resolve runfile path from manifest using PowerShell parser semantics."""
    for line in manifest_lines:
        line_norm = _strip_bom_prefix_for_tests(line)
        if len(line_norm) <= len(key):
            continue
        if not line_norm.startswith(key):
            continue
        sep = line_norm[len(key):len(key) + 1]
        if sep != " " and sep != "\t":
            continue
        path = _trim_ascii_whitespace_for_tests(line_norm[len(key) + 1:])
        if _list_contains_for_tests(existing_paths, path):
            return path

    for line in manifest_lines:
        line_norm = _strip_bom_prefix_for_tests(line)
        split_idx = _first_space_or_tab_index_for_tests(line_norm)
        if split_idx <= 0:
            continue
        line_key = line_norm[:split_idx]
        if len(line_key) <= len(key):
            continue
        if not line_key.endswith("/" + key) and not line_key.endswith("\\" + key):
            continue
        path = _trim_ascii_whitespace_for_tests(line_norm[split_idx + 1:])
        if _list_contains_for_tests(existing_paths, path):
            return path
    return ""

glob_to_regex_for_tests = _codeowners_glob_to_regex_for_tests
compile_codeowners_regex_for_tests = _compile_codeowners_regex_for_tests
build_codeowners_lookup_order_for_tests = _build_codeowners_lookup_order_for_tests
is_gitlab_section_header_pattern_for_tests = _is_gitlab_section_header_pattern_for_tests
is_gitlab_section_header_line_for_tests = _is_gitlab_section_header_line_for_tests
skip_derived_source_candidate_for_tests = _skip_derived_source_candidate_for_tests
is_gitlab_section_header_pattern_powershell_for_tests = _is_gitlab_section_header_pattern_powershell_for_tests
strip_workspace_prefix_bash_for_tests = _strip_workspace_prefix_bash_for_tests
strip_workspace_prefix_powershell_for_tests = _strip_workspace_prefix_powershell_for_tests
first_ascii_whitespace_index_for_tests = _first_ascii_whitespace_index_for_tests
trim_ascii_whitespace_for_tests = _trim_ascii_whitespace_for_tests
strip_bom_prefix_for_tests = _strip_bom_prefix_for_tests
resolve_runfile_manifest_bash_for_tests = _resolve_runfile_manifest_bash_for_tests
resolve_runfile_manifest_powershell_for_tests = _resolve_runfile_manifest_powershell_for_tests

def _uploader_impl(ctx):
    """Rule implementation that generates cross-platform uploader executables.

    The generated scripts perform runtime payload discovery/enrichment/upload,
    while this function stays analysis-time only (template rendering + runfiles).
    """

    # `_uploader_impl` is responsible for generating *all* runtime uploader
    # artifacts. It does not upload anything itself; it emits executable scripts
    # that run during `bazel run`.
    #
    # Responsibilities:
    # 1) collect rule attrs and data dependencies (context/schema/validator)
    # 2) render Bash and PowerShell script templates with concrete runfile paths
    # 3) emit platform launchers (`.sh`, `.ps1`, `.bat`) with consistent behavior
    # 4) return DefaultInfo exposing the correct executable for the target OS
    #
    # Keep template substitutions explicit and centralized. If new placeholders
    # are introduced, add tests in `tools/tests/core/test_uploader_utils.bzl` to
    # lock behavior and avoid cross-platform drift.
    # ------------------------------------------------------------------
    # Phase 1: Read rule attributes and discover optional runfile artifacts.
    # ------------------------------------------------------------------
    quiescent_sec = ctx.attr.quiescent_sec
    max_wait_sec = ctx.attr.max_wait_sec
    fail_on_error = ctx.attr.fail_on_error
    debug = ctx.attr.debug
    keep_payloads = ctx.attr.keep_payloads
    filter_prefix_enabled = ctx.attr.filter_prefix
    gzip_payloads = ctx.attr.gzip_payloads

    # Find bundled context.json files keyed by their apparent external repo
    # name so runtime selection can match payload-side metadata deterministically.
    context_entries = _context_manifest_entries_or_fail(ctx.attr.data, ctx.files.data)
    context_manifest = ctx.actions.declare_file(ctx.label.name + ".context_manifest")
    ctx.actions.write(
        output = context_manifest,
        content = _context_manifest_content_for_tests(context_entries),
    )
    context_manifest_rloc = context_manifest.short_path
    context_manifest_path = context_manifest.path

    context_json_rloc = ""
    context_json_path = ""
    if context_entries:
        primary_repo_key = sorted(context_entries.keys())[0]
        primary_entry = context_entries[primary_repo_key]
        context_json_rloc = primary_entry[0]
        context_json_path = primary_entry[1]

    telemetry_facts_files = []
    for f in ctx.files.data:
        if f.basename == "telemetry_facts.json":
            telemetry_facts_files.append(f)
    telemetry_facts_manifest = ctx.actions.declare_file(ctx.label.name + ".telemetry_facts_manifest")
    telemetry_facts_manifest_lines = []
    for f in telemetry_facts_files:
        telemetry_facts_manifest_lines.append("%s\t%s" % (f.short_path, f.path))
    ctx.actions.write(
        output = telemetry_facts_manifest,
        content = "\n".join(telemetry_facts_manifest_lines) + ("\n" if telemetry_facts_manifest_lines else ""),
    )
    telemetry_facts_manifest_rloc = telemetry_facts_manifest.short_path
    telemetry_facts_manifest_path = telemetry_facts_manifest.path
    schema_json_rloc = ctx.file._schema.short_path if ctx.file._schema else ""
    schema_json_path = ctx.file._schema.path if ctx.file._schema else ""
    schema_validator_rloc = ctx.file._schema_validator.short_path if ctx.file._schema_validator else ""
    schema_validator_path = ctx.file._schema_validator.path if ctx.file._schema_validator else ""

    # High-level debug of rule inputs
    log_info("Generating uploader scripts (Option 2: TEST_UNDECLARED_OUTPUTS_DIR)")
    log_debug(
        debug,
        "config",
        "Attributes → quiescent_sec=%s, max_wait_sec=%s, fail_on_error=%s, debug=%s, keep_payloads=%s, filter_prefix=%s, gzip_payloads=%s" %
        (
            quiescent_sec,
            max_wait_sec,
            fail_on_error,
            debug,
            keep_payloads,
            filter_prefix_enabled,
            gzip_payloads,
        ),
    )
    if context_entries:
        log_debug(debug, "inputs", "bundled context repos: %s" % ", ".join(sorted(context_entries.keys())))
        if primary_repo_key == "__single_context_fallback__":
            log_debug(debug, "inputs", "using legacy single-context fallback for bundled context.json")
        log_debug(debug, "inputs", "primary context.json found at: %s" % context_json_rloc)
        log_debug(debug, "inputs", "primary context.json artifact path: %s" % context_json_path)
    else:
        # Runtime script treats missing context as best-effort disablement.
        log_debug(debug, "inputs", "context.json not found in data files; enrichment disabled")
    if schema_json_rloc:
        log_debug(debug, "inputs", "schema found at: %s" % schema_json_rloc)
        log_debug(debug, "inputs", "schema artifact path: %s" % schema_json_path)
    else:
        log_debug(debug, "inputs", "schema not found in data files; validation disabled")
    if schema_validator_rloc:
        log_debug(debug, "inputs", "schema validator found at: %s" % schema_validator_rloc)
        log_debug(debug, "inputs", "schema validator artifact path: %s" % schema_validator_path)
    else:
        log_debug(debug, "inputs", "schema validator not found in data files; validation disabled")
    if ctx.files.data:
        log_debug(debug, "inputs", "Data files count: %d" % len(ctx.files.data))
        for f in ctx.files.data:
            log_debug(debug, "inputs", "  data file: %s (%s)" % (f.basename, f.short_path))

    # ------------------------------------------------------------------
    # Phase 2: Materialize Bash runtime implementation from template file.
    # ------------------------------------------------------------------
    bash_substitutions = _base_template_substitutions(
        quiescent_sec,
        max_wait_sec,
        fail_on_error,
        debug,
        keep_payloads,
        filter_prefix_enabled,
        gzip_payloads,
        context_manifest_rloc,
        context_manifest_path,
        context_json_rloc,
        context_json_path,
        telemetry_facts_manifest_rloc,
        telemetry_facts_manifest_path,
        schema_json_rloc,
        schema_json_path,
        schema_validator_rloc,
        schema_validator_path,
    )
    bash_substitutions["curl_retry_flags"] = " ".join(_bash_curl_retry_flags_for_tests())
    bash_file = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._bash_runtime_template,
        output = bash_file,
        substitutions = _tokenize_template_substitutions(bash_substitutions),
        is_executable = True,
    )
    log_debug(debug, "render", "Bash script rendered from template: %s" % ctx.file._bash_runtime_template.short_path)

    # ------------------------------------------------------------------
    # Phase 3: Materialize PowerShell runtime implementation from template file.
    # ------------------------------------------------------------------
    ps_file = ctx.actions.declare_file(ctx.label.name + ".ps1")
    ctx.actions.expand_template(
        template = ctx.file._powershell_runtime_template,
        output = ps_file,
        substitutions = _tokenize_template_substitutions(
            _base_template_substitutions(
                quiescent_sec,
                max_wait_sec,
                fail_on_error,
                debug,
                keep_payloads,
                filter_prefix_enabled,
                gzip_payloads,
                context_manifest_rloc,
                context_manifest_path,
                context_json_rloc,
                context_json_path,
                telemetry_facts_manifest_rloc,
                telemetry_facts_manifest_path,
                schema_json_rloc,
                schema_json_path,
                schema_validator_rloc,
                schema_validator_path,
            ),
        ),
        is_executable = False,
    )
    log_debug(debug, "render", "PowerShell script rendered from template: %s" % ctx.file._powershell_runtime_template.short_path)

    # ------------------------------------------------------------------
    # Phase 4: Materialize executable/script artifacts.
    # ------------------------------------------------------------------
    # Create a batch file wrapper for native Windows (calls PowerShell)
    bat_file = ctx.actions.declare_file(ctx.label.name + ".bat")
    ctx.actions.expand_template(
        template = ctx.file._batch_runtime_template,
        output = bat_file,
        substitutions = _tokenize_template_substitutions({"ps_name": ps_file.basename}),
        is_executable = True,
    )
    log_debug(debug, "outputs", "Declared outputs → bash='%s', ps='%s', bat='%s'" % (bash_file.basename, ps_file.basename, bat_file.basename))

    # ------------------------------------------------------------------
    # Phase 5: Build runfiles set and choose platform-specific executable.
    # ------------------------------------------------------------------
    # Include optional data files (e.g., context.json) in runfiles so scripts can locate them
    # Include both the PowerShell and batch files in runfiles for cross-platform support
    extra_files = []
    if ctx.file._schema:
        extra_files.append(ctx.file._schema)
    if ctx.file._schema_validator:
        extra_files.append(ctx.file._schema_validator)
    runfiles = ctx.runfiles(files = [ps_file, bat_file, context_manifest, telemetry_facts_manifest] + ctx.files.data + extra_files)
    log_debug(debug, "outputs", "Runfiles include %d data file(s) plus PowerShell and batch scripts" % len(ctx.files.data))

    # Use target-platform constraints (ConstraintValueInfo) so executable
    # selection is analysis-time deterministic across host operating systems.
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    executable = bat_file if is_windows else bash_file
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_dd_payload_uploader_rule = rule(
    implementation = _uploader_impl,
    executable = True,  # Makes it runnable via `bazel run`
    attrs = {
        "quiescent_sec": attr.int(default = 10, doc = "Seconds to wait for filesystem to settle before uploading (env: DD_TEST_OPTIMIZATION_QUIESCENT_SEC)"),
        "max_wait_sec": attr.int(default = 300, doc = "Maximum seconds to wait for payloads (env: DD_TEST_OPTIMIZATION_MAX_WAIT_SEC). Set to 0 to skip waiting when no payloads are present."),
        "fail_on_error": attr.bool(default = False, doc = "Exit with error when tests appear to have run but no payloads are found"),
        "debug": attr.bool(default = False, doc = "Enable debug logging"),
        "keep_payloads": attr.bool(default = False, doc = "Keep payload files after successful upload (env: DD_TEST_OPTIMIZATION_KEEP_PAYLOADS)"),
        "filter_prefix": attr.bool(default = False, doc = "Boolean gate: only upload files matching span_events_*.json or coverage_*.json; telemetry uploads are always eligible (env: DD_TEST_OPTIMIZATION_FILTER_PREFIX)"),
        "gzip_payloads": attr.bool(default = False, doc = "Gzip test payloads before upload (env: DD_TEST_OPTIMIZATION_GZIP)"),
        # Optional files to place in runfiles (e.g., a generated context.json)
        "data": attr.label_list(allow_files = True, doc = "Data files to include in runfiles (e.g., context.json for enrichment)"),
        # Schema + validator bundled for best-effort payload validation
        "_schema": attr.label(default = "//tools/core:schemas/agentless-schema.json", allow_single_file = True),
        "_schema_validator": attr.label(default = "//tools/core:validate_payload_schema.py", allow_single_file = True),
        # Runtime templates (kept as standalone files, not inline Starlark strings)
        "_bash_runtime_template": attr.label(default = "//tools/core:uploader_bash_runtime.sh.tpl", allow_single_file = True),
        "_powershell_runtime_template": attr.label(default = "//tools/core:uploader_powershell_runtime.ps1.tpl", allow_single_file = True),
        "_batch_runtime_template": attr.label(default = "//tools/core:uploader_batch_runtime.bat.tpl", allow_single_file = True),
        # Private attribute to detect Windows platform
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    doc = """
Uploads CI Visibility test, coverage, and telemetry payloads to Datadog.

This rule discovers all test.outputs directories in bazel-testlogs (created by
TEST_UNDECLARED_OUTPUTS_DIR), reads payload JSONs from `payloads/tests`,
`payloads/coverage`, and `payloads/telemetry`, waits for quiescence, and
uploads payloads.

Behavior model:
    1) Resolve payload roots:
       - TESTLOGS_DIR (if explicitly set and valid) wins.
       - Otherwise auto-discover bazel-testlogs from BUILD_WORKSPACE_DIRECTORY
         or current directory.
    2) Wait policy:
       - Poll for payload files until quiescent for quiescent_sec, or until
         max_wait_sec budget is exhausted.
       - If max_wait_sec=0 and no payloads are present, decide immediately.
    3) Upload mode selection:
       - Agentless mode when DD_TEST_OPTIMIZATION_AGENT_URL is unset (requires DD_API_KEY).
       - EVP mode when DD_TEST_OPTIMIZATION_AGENT_URL is set (uses EVP subdomain headers).
    4) Per-file best-effort semantics:
       - Continue uploading remaining files after individual failures.
       - Aggregate failures into final process exit code.
       - `fail_on_error=True` escalates "tests ran but no payloads" to failure.
    5) Telemetry handling:
       - Telemetry files are uploaded as raw JSON request bodies from `payloads/telemetry`.
       - URL and headers are reconstructed from uploader mode plus telemetry body fields.
       - Telemetry does not use `context.json`, CODEOWNERS enrichment, or schema validation.

Path resolution notes:
    - Runtime scripts resolve optional artifacts (context/schema/validator)
      via direct artifact path first, then runfiles lookup.
    - Runfiles lookup supports both directory runfiles and manifest-only mode.

Usage:
    # In BUILD.bazel at workspace root
    load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

    dd_payload_uploader(
        name = "dd_upload_payloads",
        data = ["@test_optimization_data//:test_optimization_context"],
    )

    # After running tests:
    bazel test //... || test_status=$?; test_status=${test_status:-0}; DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads; exit $test_status

Exit codes:
    0 - All payloads uploaded successfully (or no payloads found)
    1 - One or more uploads failed
    2 - Configuration error (invalid TESTLOGS_DIR, missing credentials, etc.)

Required environment variables for upload:
    DD_API_KEY - Datadog API key (agentless mode)
    DD_SITE - Datadog site (agentless mode, default: datadoghq.com)
    OR
    DD_TEST_OPTIMIZATION_AGENT_URL - Agent/EVP endpoint URL (agent mode)

Optional environment variables:
    TESTLOGS_DIR - Override testlogs directory (for non-standard setups)
    DD_TEST_OPTIMIZATION_AGENTLESS_URL - Override intake base URL (agentless only, test/dev)
    DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 - Retain payloads after upload
    DD_TEST_OPTIMIZATION_FILTER_PREFIX=1 - Only upload span_events_*.json and coverage_*.json (telemetry files are not filtered)
    DD_TEST_OPTIMIZATION_MAX_WAIT_SEC - Override max wait time (0 skips waiting when no payloads are present)
    DD_TEST_OPTIMIZATION_QUIESCENT_SEC - Override quiescence wait time
    DD_TEST_OPTIMIZATION_MAX_DEPTH - Limit find depth for large testlogs trees
""",
)

def dd_payload_uploader(name, visibility = None, **kwargs):
    """Macro wrapper around uploader rule with a stable visibility default.

    Most consumer repos define the uploader target at workspace root and invoke
    it from CI entrypoints that may live in other packages. Defaulting to
    `//visibility:public` avoids accidental package-default lock-down.
    """
    if visibility == None:
        visibility = ["//visibility:public"]
    _dd_payload_uploader_rule(name = name, visibility = visibility, **kwargs)
