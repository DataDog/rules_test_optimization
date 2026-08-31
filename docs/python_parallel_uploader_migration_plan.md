<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Python Parallel Uploader: Implementation Guide and Tracker

## Status

The Python uploader is the default. The temporary `use_python_uploader = False`
rule value keeps the legacy Bash and PowerShell runtimes available as an
explicit rollback while the remaining removal gates in this document close.

The implementation currently provides:

- one dependency-free Python 3.10+ runtime for Linux, macOS, and Windows;
- a bounded pool of homogeneous file workers;
- one complete `enrich -> validate -> split -> upload -> cleanup` pipeline per
  test file;
- equivalent complete pipelines for coverage and telemetry files;
- CODEOWNERS, context, schema, freshness, and telemetry planning before workers
  start;
- preventive test-payload splitting at `4_718_592` bytes;
- retries, dry-run, debug logs, and final human/JSON statistics;
- small platform launchers that only resolve Python, config, and the bootstrap.

This is an implementation milestone, not the end of the migration. Open
checkboxes are release gates, not deferred product ideas.

## Goals

Replace two functional uploader implementations with one portable runtime while
preserving the public uploader contract. The design must:

1. Process independent source files concurrently.
2. Give one worker exclusive ownership of a file from dequeue through cleanup.
3. Let every worker process test, coverage, and telemetry payloads.
4. Parse CODEOWNERS and other invocation-wide inputs once before worker startup.
5. Split an enriched test body before HTTP when it exceeds 4.5 MiB.
6. Keep chunks from one source ordered and stop after the first failed chunk.
7. Retry only failures that can plausibly succeed without changing the body.
8. Exercise full preparation in dry-run without HTTP or source deletion.
9. Always produce useful terminal statistics for controlled completion.
10. Prefer standard-library code and explicit data flow over framework or queue
    abstractions that are not required by the contract.

## Non-goals

- Parallelizing chunks from the same source file.
- Adding a second upload-worker pool or a prepared-payload queue.
- Adaptive splitting after HTTP `413`.
- Splitting coverage or telemetry payloads.
- Persisting resumable upload state.
- Providing a Bazel Python toolchain from the core module.
- Changing backend payload schemas or endpoint semantics.
- Keeping the legacy implementations indefinitely.

## Why Python

Recommended workflows already require host Python for the doctor and BEP
artifact staging. The uploader therefore reuses an existing operational
dependency instead of introducing a bundled Zig or other native binary.

Runtime contract:

- Python 3.10 or newer;
- standard library only;
- no public `rules_python` dependency from the core module;
- controlled exit code `2` with an actionable error when Python is unavailable.

Interpreter lookup is identical in intent on Unix and Windows:

1. `DD_TEST_OPTIMIZATION_PYTHON`
2. `PYTHON`
3. `python3`
4. `python`

## Architecture

```text
platform launcher
      |
      v
CLI + generated config
      |
      v
workspace lock
      |
      v
freshness/BEP staging + deterministic discovery
      |
      v
CODEOWNERS + contexts + schema + telemetry plan (once)
      |
      v
bounded queue<FileTask>
      |
      +--------+--------+ ... +--------+
      |        |                 |
   worker 1 worker 2          worker N
      |        |                 |
      +-- each owns one file ----+
          load / enrich / validate
          split when test > 4.5 MiB
          prepare exact request body
          upload derived requests in order
          delete source after complete success
      |
      v
immutable FileResult values
      |
      v
coordinator aggregate + final report
```

There is no synchronization between file workers beyond queue ownership and
coordinator collection. A worker never waits for another file's enrichment,
split, upload, or cleanup.

## Ownership Boundaries

### Launcher

The Bash and PowerShell Python launchers may only:

- locate a compatible interpreter;
- locate `uploader_main.py` and the generated config through Bazel runfiles;
- export the launcher directory used by CODEOWNERS discovery;
- forward arguments and the child exit code.

They must not contain discovery, enrichment, split, HTTP, retry, cleanup, or
report behavior.

### Application

The application owns the invocation lifecycle:

- configuration diagnostics;
- workspace lock lifetime;
- expected-target and freshness preflight;
- BEP staging and owned staging cleanup;
- deterministic discovery and quiescence;
- resource loading;
- coordinator invocation;
- post-worker freshness validation;
- final report emission.

### Coordinator

The coordinator owns invocation-wide worker inputs and aggregation:

- validate the snapshotted proxy configuration;
- build one immutable CODEOWNERS matcher;
- build one immutable telemetry plan;
- perform the warning-only API-key fingerprint check;
- create one shared read-only `WorkerRuntime`;
- create one HTTP transport per worker;
- run the bounded worker pool;
- convert results into one immutable `AggregateReport`.

### Worker

A worker owns exactly one `FileTask` at a time. Its complete responsibility is:

1. create task-local temporary space;
2. dispatch by payload type;
3. read and prepare the source;
4. execute every derived request sequentially;
5. delete the source only after complete success;
6. clean task-local temporary files;
7. return one immutable `FileResult`.

Workers do not mutate global counters and do not delete sources they have not
dequeued.

### Reporting

`AggregateReport` is the single source of truth for:

- compact terminal statistics;
- detailed statistics JSON;
- the backward-compatible schema-v1 report.

Report writing is atomic. A report-write failure is printed as a warning and
does not reinterpret completed uploads.

## Pre-worker Flow

The following order is intentional:

1. Parse CLI, environment, and generated config.
2. Validate endpoints and static configuration.
3. Acquire the workspace lock.
4. Resolve expected targets and local testlogs.
5. Parse freshness inputs and optionally stage BEP artifacts.
6. Wait for a stable discovery snapshot.
7. Apply expected-target and freshness selection.
8. Validate credentials only when selected files require real upload.
9. Resolve contexts, schema, and telemetry facts through one runfiles snapshot.
10. Parse CODEOWNERS and build telemetry directives once.
11. Start at most `min(workers, files)` worker threads.

The lock remains held through worker completion, staging cleanup, and final
reporting so a second uploader cannot race source deletion or staging cleanup.

## Configuration Precedence

Generated rule values are defaults. Environment overrides them, and explicit
CLI values override environment where a CLI option exists.

| Behavior | Rule | Environment | CLI |
|---|---|---|---|
| worker limit | `workers` | `DD_TEST_OPTIMIZATION_WORKERS` | `--workers` |
| debug | `debug` | `DD_TEST_OPTIMIZATION_DEBUG` | `--debug` |
| dry-run | — | — | `--dry-run` |
| enrichment assertion | — | — | `--validate-enrichment` |
| retain sources | `keep_payloads` | `DD_TEST_OPTIMIZATION_KEEP_PAYLOADS` | — |
| prefix filter | `filter_prefix` | `DD_TEST_OPTIMIZATION_FILTER_PREFIX` | — |
| gzip tests | `gzip_payloads` | `DD_TEST_OPTIMIZATION_GZIP` | — |
| CODEOWNERS override | — | `DD_TEST_OPTIMIZATION_CODEOWNERS_FILE` | — |
| report path | — | `DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON` | `--report-json` |

Invalid booleans retain legacy truth semantics; numeric values, choices, URLs,
ports, and proxy URLs fail preflight when invalid. `--validate-enrichment`
requires `--dry-run`.

## CODEOWNERS

CODEOWNERS discovery occurs once before workers start. Lookup order preserves
the existing contract, including explicit override and common GitHub/GitLab
locations.

The parser produces immutable compiled rules and preserves:

- last matching rule wins;
- escaped whitespace and comments;
- GitLab section headers;
- explicit empty-owner rules;
- source candidate normalization;
- existing producer-owned tags;
- supported-event filtering.

Workers share the matcher but keep a file-local source-to-match cache. They do
not mutate matcher rules or share per-file match state.

## Worker Pool

- The queue is bounded to apply producer backpressure.
- Threads are homogeneous and non-daemon.
- Each thread receives one private `HttpTransport`.
- Results are reordered to deterministic discovery order before reporting.
- Duplicate task IDs and mismatched result IDs are rejected.
- An unhandled file exception becomes a sanitized failed `FileResult`; it does
  not terminate unrelated workers.
- `workers=1` is the sequential compatibility baseline.

On `KeyboardInterrupt`, queued/unowned files are cancelled and retained. Files
already owned finish their current complete pipeline, all threads join, owned
temporary resources are cleaned, completed results are reported, and the
process exits `130`.

## Test Payload Pipeline

For each test JSON file, one worker performs:

1. Validate suffix and optional `span_events_` prefix filter.
2. Parse strict JSON and require a non-empty `events` array.
3. Load optional Bazel sidecar metadata.
4. Select the correct repository context.
5. Enrich top-level metadata and individual events.
6. Apply CODEOWNERS using the shared matcher.
7. Run warning-only schema validation.
8. Optionally assert expected enriched tags in dry-run.
9. Serialize and split using the preventive size contract.
10. Optionally gzip each already-split chunk.
11. Validate or upload chunks sequentially.
12. Delete the source only if every chunk succeeds.

### Preventive split contract

`MAX_TEST_PAYLOAD_BYTES = 4_718_592` is the maximum compact UTF-8 JSON body
before gzip. The worker never sends a known-oversized test request.

If the complete enriched body fits, one chunk is written. Otherwise the
splitter:

- preserves every top-level field;
- partitions only the `events` array;
- preserves event order and exactly-once membership;
- greedily fills deterministic chunks up to the limit;
- rejects an envelope or individual event that cannot fit;
- writes every exact request body in task-local temporary space before HTTP.

Chunks from one source are never parallelized. A failed chunk prevents all
later chunks and retains the source.

HTTP `413` is a terminal `payload_limit_contract_mismatch` for test chunks. It
is not retried and does not trigger another split, because the preventive split
should already have made the request valid.

## Coverage Pipeline

Coverage accepts JSON and msgpack. The worker:

1. verifies the source can be opened;
2. builds the fixed Datadog event + coverage multipart body in task-local space;
3. validates the exact `Content-Length` and media type;
4. reopens the same immutable body for every retry;
5. deletes the source only after a successful response.

Coverage is not split. A `413` is terminal and identifies unsupported oversized
coverage rather than invoking test-split behavior.

## Telemetry Pipeline

Telemetry correlation is planned before workers start, but each source remains
owned by one worker. The source worker:

1. parses strict JSON and validates required metadata;
2. applies any immutable environment/message directive;
3. rewrites provider tags when configured;
4. materializes the primary exact body in task-local space;
5. lets the selected anchor create any synthetic message batch;
6. validates or sends primary and synthetic requests sequentially;
7. deletes the source only after all requests succeed.

Unchanged primary telemetry preserves its original bytes. Changed and
synthetic bodies use deterministic compact serialization. Telemetry is not
split, and `413` is terminal.

## HTTP and Retry Contract

Each worker-local standard-library transport owns:

- system TLS verification;
- separate connect and socket-I/O timeouts;
- a snapshotted proxy and `NO_PROXY` configuration;
- redirect rejection so credentials remain on the configured intake host;
- bounded response excerpts;
- exact request body factories that reopen the same bytes per attempt;
- redacted task-scoped debug diagnostics.

The normalized retry budget is four total attempts.

Retry:

- connection and timeout failures, except TLS certificate verification failure;
- HTTP `408`;
- HTTP `429`;
- HTTP `5xx`.

Do not retry:

- HTTP `2xx` success;
- permanent HTTP `4xx`, including `413`;
- TLS certificate verification failure;
- local request-preparation errors.

`Retry-After` supports integer seconds and HTTP dates and is bounded to 60
seconds. Otherwise the configured fixed delay is used. Dry-run performs no
sleep and creates no network connection.

## Dry-run and Debug

### Dry-run

Dry-run uses the same discovery and per-file preparation code as upload mode,
including enrichment, schema checks, 4.5 MiB split, gzip, multipart spooling,
telemetry augmentation, and URL/header/body-length validation.

It must perform:

- zero backend requests;
- zero retry sleeps;
- zero source deletions;
- zero credential requirements when no HTTP request will occur.

### Debug

Debug adds diagnostics for effective config, redacted endpoints, runfiles,
freshness decisions, CODEOWNERS/context selection, queue lifecycle, worker
ownership, exact body/chunk sizes, HTTP attempts, retries, cleanup, and final
timing.

Debug must never print API keys, authorization headers, full payload bodies, or
unbounded response bodies.

## Cleanup and Outcome Rules

- Delete a source only after all requests derived from it succeed.
- Keep sources on preparation, validation, split, transport, or HTTP failure.
- `keep_payloads` suppresses deletion after success.
- Dry-run never deletes sources.
- Task/invocation temporary cleanup failure adds a warning without changing an
  already-known upload result.
- BEP staging cleanup failure preserves completed counters, adds its own reason,
  and changes an otherwise successful invocation to controlled failure.
- Failure of one source does not cancel other source files.

Severity precedence is:

1. interrupt (`130`);
2. preflight or lifecycle error (`2`, or the established freshness code);
3. one or more failed files (`1`);
4. success (`0`).

## Final Statistics

Every controlled completion prints a stable summary containing:

- mode, result, exit code, configured workers, peak workers, elapsed time;
- discovered, eligible, processed, succeeded, failed, skipped, and cancelled
  files;
- succeeded/failed/skipped counts for test, coverage, and telemetry;
- split files, chunks created/uploaded/failed, and oversized events;
- planned/attempted/succeeded/failed requests and retries;
- deleted and retained sources.

Human output and JSON derive from the same aggregate. The schema-v1 report keeps
legacy fields and adds explicit concurrency, split, request, warning, and
failure sections.

## Package Map

| Module | Responsibility |
|---|---|
| `uploader_main.py` | minimal import bootstrap |
| `uploader_py/main.py` | startup, version check, top-level controlled exit |
| `config.py` | typed config and CLI/environment precedence |
| `application.py` | locked preflight, postflight, and report lifecycle |
| `coordinator.py` | shared inputs, worker execution, aggregation |
| `worker_pool.py` | bounded ownership and shutdown semantics |
| `file_worker.py` | complete per-type file pipelines |
| `splitting.py` | deterministic preventive test split |
| `transport.py` | exact HTTP requests and retry policy |
| `codeowners.py` | discovery, immutable parsing, matching |
| `enrichment.py` | context/sidecar/event enrichment |
| `telemetry.py` | immutable cross-file telemetry planning |
| `freshness.py` | BEP staging and current-invocation selection |
| `reporting.py` | aggregate counters and renderers |
| `topt_runtime/runfiles.py` | immutable cross-platform runfiles lookup |

Small support modules contain focused models, endpoints, locking, temporary
directories, strict JSON, credentials, discovery, expected targets, and
resource loading. Avoid adding another layer unless it removes more complexity
than it introduces.

## Implementation Tracker

### Runtime foundations

- [x] Add Python 3.10+ startup check and minimal bootstrap.
- [x] Add generated typed config and standard-library-only runtime package.
- [x] Add cross-platform immutable runfiles resolution.
- [x] Add endpoint, proxy, credential, strict-JSON, and redacted-log validation.
- [x] Add workspace lock and owned temporary-directory primitives.
- [x] Make schema validation importable without breaking its CLI.

### Shared pre-worker state

- [x] Port expected-target and freshness selection.
- [x] Reuse doctor BEP parsing/staging and preserve cleanup ownership.
- [x] Port context and telemetry-facts resource loading.
- [x] Detect, parse, and compile CODEOWNERS once.
- [x] Prove matcher reads are deterministic under concurrent workers.
- [x] Plan telemetry correlation once and emit immutable per-source directives.
- [x] Perform API-key fingerprint parity once before workers.

### Complete file pipelines

- [x] Implement one dispatcher supporting all payload types.
- [x] Implement test enrichment, validation, split, gzip, upload, and cleanup.
- [x] Implement exact coverage multipart preparation and upload.
- [x] Implement primary and synthetic telemetry preparation and upload.
- [x] Reopen immutable task-local bodies across retries.
- [x] Stop later derived requests after a terminal failure.
- [x] Delete a source only after complete success.
- [x] Exercise all preparation paths in dry-run.

### Concurrency and reporting

- [x] Add rule/environment/CLI worker configuration.
- [x] Add bounded queue and homogeneous non-daemon workers.
- [x] Give each thread one private HTTP transport.
- [x] Keep coordinator counters out of workers.
- [x] Preserve deterministic result order.
- [x] Implement interrupt drain/join/report behavior.
- [x] Emit final human and JSON statistics from one aggregate.

### Bazel rollout

- [x] Generate config and carry the Python runtime in runfiles.
- [x] Generate behavior-free Unix and Windows Python launchers.
- [x] Keep an explicit per-target `use_python_uploader` rollout switch.
- [x] Add generated-launcher dry-run smoke coverage to CI.
- [ ] Record Bash and PowerShell compatibility fixtures for all public modes.
- [ ] Pass Linux, macOS, and Windows parity lanes.
- [ ] Pass the sibling consumer fixture with local module overrides.
- [ ] Validate one representative real consumer workflow.
- [x] Make Python the default.
- [ ] Update `UPLOADER_VERSION` intentionally for release.
- [ ] Remove the temporary switch and legacy Bash/PowerShell runtimes.
- [ ] Remove obsolete jq/curl/gzip uploader prerequisites from docs.

## Test Matrix

Required automated coverage:

- configuration precedence and invalid values;
- Python version and launcher resolution, including manifest-only runfiles and
  paths with spaces;
- CODEOWNERS discovery, parser parity, last-match behavior, and concurrent reads;
- zero/one/multiple context selection and sidecar enrichment;
- strict JSON and schema warning behavior;
- exact split boundary at limit minus one, limit, and limit plus one;
- top-level preservation, event ordering, and oversized single event;
- gzip after split and byte-identical retry body;
- JSON/msgpack coverage multipart content and exact length;
- telemetry primary/synthetic ownership and immutable retry body;
- agentless and EVP headers/endpoints;
- transient retry matrix and terminal permanent errors/`413`;
- worker bound, exactly-once file ownership, deterministic order, and
  `workers=1` baseline;
- interrupt, cleanup failure, keep-payloads, filter-prefix, and dry-run;
- final counters, schema-v1 compatibility, and secret redaction;
- real loopback all-protocol execution;
- generated Bazel launcher smoke on Linux, macOS, and Windows.

Repository validation before changing the default:

```bash
python3 -m unittest discover -s tools/tests/python -p 'test*_tools.py'
python3 tools/dev/lint_uploader_templates.py
./bazelw test //tools/...
./bazelw test //examples/...
```

Also run every companion-module command from `CONTRIBUTING.md` and the relevant
flow in `../rules_test_optimization_tests` with local overrides.

## Acceptance Criteria

- [x] One functional Python uploader implementation exists.
- [x] Platform launchers contain resolution only.
- [x] Every worker processes all three payload types.
- [x] One worker owns a source through complete cleanup.
- [x] CODEOWNERS and global telemetry state are prepared once.
- [x] Test split occurs before HTTP at exactly `4_718_592` bytes.
- [x] Chunks preserve top-level fields, order, and exactly-once events.
- [x] `413` is terminal and never triggers retry or adaptive split.
- [x] Dry-run performs full preparation with no HTTP, sleep, or deletion.
- [x] Debug is task-scoped and secret-safe.
- [x] Controlled completion prints final statistics.
- [x] Human and JSON counters share one aggregate.
- [x] Source deletion requires complete success.
- [x] `workers=4` demonstrates real bounded overlap in the loopback harness.
- [ ] Public Bash/PowerShell behavior is characterized and matched.
- [ ] Standard-library HTTP behavior passes all supported OS/proxy/TLS lanes.
- [ ] `workers=1` passes the complete cross-platform parity matrix.
- [ ] Linux, macOS, and Windows CI pass with the Python target.
- [ ] The sibling consumer fixture passes.
- [x] Python becomes the default.
- [ ] Legacy functional scripts are removed.

## Performance Validation

Measure with identical payload fixtures and backend behavior:

- wall-clock duration;
- files and requests per second;
- peak active workers;
- retry count;
- peak resident memory;
- temporary bytes written;
- p50/p95 per-file latency.

Compare `workers=1`, the legacy uploader, and at least `workers=2/4/8`.

A local ARM64/Python 3.12 loopback benchmark at commit `123113e` measured the
real worker pipeline with identical fixtures and rotating execution order. For
48 small mixed test/coverage/telemetry files, median speedups over one worker
were `1.99x`, `3.83x`, and `6.14x` with 2, 4, and 8 workers. For eight test
payloads above the 4.5 MiB split threshold, the corresponding speedups were
`1.40x`, `1.50x`, and `1.51x`. Based on the network-bound large-batch result,
the default is `8`; consumers with split-heavy workloads or backend throttling
can override it to `4`. Continue validating memory, temporary storage, and
real-backend retry behavior on supported CI hosts.

## Rollout and Rollback

1. Compare dry-run outputs and loopback request captures against legacy.
2. Validate the default in representative consumers and supported CI platforms.
3. Remove legacy code promptly once the remaining gates close so two
   implementations cannot drift.

During rollout, rollback is the rule-level switch back to the legacy
executable. Payload files remain recoverable because failures and dry-run retain
sources. After legacy removal, rollback should be a source-control revert of the
default/removal change, not permanent dual maintenance.
