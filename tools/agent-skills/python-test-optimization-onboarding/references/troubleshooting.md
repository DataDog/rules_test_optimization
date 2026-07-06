<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Python Troubleshooting

## No JSON Payloads

Check the test outputs first:

```bash
find bazel-testlogs -path "*/test.outputs/payloads/*/*.json" -type f | sort
```

If no files appear:

- Confirm the test target uses `dd_topt_py_test`.
- Confirm the target depends on `pytest` and `ddtrace`.
- Confirm managed pytest mode did not receive `PYTEST_ADDOPTS=--no-ddtrace`.
- In `consumer_runner` mode, confirm the wrapper preserves `env` and runs
  pytest with the ddtrace plugin enabled.
- In WORKSPACE mode, confirm the Python companion was declared with
  `datadog_python_test_optimization_workspace_repositories(...)`.

## Missing Bazel Metadata

Check for metadata:

```bash
find bazel-testlogs -name "bazel_target_metadata.json" -type f | sort
```

If it is missing, confirm the test target uses the companion macro and not the
raw language test rule directly. For consumer-owned wrappers, the wrapper must
return an executable test target while preserving the environment passed by the
Datadog macro.

## Missing Git Metadata

Git metadata is fetched during sync, not test execution. Put `DD_GIT_*` values
in `.bazelrc` or CI as `--repo_env`, not `--test_env`:

```text
common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL
common:test-optimization --repo_env=DD_GIT_COMMIT_SHA
common:test-optimization --repo_env=DD_GIT_BRANCH
```

The doctor can scan versioned `.bazelrc` files for `--test_env=DD_GIT_*`, but
it cannot detect a bad `--test_env=DD_GIT_*` flag typed directly on the CLI.

## WORKSPACE Helper Resolution Fails

Check ordering:

- `datadog-rules-test-optimization` must be declared before loading the Python
  helper from that repository.
- `rules_python` must be declared before loading the Python companion in test
  BUILD files.
- `rules_python_repo_name` must match the consumer's actual rules_python repo.

The Python helper only declares `datadog-rules-test-optimization-python`; it is
not a replacement for the consumer's Python dependency setup.

If fetching `datadog-rules-test-optimization` returns `404` in an internal or
private repository, confirm auth before changing the rule wiring. Prefer
`ssh://git@github.com/DataDog/rules_test_optimization.git` for internal git
fetches, or use an authenticated archive setup supported by the consumer's
Bazel environment. Do not commit local archive paths as a CI workaround.

## Monorepo Analysis Looks Unrelated

If tests already produced JSON payloads but doctor/uploader analysis downloads
unrelated toolchains or loads unrelated packages, the issue may be cold
monorepo state or target placement, not payload generation. Move the logical
doctor/uploader pair to a lightweight package such as `//tools/test_optimization`
and run those package-local labels before changing instrumentation.

If metadata refetches repeatedly, check whether `.bazelrc` or scripts set
`FETCH_SALT` by default. It should appear only in an explicit
`bazel sync --only=<repo> --repo_env=FETCH_SALT="$(date +%s)"` force-refresh
command.

## Remote Outputs Missing

If tests use remote execution or remote cache, add:

```text
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
test:test-optimization --zip_undeclared_test_outputs
```

Pass the matching BEP files to doctor/uploader with repeatable
`--bep-json=<path>` plus `--freshness-source=bep`,
`--freshness-mode=required`, `--artifact-source=bep`, and
`--artifact-staging-dir=<temp-dir>`.

If BEP still points at HTTP/HTTPS `outputs.zip` artifacts, add
`--artifact-source=bep --remote-artifacts=download`; no downloader is required
unless the endpoint needs custom auth. For bytestream/CAS/custom-auth artifact
providers, also configure `--bep-artifact-downloader=/path/to/downloader`. Use
`--remote-artifacts=required` only when the rollout should fail if any selected
artifact cannot be materialized.

If local outputs may be stale while BEP can stage fresh carriers, consider
`--artifact-source=auto --remote-artifacts=download` so staged outputs win for
matching BEP output keys.

Then re-run tests before running doctor and uploader.

## Diagnostic Reports

When logs are long or ambiguous, first ask for a doctor-only support bundle with
`bazel run //:dd_test_optimization_doctor -- --support-bundle=<path>` plus any
matching BEP/artifact flags. Use the CI wrapper bundle when uploader dry-run or
upload results matter. If a repository cannot use either bundle mode, collect
`doctor-report.json`, `uploader-dry-run-report.json`, optional
`uploader-upload-report.json`, then use `create_support_bundle.py` manually if
the helper is available. Render `upload-diagnostics.md` only as a Markdown
fallback.

- Doctor: pass `--support-bundle=<path>` for the redacted doctor-only zip, or
  `--report-json=<path>` for the raw machine-readable doctor report.
- Uploader: pass `--report-json=<path>` after the uploader target's `--`
  separator, or set `DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON`.
- Wrapper: prefer `--report-dir=<path>` plus `--support-bundle=<path>`, or set
  `DD_TEST_OPTIMIZATION_REPORT_DIR` and
  `DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE`, so CI archives both individual reports
  and `dd-test-optimization-support.zip`.

Use the support bundle to compare `result.reason_code`, next steps, expected
targets, BEP freshness, artifact staging, payload directories, payload counts,
status, exit code, effective flags, runtime metadata, and selected BEP summaries
without reading the full CI log. Wrapper bundles also include upload attempts
and upload failures.
`tools/test_optimization/render_report_summary.py` can render raw JSON files as
a short Markdown fallback summary. Review raw reports for internal paths and
target names before sharing outside the trusted project boundary.

Support bundle intake order:

1. Read `summary.md` for the support-facing failure classification.
2. Read `diagnostics.json` for `summary.status`,
   `summary.primary_reason_code`, report count, BEP summary count, and payload
   counts.
3. Read `reports/doctor-report.json` for expected targets, seen targets,
   missing target roots, fresh/cached/remote-only BEP outputs, and artifact
   staging results.
4. If present, read `reports/uploader-dry-run-report.json` before any upload
   report. It proves payload discovery and enrichment without sending data.
5. If present, read `reports/uploader-upload-report.json` for real upload
   attempts and terminal upload failures.
6. Read `command/flags.json` to verify the test run used a unique BEP file and
   doctor/uploader used the matching `--bep-json`, freshness, artifact-source,
   artifact-staging, and remote-artifact flags.

If `command/flags.json` shows `upload_mode=doctor_only_no_uploader`, do not
claim uploader or Datadog intake behavior was validated. Ask for the wrapper
support bundle when dry-run, enrichment, or real upload behavior matters.
