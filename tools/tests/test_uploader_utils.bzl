# Unit tests for uploader template rendering (placeholder and brace handling).
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//tools:test_optimization_uploader.bzl",
    "build_codeowners_lookup_order_for_tests",
    "compile_codeowners_regex_for_tests",
    "glob_to_regex_for_tests",
    "render_template_for_tests",
)

def _render_template_substitution_test(ctx):
    env = unittest.begin(ctx)
    template = "A {x} B {{y}} C {z}"
    out = render_template_for_tests(template, {"x": 1, "z": "Z"})
    asserts.equals(env, "A 1 B {y} C Z", out)
    return unittest.end(env)

def _render_template_unescape_only_test(ctx):
    env = unittest.begin(ctx)
    template = "hello {{world}}"
    out = render_template_for_tests(template, {})
    asserts.equals(env, "hello {world}", out)
    return unittest.end(env)

def _render_template_missing_placeholder_test(ctx):
    env = unittest.begin(ctx)
    template = "X {missing} Y {value} Z"
    out = render_template_for_tests(template, {"value": "V"})
    asserts.equals(env, "X {missing} Y V Z", out)
    return unittest.end(env)

def _codeowners_glob_to_regex_test(ctx):
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

def _codeowners_compile_regex_test(ctx):
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
    asserts.equals(env, "(^|.*/).*($|/.*)", compile_codeowners_regex_for_tests("**"))
    # Root-only slash is not a valid CODEOWNERS rule.
    asserts.equals(env, "", compile_codeowners_regex_for_tests("/"))
    return unittest.end(env)

def _codeowners_lookup_order_test(ctx):
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

render_template_substitution_test = unittest.make(_render_template_substitution_test)
render_template_unescape_only_test = unittest.make(_render_template_unescape_only_test)
render_template_missing_placeholder_test = unittest.make(_render_template_missing_placeholder_test)
codeowners_glob_to_regex_test = unittest.make(_codeowners_glob_to_regex_test)
codeowners_compile_regex_test = unittest.make(_codeowners_compile_regex_test)
codeowners_lookup_order_test = unittest.make(_codeowners_lookup_order_test)
codeowners_lookup_order_empty_script_dir_test = unittest.make(_codeowners_lookup_order_empty_script_dir_test)
