# Unit tests for uploader template rendering (placeholder and brace handling).
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//tools/core:test_optimization_uploader.bzl",
    "bash_curl_retry_flags_for_tests",
    "build_codeowners_lookup_order_for_tests",
    "context_manifest_content_for_tests",
    "compile_codeowners_regex_for_tests",
    "first_ascii_whitespace_index_for_tests",
    "glob_to_regex_for_tests",
    "is_gitlab_section_header_line_for_tests",
    "is_gitlab_section_header_pattern_for_tests",
    "is_gitlab_section_header_pattern_powershell_for_tests",
    "render_template_for_tests",
    "resolve_runfile_manifest_bash_for_tests",
    "resolve_runfile_manifest_powershell_for_tests",
    "skip_derived_source_candidate_for_tests",
    "strip_bom_prefix_for_tests",
    "strip_workspace_prefix_bash_for_tests",
    "strip_workspace_prefix_powershell_for_tests",
    "trim_ascii_whitespace_for_tests",
)

def _bash_curl_retry_flags_test(ctx):
    """Validate baseline uploader curl retry flags."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--retry", "3", "--retry-delay", "2", "--retry-connrefused"],
        bash_curl_retry_flags_for_tests(),
    )
    asserts.false(env, "--retry-all-errors" in bash_curl_retry_flags_for_tests())
    return unittest.end(env)

def _render_template_substitution_test(ctx):
    """Validate template placeholder substitution and brace unescaping."""
    env = unittest.begin(ctx)
    template = "A {x} B {{y}} C {z}"
    out = render_template_for_tests(template, {"x": 1, "z": "Z"})
    asserts.equals(env, "A 1 B {y} C Z", out)
    return unittest.end(env)

def _render_template_unescape_only_test(ctx):
    """Validate template renderer when only brace-unescaping is needed."""
    env = unittest.begin(ctx)
    template = "hello {{world}}"
    out = render_template_for_tests(template, {})
    asserts.equals(env, "hello {world}", out)
    return unittest.end(env)

def _render_template_missing_placeholder_test(ctx):
    """Validate missing placeholders remain literal in rendered output."""
    env = unittest.begin(ctx)
    template = "X {missing} Y {value} Z"
    out = render_template_for_tests(template, {"value": "V"})
    asserts.equals(env, "X {missing} Y V Z", out)
    return unittest.end(env)

def _render_template_no_recursive_substitution_test(ctx):
    """Validate values containing placeholders are not recursively substituted."""
    env = unittest.begin(ctx)
    template = "A {x} B {z}"
    out = render_template_for_tests(template, {"x": "{z}", "z": "Z"})
    asserts.equals(env, "A {z} B Z", out)
    return unittest.end(env)

def _codeowners_glob_to_regex_test(ctx):
    """Validate common CODEOWNERS glob-to-regex translations."""
    env = unittest.begin(ctx)

    # `**/` should match from repo root or nested directories.
    asserts.equals(env, "(.*/)?foo\\.cs", glob_to_regex_for_tests("**/foo.cs"))

    # Character classes are preserved (used by patterns like [Tt]estSuite.cs).
    asserts.equals(env, "[Tt]estSuite\\.cs", glob_to_regex_for_tests("[Tt]estSuite.cs"))

    # Single-star should stay segment-local (no slash crossing).
    asserts.equals(env, "foo/[^/]*\\.cs", glob_to_regex_for_tests("foo/*.cs"))

    # Backslash escapes should force literal glob metacharacters.
    asserts.equals(env, "literal\\*\\.cs", glob_to_regex_for_tests("literal\\*.cs"))
    asserts.equals(env, "suite\\?\\.cs", glob_to_regex_for_tests("suite\\?.cs"))
    asserts.equals(env, "bracket\\[name\\]\\.cs", glob_to_regex_for_tests("bracket\\[name\\].cs"))

    # Escaped whitespace should stay inside pattern, not split owners parsing.
    asserts.equals(env, "manual/space owner\\.cs", glob_to_regex_for_tests("manual/space\\ owner.cs"))

    # `**` means "match everything", while `?` means a single non-slash char.
    asserts.equals(env, ".*", glob_to_regex_for_tests("**"))
    asserts.equals(env, "[^/]", glob_to_regex_for_tests("?"))
    return unittest.end(env)

def _codeowners_glob_to_regex_edge_cases_test(ctx):
    """Validate edge-case glob translations (classes, escapes, ** combos)."""
    env = unittest.begin(ctx)

    # Class negation and escaped class literals.
    asserts.equals(env, "[^ab]\\.cs", glob_to_regex_for_tests("[!ab].cs"))
    asserts.equals(env, "[\\^ab]\\.cs", glob_to_regex_for_tests("[^ab].cs"))
    asserts.equals(env, "literal\\[abc\\]\\.cs", glob_to_regex_for_tests("literal\\[abc\\].cs"))

    # Unterminated classes should treat '[' as a literal.
    asserts.equals(env, "unterminated\\[abc", glob_to_regex_for_tests("unterminated[abc"))

    # Trailing backslash should remain escaped.
    asserts.equals(env, "trailing\\\\", glob_to_regex_for_tests("trailing\\"))

    # Multiple **/ segments and wildcard suffix handling.
    asserts.equals(env, "(.*/)?foo/(.*/)?bar[^/]\\.go", glob_to_regex_for_tests("**/foo/**/bar?.go"))
    asserts.equals(env, "dir/.*", glob_to_regex_for_tests("dir/**"))
    return unittest.end(env)

def _codeowners_compile_regex_test(ctx):
    """Validate compiled CODEOWNERS regex for representative patterns."""
    env = unittest.begin(ctx)

    # Non-anchored patterns can match anywhere in the repo path.
    asserts.equals(env, "(^|.*/)foo($|/.*)", compile_codeowners_regex_for_tests("foo"))

    # Trailing slash marks directory-only ownership.
    asserts.equals(env, "(^|.*/)foo/.*$", compile_codeowners_regex_for_tests("foo/"))

    # Leading slash anchors pattern to repository root.
    asserts.equals(env, "^foo/bar($|/.*)", compile_codeowners_regex_for_tests("foo/bar"))
    asserts.equals(env, "^foo/[^/]*\\.cs($|/.*)", compile_codeowners_regex_for_tests("/foo/*.cs"))
    asserts.equals(env, "^(.*/)?foo\\.cs($|/.*)", compile_codeowners_regex_for_tests("**/foo.cs"))
    asserts.equals(env, "(^|.*/)literal\\*\\.cs($|/.*)", compile_codeowners_regex_for_tests("literal\\*.cs"))
    asserts.equals(env, "^manual/space owner\\.cs($|/.*)", compile_codeowners_regex_for_tests("manual/space\\ owner.cs"))

    # Bracket-only character classes are valid CODEOWNERS patterns.
    asserts.equals(env, "(^|.*/)[xy]($|/.*)", compile_codeowners_regex_for_tests("[xy]"))
    asserts.equals(env, "(^|.*/)[abc]($|/.*)", compile_codeowners_regex_for_tests("[abc]"))
    asserts.equals(env, "(^|.*/)[ABC]($|/.*)", compile_codeowners_regex_for_tests("[ABC]"))
    asserts.equals(env, "(^|.*/)[Abc]($|/.*)", compile_codeowners_regex_for_tests("[Abc]"))
    asserts.equals(env, "(^|.*/)[ABCD]($|/.*)", compile_codeowners_regex_for_tests("[ABCD]"))
    asserts.equals(env, "(^|.*/)[A1B2C3]($|/.*)", compile_codeowners_regex_for_tests("[A1B2C3]"))
    asserts.equals(env, "(^|.*/).*($|/.*)", compile_codeowners_regex_for_tests("**"))

    # Root-only slash is not a valid CODEOWNERS rule.
    asserts.equals(env, "", compile_codeowners_regex_for_tests("/"))
    return unittest.end(env)

def _codeowners_compile_regex_edge_cases_test(ctx):
    """Validate compiled regex behavior for edge-case patterns."""
    env = unittest.begin(ctx)

    # Directory ownership preserves root anchoring with slash-containing patterns.
    asserts.equals(env, "^foo/.*$", compile_codeowners_regex_for_tests("/foo/"))
    asserts.equals(env, "^foo/bar/.*$", compile_codeowners_regex_for_tests("foo/bar/"))

    # Non-anchored slashless files can match any path segment.
    asserts.equals(env, "(^|.*/)README\\.md($|/.*)", compile_codeowners_regex_for_tests("README.md"))

    # Escaped literals and bracket classes should compile deterministically.
    asserts.equals(env, "^manual/literal\\*\\.cs($|/.*)", compile_codeowners_regex_for_tests("manual/literal\\*.cs"))
    asserts.equals(env, "^manual/literal\\[ab\\]\\.cs($|/.*)", compile_codeowners_regex_for_tests("manual/literal\\[ab\\].cs"))
    asserts.equals(env, "^[ABC]($|/.*)", compile_codeowners_regex_for_tests("/[ABC]"))

    # Slash-containing patterns remain root-anchored.
    asserts.equals(env, "^dir/(.*/)?file\\.txt($|/.*)", compile_codeowners_regex_for_tests("dir/**/file.txt"))
    asserts.equals(env, "^(.*/)?x($|/.*)", compile_codeowners_regex_for_tests("**/x"))
    return unittest.end(env)

def _codeowners_section_header_classification_test(ctx):
    """Validate GitLab section-header classification rules."""
    env = unittest.begin(ctx)

    # GitLab headers with spaces should be recognized.
    asserts.true(env, is_gitlab_section_header_pattern_for_tests("[Core Team]"))
    asserts.true(env, is_gitlab_section_header_pattern_for_tests("[Release Train]"))

    # Valid bracket-class globs should not be treated as section headers.
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[xy]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[abc]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[ABC]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[Abc]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[ABCD]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[A1B2C3]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[a1b2]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[A-Z]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[!ab]"))
    asserts.false(env, is_gitlab_section_header_pattern_for_tests("[^ab]"))

    # Whole-line parsing should require a valid bracket token and whitespace delimiter.
    asserts.true(env, is_gitlab_section_header_line_for_tests("[Core Team] @org/team"))
    asserts.true(env, is_gitlab_section_header_line_for_tests("[CoreTeam]\t@org/team"))
    asserts.false(env, is_gitlab_section_header_line_for_tests("[CoreTeam]@org/team"))
    asserts.false(env, is_gitlab_section_header_line_for_tests("[ABC] @org/owner"))
    asserts.false(env, is_gitlab_section_header_line_for_tests("[A-Z] @org/range"))
    asserts.false(env, is_gitlab_section_header_line_for_tests("[Core Team"))
    return unittest.end(env)

def _codeowners_section_header_powershell_parity_test(ctx):
    """Validate Starlark and PowerShell header detection parity."""
    env = unittest.begin(ctx)
    cases = [
        ("[Core Team]", True),
        ("[Release\tTrain]", True),
        ("[CoreTeam]", True),
        ("[xy]", False),
        ("[abc]", False),
        ("[ABC]", False),
        ("[Abc]", False),
        ("[ABCD]", False),
        ("[A1B2C3]", False),
        ("[a1b2]", False),
        ("[A-Z]", False),
        ("[!ab]", False),
        ("[^ab]", False),
    ]
    for pattern, expected in cases:
        asserts.equals(env, expected, is_gitlab_section_header_pattern_for_tests(pattern))
        asserts.equals(env, expected, is_gitlab_section_header_pattern_powershell_for_tests(pattern))
    return unittest.end(env)

def _codeowners_derived_candidate_filter_test(ctx):
    """Validate derived/external source candidate filtering."""
    env = unittest.begin(ctx)

    # Derived external paths should be excluded from ownership resolution.
    main_external = "_main/" + "external/rules_go/pkg/file.go"
    asserts.true(env, skip_derived_source_candidate_for_tests("external/rules_go/pkg/file.go"))
    asserts.true(env, skip_derived_source_candidate_for_tests(main_external))

    # Normal repository-relative candidates should stay eligible.
    asserts.false(env, skip_derived_source_candidate_for_tests("manual/owned.cs"))
    asserts.false(env, skip_derived_source_candidate_for_tests("pkg/externalized/file.go"))
    asserts.false(env, skip_derived_source_candidate_for_tests("externality/file.go"))
    asserts.false(env, skip_derived_source_candidate_for_tests(""))
    return unittest.end(env)

def _strip_workspace_prefix_powershell_windows_test(ctx):
    """Validate workspace-prefix stripping and Windows case behavior."""
    env = unittest.begin(ctx)

    # Windows path matching should ignore path case.
    asserts.equals(
        env,
        "src/file.cs",
        strip_workspace_prefix_powershell_for_tests("c:/Repo/src/file.cs", "C:/repo", True),
    )
    asserts.equals(
        env,
        "",
        strip_workspace_prefix_powershell_for_tests("C:/Repo", "c:/repo", True),
    )
    asserts.equals(
        env,
        None,
        strip_workspace_prefix_powershell_for_tests("D:/Repo/src/file.cs", "C:/repo", True),
    )

    # Non-Windows mode should stay case-sensitive.
    asserts.equals(
        env,
        None,
        strip_workspace_prefix_powershell_for_tests("c:/Repo/src/file.cs", "C:/repo", False),
    )

    # Baseline parity with Bash when casing matches exactly.
    asserts.equals(
        env,
        "pkg/file.go",
        strip_workspace_prefix_bash_for_tests("/repo/pkg/file.go", "/repo"),
    )
    asserts.equals(
        env,
        "pkg/file.go",
        strip_workspace_prefix_powershell_for_tests("/repo/pkg/file.go", "/repo", False),
    )
    return unittest.end(env)

def _runfile_manifest_bash_resolution_test(ctx):
    """Validate Bash-style runfile manifest resolution logic."""
    env = unittest.begin(ctx)
    lines = [
        "\\ufeff_main/context.json /ctx/path.json",
        "_main/schema.json\t/schema/path.json",
        "repo/context.json /suffix/path.json",
        "repo\\context.json /suffix/win/path.json",
        "_main/context_crlf.json /ctx/crlf/path.json\r",
        "repo/spaced.json\t /suffix/path with spaces.json \r",
    ]
    existing = ["/ctx/path.json", "/schema/path.json", "/suffix/path.json", "/suffix/win/path.json", "/ctx/crlf/path.json", "/suffix/path with spaces.json"]
    asserts.equals(
        env,
        "/ctx/path.json",
        resolve_runfile_manifest_bash_for_tests(lines, "_main/context.json", existing),
    )
    asserts.equals(
        env,
        "/schema/path.json",
        resolve_runfile_manifest_bash_for_tests(lines, "_main/schema.json", existing),
    )
    asserts.equals(
        env,
        "/ctx/path.json",
        resolve_runfile_manifest_bash_for_tests(lines, "context.json", existing),
    )
    asserts.equals(
        env,
        "/ctx/crlf/path.json",
        resolve_runfile_manifest_bash_for_tests(lines, "_main/context_crlf.json", existing),
    )
    asserts.equals(
        env,
        "/suffix/path with spaces.json",
        resolve_runfile_manifest_bash_for_tests(lines, "spaced.json", existing),
    )

    # Non-existing exact/suffix candidates should not be returned.
    missing_lines = [
        "\\ufeffrepo/context.json /missing/path.json",
        "other/context.json /good/path.json",
    ]
    asserts.equals(
        env,
        "/good/path.json",
        resolve_runfile_manifest_bash_for_tests(missing_lines, "context.json", ["/good/path.json"]),
    )
    return unittest.end(env)

def _runfile_manifest_powershell_resolution_test(ctx):
    """Validate PowerShell-style runfile manifest resolution logic."""
    env = unittest.begin(ctx)

    # PowerShell trims path whitespace around manifest values.
    lines = [
        "context.json    /ps/path.json   ",
        "repo/fallback.json /suffix/path.json",
        "repo\\fallback_win.json\t/suffix/win/path.json",
        "\\ufeffcontext_bom.json /bom/path.json",
        "_main/context_windows.json\tC:/tmp/path with spaces/context.json\r",
    ]
    existing = ["/ps/path.json", "/suffix/path.json", "/suffix/win/path.json", "/bom/path.json", "C:/tmp/path with spaces/context.json"]
    asserts.equals(
        env,
        "/ps/path.json",
        resolve_runfile_manifest_powershell_for_tests(lines, "context.json", existing),
    )
    asserts.equals(
        env,
        "/suffix/path.json",
        resolve_runfile_manifest_powershell_for_tests(lines, "fallback.json", existing),
    )
    asserts.equals(
        env,
        "/suffix/win/path.json",
        resolve_runfile_manifest_powershell_for_tests(lines, "fallback_win.json", existing),
    )
    asserts.equals(
        env,
        "/bom/path.json",
        resolve_runfile_manifest_powershell_for_tests(lines, "context_bom.json", existing),
    )
    asserts.equals(
        env,
        "C:/tmp/path with spaces/context.json",
        resolve_runfile_manifest_powershell_for_tests(lines, "_main/context_windows.json", existing),
    )
    assert_missing = resolve_runfile_manifest_powershell_for_tests(lines, "not_found.json", existing)
    asserts.equals(env, "", assert_missing)
    return unittest.end(env)

def _runfile_manifest_parser_parity_test(ctx):
    """Validate parity between Bash and PowerShell manifest parsers."""
    env = unittest.begin(ctx)

    # Canonical fixtures where both Bash and PowerShell parsers should agree.
    lines = [
        "\\ufeff_main/context.json /ctx/path.json",
        "_main/schema.json\t/schema/path.json",
        "repo/context.json /suffix/path.json",
        "_main/trimmed.json\t /trim/path.json \r",
    ]
    existing = ["/ctx/path.json", "/schema/path.json", "/suffix/path.json", "/trim/path.json"]
    for key in ["_main/context.json", "_main/schema.json", "context.json", "_main/trimmed.json"]:
        bash_path = resolve_runfile_manifest_bash_for_tests(lines, key, existing)
        ps_path = resolve_runfile_manifest_powershell_for_tests(lines, key, existing)
        asserts.equals(env, bash_path, ps_path)
    return unittest.end(env)

def _runfile_manifest_not_found_parity_test(ctx):
    """Validate both manifest parsers return empty string for not-found key."""
    env = unittest.begin(ctx)
    lines = [
        "_main/context.json /ctx/path.json",
        "_main/schema.json /schema/path.json",
    ]
    existing = ["/ctx/path.json", "/schema/path.json"]
    bash_path = resolve_runfile_manifest_bash_for_tests(lines, "missing.json", existing)
    ps_path = resolve_runfile_manifest_powershell_for_tests(lines, "missing.json", existing)
    asserts.equals(env, "", bash_path)
    asserts.equals(env, "", ps_path)
    asserts.equals(env, bash_path, ps_path)
    return unittest.end(env)

def _context_manifest_content_test(ctx):
    """Validate bundled context manifests sort repo keys deterministically."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "repo_a\ta.short\t/a/path.json\nrepo_b\tb.short\t/b/path.json\n",
        context_manifest_content_for_tests({
            "repo_b": ("b.short", "/b/path.json"),
            "repo_a": ("a.short", "/a/path.json"),
        }),
    )
    asserts.equals(env, "", context_manifest_content_for_tests({}))
    return unittest.end(env)

def _manifest_trim_and_bom_helpers_test(ctx):
    """Validate manifest parser helper behavior for whitespace/BOM handling."""
    env = unittest.begin(ctx)
    asserts.equals(env, 3, first_ascii_whitespace_index_for_tests("abc def"))
    asserts.equals(env, -1, first_ascii_whitespace_index_for_tests("abcdef"))
    asserts.equals(env, "abc", trim_ascii_whitespace_for_tests(" \t abc \r\n"))
    asserts.equals(env, "", trim_ascii_whitespace_for_tests(" \t \r\n"))
    asserts.equals(env, "_main/context.json", strip_bom_prefix_for_tests("\\ufeff_main/context.json"))
    asserts.equals(env, "_main/context.json", strip_bom_prefix_for_tests("_main/context.json"))
    return unittest.end(env)

def _codeowners_lookup_order_test(ctx):
    """Validate CODEOWNERS lookup precedence ordering."""
    env = unittest.begin(ctx)
    with_context = build_codeowners_lookup_order_for_tests("/ctx/ws", "/repo/ws", "/script")
    asserts.equals(
        env,
        [
            "/ctx/ws/CODEOWNERS",
            "/ctx/ws/.github/CODEOWNERS",
            "/ctx/ws/.gitlab/CODEOWNERS",
            "/ctx/ws/docs/CODEOWNERS",
            "/ctx/ws/.docs/CODEOWNERS",
            "/repo/ws/CODEOWNERS",
            "/repo/ws/.github/CODEOWNERS",
            "/repo/ws/.gitlab/CODEOWNERS",
            "/repo/ws/docs/CODEOWNERS",
            "/repo/ws/.docs/CODEOWNERS",
            "./CODEOWNERS",
            "/script/CODEOWNERS",
        ],
        with_context,
    )

    without_context = build_codeowners_lookup_order_for_tests("", "/repo/ws", "/script")
    asserts.equals(
        env,
        [
            "/repo/ws/CODEOWNERS",
            "/repo/ws/.github/CODEOWNERS",
            "/repo/ws/.gitlab/CODEOWNERS",
            "/repo/ws/docs/CODEOWNERS",
            "/repo/ws/.docs/CODEOWNERS",
            "./CODEOWNERS",
            "/script/CODEOWNERS",
        ],
        without_context,
    )
    return unittest.end(env)

def _codeowners_lookup_order_empty_script_dir_test(ctx):
    """Validate CODEOWNERS lookup ordering when script dir is empty."""
    env = unittest.begin(ctx)
    without_script = build_codeowners_lookup_order_for_tests("", "/repo/ws", "")
    asserts.equals(
        env,
        [
            "/repo/ws/CODEOWNERS",
            "/repo/ws/.github/CODEOWNERS",
            "/repo/ws/.gitlab/CODEOWNERS",
            "/repo/ws/docs/CODEOWNERS",
            "/repo/ws/.docs/CODEOWNERS",
            "./CODEOWNERS",
            "CODEOWNERS",
        ],
        without_script,
    )
    return unittest.end(env)

bash_curl_retry_flags_test = unittest.make(_bash_curl_retry_flags_test)
render_template_substitution_test = unittest.make(_render_template_substitution_test)
render_template_unescape_only_test = unittest.make(_render_template_unescape_only_test)
render_template_missing_placeholder_test = unittest.make(_render_template_missing_placeholder_test)
render_template_no_recursive_substitution_test = unittest.make(_render_template_no_recursive_substitution_test)
codeowners_glob_to_regex_test = unittest.make(_codeowners_glob_to_regex_test)
codeowners_glob_to_regex_edge_cases_test = unittest.make(_codeowners_glob_to_regex_edge_cases_test)
codeowners_compile_regex_test = unittest.make(_codeowners_compile_regex_test)
codeowners_compile_regex_edge_cases_test = unittest.make(_codeowners_compile_regex_edge_cases_test)
codeowners_section_header_classification_test = unittest.make(_codeowners_section_header_classification_test)
codeowners_section_header_powershell_parity_test = unittest.make(_codeowners_section_header_powershell_parity_test)
codeowners_derived_candidate_filter_test = unittest.make(_codeowners_derived_candidate_filter_test)
strip_workspace_prefix_powershell_windows_test = unittest.make(_strip_workspace_prefix_powershell_windows_test)
runfile_manifest_bash_resolution_test = unittest.make(_runfile_manifest_bash_resolution_test)
runfile_manifest_powershell_resolution_test = unittest.make(_runfile_manifest_powershell_resolution_test)
runfile_manifest_parser_parity_test = unittest.make(_runfile_manifest_parser_parity_test)
runfile_manifest_not_found_parity_test = unittest.make(_runfile_manifest_not_found_parity_test)
context_manifest_content_test = unittest.make(_context_manifest_content_test)
manifest_trim_and_bom_helpers_test = unittest.make(_manifest_trim_and_bom_helpers_test)
codeowners_lookup_order_test = unittest.make(_codeowners_lookup_order_test)
codeowners_lookup_order_empty_script_dir_test = unittest.make(_codeowners_lookup_order_empty_script_dir_test)
