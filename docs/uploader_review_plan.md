# Uploader Test Code Review Plan

This document contains a comprehensive review of `tools/test_optimization_uploader_test.bzl` with findings and proposed fixes for both the Bash (Linux/macOS) and PowerShell (Windows) implementations.

---

## Summary

| Priority | Category | Bash Issues | PowerShell Issues | Shared Issues |
|----------|----------|-------------|-------------------|---------------|
| **High** | Bugs | 2 | 2 | 0 |
| **Medium** | Reliability | 0 | 3 | 1 |
| **Low** | Code Quality | 0 | 1 | 2 |

*Note: SHARED-001 (temp file cleanup) removed from scope per Q1 decision.*

---

## Decisions (Resolved)

### Q1: Temporary file cleanup behavior
**Decision:** **C) Never cleanup** — Let the sandbox/temp directory handle cleanup. This is the simplest approach requiring no trap/finally complexity, and the files are ephemeral anyway.

**Impact:** SHARED-001 is **removed from scope**. No cleanup code will be added.

**Caveat:** This assumes tests run in a sandboxed environment. If tests run with `local = True` or use persistent payload directories outside the sandbox, `.enriched.json` files may accumulate over time. In such cases, external cleanup (e.g., CI job cleanup step or periodic cron) may be needed.

### Q2: Coverage upload parity with test uploads
**Decision:** **A) Yes, refactor to use shared upload function** — Coverage uploads will use the same shared helper with retry/timeout/encoding as test uploads.

**Impact:** PS-004, PS-005, PS-006 will be applied to **both** test and coverage uploads via a shared `Send-Request` helper function (see Refactoring Suggestion section).

---

## High Priority Issues (Bugs)

### BASH-001: Missing empty string check for PAYLOADS_DIR

**Location:** Line 88

**Problem:** The bash script checks if `$PAYLOADS_DIR` is a directory but doesn't first check if it's empty. While this works by accident (empty string is not a directory), it's inconsistent with the PowerShell implementation and produces a confusing log message.

**Current code:**
```bash
if [[ ! -d "$PAYLOADS_DIR" ]]; then
  log "payloads dir not found: $PAYLOADS_DIR (nothing to upload)"
  exit 0
fi
```

**Fix:**
```bash
if [[ -z "$PAYLOADS_DIR" ]]; then
  log "payloads dir not configured (nothing to upload)"
  exit 0
fi
if [[ ! -d "$PAYLOADS_DIR" ]]; then
  log "payloads dir not found: $PAYLOADS_DIR (nothing to upload)"
  exit 0
fi
```

---

### BASH-002: `((count++))` can fail with `set -e`

**Location:** Line 231

**Problem:** When `count=0`, the expression `((count++))` evaluates to 0 (falsy) before incrementing, which returns exit code 1. With `set -e` enabled (line 65), this could cause the script to exit unexpectedly.

**Current code:**
```bash
((count++))
```

**Fix:**
```bash
((++count))  # Pre-increment returns 1, not 0
# OR
count=$((count + 1))
```

---

### PS-001: HttpClient not disposed (memory/resource leak)

**Location:** Lines 417, 449

**Problem:** `System.Net.Http.HttpClient` instances are created but never disposed. This can cause resource leaks, especially with many uploads.

**Current code:**
```powershell
function Send-PostJson([string]$url, [hashtable]$headers, [string]$file) {
  $client = New-Object System.Net.Http.HttpClient
  # ... uses $client but never disposes
}
```

**Fix:**
```powershell
function Send-PostJson([string]$url, [hashtable]$headers, [string]$file) {
  $client = $null
  try {
    $client = New-Object System.Net.Http.HttpClient
    foreach ($k in $headers.Keys) { $client.DefaultRequestHeaders.Add($k, [string]$headers[$k]) }
    # ... rest of function
  } finally {
    if ($client) { $client.Dispose() }
  }
}
```

**Note:** This fix must also be applied to the coverage upload section (line 449) which has its own HttpClient instance.

---

### PS-002: File stream not closed (resource leak)

**Location:** Line 463

**Problem:** `[System.IO.File]::OpenRead($f)` opens a file stream that is never closed, potentially locking the file.

**Current code:**
```powershell
$fs = [System.IO.File]::OpenRead($f)
$covContent = New-Object System.Net.Http.StreamContent($fs)
# $fs is never closed
```

**Fix:**
```powershell
$fs = $null
try {
  $fs = [System.IO.File]::OpenRead($f)
  $covContent = New-Object System.Net.Http.StreamContent($fs)
  # ... upload logic
} finally {
  if ($fs) { $fs.Dispose() }
}
```

---

## Medium Priority Issues (Reliability)

### SHARED-004: Success logs emitted even when uploads fail (masked failures)

**Location:**
- Bash: Lines 230, 266 (both test and coverage uploads)
- PowerShell: Line 442 (test uploads only; coverage uploads at line 472 already log success only on success)

**Problem:** When `FAIL_ON_ERROR=0`, the bash script and PowerShell test uploads log "uploaded test payload: $f" even when the upload actually failed. This can mask real failures and make debugging difficult.

**Note:** PowerShell coverage uploads (line 472) already correctly log success only inside the `else` block of the success check, so no fix is needed there.

**Current code (Bash):**
```bash
curl ... || {
  if (( FAIL_ON_ERROR )); then log "upload failed: $f"; exit 1; else log "upload failed (ignored): $f"; fi
}
log "uploaded test payload: $f"  # Always executed, even after failure
```

**Current code (PowerShell test uploads):**
```powershell
Send-PostJson $TestUrl $hdrs $body  # May fail silently when $FailOnError is false
Log "uploaded test payload: $f"    # Always executed
```

**Fix (Bash test uploads):** Track success and only log on success:
```bash
if (( AGENTLESS == 1 )); then
  if curl -f -sS ... ; then
    log "uploaded test payload: $f"
    ((++count))
  else
    if (( FAIL_ON_ERROR )); then log "upload failed: $f"; exit 1; else log "upload failed (ignored): $f"; fi
  fi
else
  # Same pattern for non-agentless
fi
```

**Fix (Bash coverage uploads):** Same pattern for coverage loop (line 266):
```bash
if (( AGENTLESS == 1 )); then
  if curl -f -sS ... ; then
    log "uploaded coverage payload: $f"
  else
    if (( FAIL_ON_ERROR )); then log "coverage upload failed: $f"; exit 1; else log "coverage upload failed (ignored): $f"; fi
  fi
else
  # Same pattern for non-agentless
fi
```

**Fix (PowerShell test uploads):** Return success status from Send-PostJson and remove the internal `Log "uploaded"` (line 426) to avoid duplicate logs:
```powershell
function Send-PostJson([string]$url, [hashtable]$headers, [string]$file) {
  # ... existing code ...
  if ($resp.IsSuccessStatusCode) {
    return $true  # Removed: Log "uploaded" - caller now handles success logging
  } else {
    # ... error handling ...
    return $false
  }
}

# In test upload loop:
if (Send-PostJson $TestUrl $hdrs $body) {
  Log "uploaded test payload: $f"
}
```

**Note:** The existing `Log "uploaded"` at line 426 inside Send-PostJson must be removed when implementing this fix, otherwise every successful test upload would log twice.

---

### PS-004: No retry logic for HTTP requests

**Location:** Lines 416-427 (Send-PostJson function)

**Problem:** The bash script uses curl's built-in retry mechanism (`--retry 3 --retry-delay 2 --retry-connrefused`), but the PowerShell implementation has no retry logic, making it less resilient to transient network failures.

**Scope:** Per Q2 decision, this fix applies to **both test and coverage uploads** via a shared `Send-Request` helper function.

**Fix:** Add retry logic. See Refactoring Suggestion section for recommended approach.

---

### PS-005: No timeout configuration for HttpClient

**Location:** Lines 417, 449

**Problem:** Bash curl has explicit timeouts (`--connect-timeout 10 --max-time 60`), but PowerShell HttpClient uses default timeouts which may be too long or inconsistent.

**Scope:** Per Q2 decision, this fix applies to **both test and coverage uploads** via the shared helper.

**Fix:** Add timeout configuration:
```powershell
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(60)
```

---

### PS-006: File encoding assumption

**Location:** Lines 420, 460

**Problem:** `[IO.File]::ReadAllText($file)` uses the system's default encoding, which may not be UTF-8. JSON files should be read as UTF-8.

**Scope:** Per Q2 decision, this fix applies to **both test and coverage uploads** via the shared helper.

**Current code:**
```powershell
$content = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($file))
```

**Fix:**
```powershell
$content = New-Object System.Net.Http.StringContent(
  [IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
```

---

## Low Priority Issues (Code Quality)

### PS-003: Array wrapping for consistency

**Location:** Lines 433, 455

**Status:** `.Count` on `$null` and single items is safe in PowerShell 5.1+, so this is just a consistency improvement.

**Current code:**
```powershell
$testFiles = Get-ChildItem -LiteralPath $testDir -Filter *.json -File -ErrorAction SilentlyContinue
```

**Optional fix for consistency:**
```powershell
$testFiles = @(Get-ChildItem -LiteralPath $testDir -Filter *.json -File -ErrorAction SilentlyContinue)
```

---

### SHARED-002: Hardcoded tracer version

**Location:**
- Bash: Line 161
- PowerShell: Line 357

**Problem:** The tracer version `1.0.0` is hardcoded. Consider making this a constant or configurable.

**Current code:**
```
"Datadog-Meta-Tracer-Version: 1.0.0"
```

**Suggested:** Define a constant at the top of the Starlark file:
```python
UPLOADER_VERSION = "1.0.0"
```

---

### SHARED-003: Coverage event.json contains dummy data

**Location:**
- Bash: Line 241
- PowerShell: Line 453

**Problem:** The coverage upload creates a dummy event file with `{"dummy":true}`. This may be intentional for the API, but should be documented.

**Current code:**
```bash
echo '{"dummy":true}' > "$eventjson"
```

**Suggested:** Add a comment explaining why this is needed, or generate a proper event structure if required by the API.

---

## Implementation Phases

### Phase 1 - Critical Bug Fixes
| Issue | Priority | Effort | Depends On |
|-------|----------|--------|------------|
| BASH-001 | High | Small | - |
| BASH-002 | High | Small | - |
| PS-001 | High | Medium | - |
| PS-002 | High | Medium | - |

### Phase 2 - Reliability Improvements
| Issue | Priority | Effort | Depends On |
|-------|----------|--------|------------|
| SHARED-004 | Medium | Medium | - |
| PS-006 | Medium | Small | - |
| PS-005 | Medium | Small | - |
| PS-004 | Medium | Large | PS-001, PS-005, PS-006 |

**Note:** Per Q2 decision, PS-004/PS-005/PS-006 will be applied to **both** test and coverage uploads via a shared helper function.

**Removed:** SHARED-001 (temp file cleanup) — per Q1 decision, sandbox handles cleanup.

### Phase 3 - Code Quality (Optional)
| Issue | Priority | Effort | Depends On |
|-------|----------|--------|------------|
| PS-003 | Low | Small | - |
| SHARED-002 | Low | Small | - |
| SHARED-003 | Low | Small | - |

---

## Refactoring Suggestion

To address the coverage upload parity issue (Q2), consider refactoring to share upload logic:

### Current Architecture
```
Send-PostJson (test uploads only)
├── Creates HttpClient
├── No retry
├── No timeout
└── Default encoding

Coverage Upload Section (separate code)
├── Creates its own HttpClient
├── No retry
├── No timeout
└── Default encoding
```

### Proposed Architecture
```
Send-Request (shared helper)
├── Creates HttpClient with timeout
├── Retry logic (3 attempts)
├── UTF-8 encoding
├── Proper disposal
└── Returns success/failure status

Send-PostJson (uses Send-Request)
└── JSON content type

Send-MultipartPost (new, uses similar pattern)
└── Multipart form content type
```

This reduces code duplication and ensures consistent behavior for all uploads.

---

## Testing Checklist

After implementing fixes, test on:

- [ ] Linux (native bash)
- [ ] macOS (BSD tools)
- [ ] Windows (native PowerShell 5.1)
- [ ] Windows (PowerShell 7+)
- [ ] MSYS2/Git Bash on Windows (bash delegating to PowerShell)

Test scenarios:
- [ ] Empty payloads directory (nothing to upload)
- [ ] Missing payloads directory
- [ ] Empty `DD_PAYLOADS_DIR` environment variable
- [ ] Payloads directory with test files
- [ ] Payloads directory with coverage files
- [ ] Upload failure with `FAIL_ON_ERROR=0` (verify correct logging)
- [ ] Upload failure with `FAIL_ON_ERROR=1` (verify script exits)
- [ ] Network timeout simulation (for timeout testing)
- [ ] Transient network failure (for retry logic testing)
- [ ] `DD_API_KEY` not set (agentless mode skip)
- [ ] `DD_TRACE_AGENT_URL` set (agent mode)
- [ ] Large number of files (for resource leak detection)

### Critical Scenarios Requiring Actual Test Coverage

The following scenarios are particularly important for validating the reliability fixes and should have automated or reproducible test procedures, not just manual verification:

| Scenario | Validates | How to Test |
|----------|-----------|-------------|
| `FAIL_ON_ERROR=0` with failed upload | SHARED-004 (masked failures) | Use invalid URL or mock server returning 500; verify failure is logged but script continues |
| `FAIL_ON_ERROR=0` with successful upload | SHARED-004 (no duplicate logs) | Verify exactly one success log per file, not duplicates |
| Network timeout | PS-005 (timeout config) | Use a mock server with delayed response > 60s; verify timeout occurs |
| Transient failures with retry | PS-004 (retry logic) | Use mock server that fails first 2 requests then succeeds; verify 3rd attempt works |

### Mock Server Setup for CI

To reliably test network failure scenarios, use one of these reproducible methods.

**Prerequisites:**
- Python 3 must be available in the test environment
- These examples use POSIX shell backgrounding (`&`); see Windows notes below

**Bazel sandbox considerations:** If `--sandbox_default_allow_network=false` is enabled (recommended), localhost calls will be blocked. For these tests, either:
- Run them with `tags = ["requires-network"]` and `--sandbox_default_allow_network=false --test_tag_filters=-requires-network` exclusion
- Or run outside the sandbox using `--spawn_strategy=local` for this specific test
- Or use `local = True` on the test target

**Option 1: Return 500 for all requests (Linux/macOS)**
```bash
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_POST(self): self.send_response(500); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', 8888), H).serve_forever()
" &
```

**Option 2: Delayed response (for timeout testing, Linux/macOS)**

**Timeout alignment required:** The mock server sleep (90s) must exceed the client timeout (60s) but the test must have enough time to complete. Configure the test target with:
```python
# In BUILD file for the timeout test
sh_test(
    name = "uploader_timeout_test",
    timeout = "long",  # or explicit: timeout = 180
    ...
)
```

```bash
python3 -c "
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_POST(self): time.sleep(90); self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', 8888), H).serve_forever()
" &
```

**Option 3: Transient failure - fails N times, then succeeds (Linux/macOS)**
```bash
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
count = [0]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        count[0] += 1
        code = 500 if count[0] <= 2 else 200
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', 8888), H).serve_forever()
" &
```

**Windows/PowerShell:** Use `Start-Process` instead of `&` for backgrounding:
```powershell
Start-Process -NoNewWindow python3 -ArgumentList '-c', @'
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_POST(self): self.send_response(500); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 8888), H).serve_forever()
'@
```

**CI Integration:** Start the mock server as a background process before running the uploader test, then kill it after. Set `DD_TRACE_AGENT_URL=http://127.0.0.1:8888` or the appropriate test URL to route uploads to the mock.

**CI prerequisites checklist:**
- [ ] Python 3 available in CI environment
- [ ] Network access enabled for mock server tests (see sandbox considerations above)
- [ ] Test timeout configured appropriately for timeout scenario (see Option 2)

---

## Out of Scope

### SHARED-001: No cleanup of temporary enriched files

**Status:** Removed from scope per Q1 decision.

**Rationale:** Let the sandbox/temp directory handle cleanup. The `.enriched.json` files are ephemeral and will be cleaned up when the sandbox is torn down. This avoids the complexity of trap/finally handlers for early-exit safety.

**Location (for reference):**
- Bash: Lines 216-217
- PowerShell: Lines 436-437
