# A Starlark test rule that uploads CI Visibility test and coverage payloads
# within the same `bazel test` invocation by watching a shared writable
# payloads directory for quiescence, enriching test payloads with Git
# metadata, and sending them to Datadog.
#
# Usage pattern for best results:
# - Configure tests to write payloads under an external writable directory
#   exposed via `--sandbox_writable_path` and made available to tests via
#   `--test_env=DD_PAYLOADS_DIR=/abs/path/.testoptimization/payloads`.
# - Invoke this test target together with your tests (e.g., include in a
#   test_suite or add to the same invocation). It runs outside the sandbox and
#   uploads after the directory is quiescent.

# Version identifier sent in Datadog-Meta-Tracer-Version header
UPLOADER_VERSION = "1.0.0"

def log_info(message):
    print("dd_payload_uploader_test: %s" % message)

def log_debug(debug_enabled, message):
    if debug_enabled:
        print("dd_payload_uploader_test: %s" % message)

def _render_template(template, substitutions):
    # Simple template renderer compatible with the existing {key} placeholders.
    # It also converts doubled braces ({{, }}) into single braces after substitution,
    # which keeps literal braces used by shell/JSON/PowerShell intact.
    out = template
    for k, v in substitutions.items():
        out = out.replace("{" + k + "}", str(v))

    # Unescape '{{' and '}}' used to protect literal braces in the template
    out = out.replace("{{", "{").replace("}}", "}")
    return out

def _uploader_impl(ctx):
    payloads_dir = ctx.attr.payloads_dir
    tests_subdir = ctx.attr.tests_subdir
    coverage_subdir = ctx.attr.coverage_subdir
    quiescent_sec = ctx.attr.quiescent_sec
    max_wait_sec = ctx.attr.max_wait_sec
    fail_on_error = ctx.attr.fail_on_error
    debug = ctx.attr.debug

    # High-level debug of rule inputs
    log_info("Generating uploader scripts")
    log_debug(
        debug,
        "Attributes → payloads_dir='%s', tests_subdir='%s', coverage_subdir='%s', quiescent_sec=%s, max_wait_sec=%s, fail_on_error=%s, debug=%s" %
        (
            (payloads_dir or "<unset>"),
            tests_subdir,
            coverage_subdir,
            quiescent_sec,
            max_wait_sec,
            fail_on_error,
            debug,
        ),
    )
    if ctx.files.data:
        log_debug(debug, "Data files count: %d" % len(ctx.files.data))
        for f in ctx.files.data:
            log_debug(debug, "  data file: %s (%s)" % (f.basename, f.short_path))

    # Bash implementation (Unix)
    bash_template = """
#!/usr/bin/env bash
set -euo pipefail

PAYLOADS_DIR="${{DD_PAYLOADS_DIR:-{payloads_dir}}}"
TESTS_SUBDIR="{tests_subdir}"
COVERAGE_SUBDIR="{coverage_subdir}"
QUIESCENT_SEC={quiescent_sec}
MAX_WAIT_SEC={max_wait_sec}
FAIL_ON_ERROR={fail_on_error}

log() {{ echo "[dd-uploader] $1"; }}
dbg() {{ if [[ {debug} == 1 ]]; then echo "[dd-uploader][dbg] $1" >&2; fi }}

dbg "uname: $(uname -s)"
dbg "PAYLOADS_DIR='$PAYLOADS_DIR'"
dbg "TESTS_SUBDIR='$TESTS_SUBDIR', COVERAGE_SUBDIR='$COVERAGE_SUBDIR'"
dbg "QUIESCENT_SEC=$QUIESCENT_SEC, MAX_WAIT_SEC=$MAX_WAIT_SEC, FAIL_ON_ERROR=$FAIL_ON_ERROR"

if [[ "$(uname -s | tr 'A-Z' 'a-z')" == *mingw* || "$(uname -s | tr 'A-Z' 'a-z')" == *msys* || "$(uname -s | tr 'A-Z' 'a-z')" == *cygwin* ]]; then
  ps_path="$(dirname "$0")/$(basename "$0" .sh).ps1"
  dbg "Windows-like environment detected; delegating to PowerShell: $ps_path"
  exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps_path"
fi

if [[ -z "$PAYLOADS_DIR" ]]; then
  log "payloads dir not configured (nothing to upload)"
  exit 0
fi
if [[ ! -d "$PAYLOADS_DIR" ]]; then
  log "payloads dir not found: $PAYLOADS_DIR (nothing to upload)"
  exit 0
fi

latest_mtime() {{
  local d="$1"
  if [[ ! -d "$d" ]]; then dbg "latest_mtime: directory '$d' not found"; echo 0; return; fi
  dbg "latest_mtime: scanning '$d'"
  local mt
  if stat -f %m / >/dev/null 2>&1; then
    # BSD/macOS stat
    dbg "latest_mtime: using BSD stat"
    mt=$(find "$d" -type f -exec stat -f '%m' {{}} + 2>/dev/null | sort -nr | head -1 || true)
  else
    # GNU/Linux stat
    dbg "latest_mtime: using GNU stat"
    mt=$(find "$d" -type f -exec stat -c '%Y' {{}} + 2>/dev/null | sort -nr | head -1 || true)
  fi
  if [[ -z "$mt" ]]; then
    dbg "latest_mtime: no files in '$d'"
    echo 0
  else
    dbg "latest_mtime('$d') -> $mt"
    printf '%.0f' "$mt"
  fi
}}

start_ts=$(date +%s)
last_ts=$(latest_mtime "$PAYLOADS_DIR")
dbg "initial latest mtime: $last_ts"
while true; do
  now=$(date +%s)
  elapsed=$(( now - start_ts ))
  dbg "loop: elapsed=$elapsed s"
  if (( elapsed > MAX_WAIT_SEC )); then
    log "max wait exceeded ($MAX_WAIT_SEC s); proceeding to upload"
    break
  fi
  cur=$(latest_mtime "$PAYLOADS_DIR")
  dbg "loop: latest_mtime=$cur"
  if (( cur == 0 )); then
    dbg "no files yet; sleeping"
    sleep 2
    continue
  fi
  idle=$(( now - cur ))
  dbg "loop: idle=$idle s"
  if (( idle >= QUIESCENT_SEC )); then
    log "directory quiescent for $idle s; starting upload"
    break
  fi
  sleep 2
done

# Build endpoints
DD_SITE="${{DD_SITE:-datadoghq.com}}"
if [[ -z "${{DD_TRACE_AGENT_URL:-}}" ]]; then
  AGENTLESS=1
  TEST_URL="https://citestcycle-intake.${{DD_SITE}}/api/v2/citestcycle"
  COV_URL="https://citestcov-intake.${{DD_SITE}}/api/v2/citestcov"
else
  AGENTLESS=0
  TEST_URL="${{DD_TRACE_AGENT_URL}}/evp_proxy/v2/api/v2/citestcycle"
  COV_URL="${{DD_TRACE_AGENT_URL}}/evp_proxy/v2/api/v2/citestcov"
fi
dbg "mode: AGENTLESS=$AGENTLESS DD_SITE=$DD_SITE"
dbg "endpoints: TEST_URL=$TEST_URL COV_URL=$COV_URL"

hdrs=(
  -H "Datadog-Meta-Lang: bazel-starlark"
  -H "Datadog-Meta-Lang-Version: n/a"
  -H "Datadog-Meta-Lang-Interpreter: bazel-test"
  -H "Datadog-Meta-Tracer-Version: {uploader_version}"
  -H "Accept: application/json"
)
if (( AGENTLESS == 1 )); then
  if [[ -z "${{DD_API_KEY:-}}" ]]; then
    log "DD_API_KEY required for agentless uploads; skipping"
    exit 0
  fi
  hdrs+=( -H "DD-API-KEY: $DD_API_KEY" )
else
  # EVP subdomain headers per endpoint
  TEST_EVP=( -H "X-Datadog-EVP-Subdomain: citestcycle-intake" )
  COV_EVP=( -H "X-Datadog-EVP-Subdomain: citestcov-intake" )
fi
dbg "headers prepared (agentless=$AGENTLESS)"

# Load context.json from runfiles if present (added via data deps)
CONTEXT_JSON=""
dbg "TEST_SRCDIR: ${TEST_SRCDIR:-<unset>}"
dbg "RUNFILES_MANIFEST_FILE: ${RUNFILES_MANIFEST_FILE:-<unset>}"
if [[ -n "${TEST_SRCDIR:-}" && -d "$TEST_SRCDIR" ]]; then
  dbg "searching runfiles dir for context.json"
  CONTEXT_JSON="$(find -L "$TEST_SRCDIR" -name context.json 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$CONTEXT_JSON" && -n "${RUNFILES_MANIFEST_FILE:-}" && -f "$RUNFILES_MANIFEST_FILE" ]]; then
  dbg "searching manifest for context.json"
  CONTEXT_JSON="$(awk 'NF>=2 && $1 ~ /context\\.json$/ {print $2; exit}' "$RUNFILES_MANIFEST_FILE" 2>/dev/null || true)"
fi
JQ_AVAILABLE=0
if command -v jq >/dev/null 2>&1; then JQ_AVAILABLE=1; fi
dbg "jq available: $JQ_AVAILABLE"
dbg "context.json: ${CONTEXT_JSON:-<none>}"

enrich_with_context() {
  local infile="$1"; local tmpfile="$2"
  dbg "enrich_with_context: infile='$infile' outfile='$tmpfile' ctx='${CONTEXT_JSON:-<none>}' jq=$JQ_AVAILABLE"
  if (( JQ_AVAILABLE == 0 )) || [[ -z "$CONTEXT_JSON" ]] || [[ ! -f "$CONTEXT_JSON" ]]; then
    cp "$infile" "$tmpfile"
    return 0
  fi
  jq --slurpfile ctx "$CONTEXT_JSON" '
    (.metadata |= (. // {{}}))
    | (.metadata["*"] |= ((. // {{}}) + ($ctx[0] | with_entries(select(.value != null)))))
  ' "$infile" > "$tmpfile"
}

upload_tests() {{
  local d="$PAYLOADS_DIR/$TESTS_SUBDIR"
  [[ -d "$d" ]] || return 0
  shopt -s nullglob
  local files=( "$d"/*.json )
  dbg "upload_tests: found ${#files[@]} files in '$d'"
  local count=0
  for f in "${files[@]}"; do
    local body
    body="${f}.enriched.json"
    enrich_with_context "$f" "$body"
    dbg "upload_tests: posting '$f' (body '$body')"
    if (( AGENTLESS == 1 )); then
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \
        -X POST "${TEST_URL}" "${hdrs[@]}" -H "Content-Type: application/json" --data-binary @"${body}" -o /dev/null -w "%{http_code}" >/dev/null; then
        log "uploaded test payload: $f"
        ((++count))
      else
        if (( FAIL_ON_ERROR )); then log "upload failed: $f"; exit 1; else log "upload failed (ignored): $f"; fi
      fi
    else
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \
        -X POST "${TEST_URL}" "${hdrs[@]}" "${TEST_EVP[@]}" -H "Content-Type: application/json" --data-binary @"${body}" -o /dev/null -w "%{http_code}" >/dev/null; then
        log "uploaded test payload: $f"
        ((++count))
      else
        if (( FAIL_ON_ERROR )); then log "upload failed: $f"; exit 1; else log "upload failed (ignored): $f"; fi
      fi
    fi
  done
  dbg "upload_tests: uploaded $count files"
}}

upload_coverage() {{
  local d="$PAYLOADS_DIR/$COVERAGE_SUBDIR"
  [[ -d "$d" ]] || return 0
  local eventjson
  eventjson="${d}/event.json"
  # The CI Visibility coverage intake API requires a multipart 'event' field.
  # Since coverage payloads are self-contained, we send a minimal placeholder.
  echo '{{"dummy":true}}' > "$eventjson"
  dbg "upload_coverage: wrote event file '$eventjson'"
  shopt -s nullglob
  local files=( "$d"/*.json )
  dbg "upload_coverage: found ${#files[@]} files in '$d'"
  for f in "${files[@]}"; do
    if [[ "$f" == "$eventjson" ]]; then
      continue
    fi
    dbg "upload_coverage: posting '$f'"
    if (( AGENTLESS == 1 )); then
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \
        -X POST "${COV_URL}" "${hdrs[@]}" \
        -F "event=@${eventjson};type=application/json;filename=fileevent.json" \
        -F "coveragex=@${f};type=application/json;filename=filecoveragex.json" -o /dev/null -w "%{http_code}" >/dev/null; then
        log "uploaded coverage payload: $f"
      else
        if (( FAIL_ON_ERROR )); then log "coverage upload failed: $f"; exit 1; else log "coverage upload failed (ignored): $f"; fi
      fi
    else
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \
        -X POST "${COV_URL}" "${hdrs[@]}" "${COV_EVP[@]}" \
        -F "event=@${eventjson};type=application/json;filename=fileevent.json" \
        -F "coveragex=@${f};type=application/json;filename=filecoveragex.json" -o /dev/null -w "%{http_code}" >/dev/null; then
        log "uploaded coverage payload: $f"
      else
        if (( FAIL_ON_ERROR )); then log "coverage upload failed: $f"; exit 1; else log "coverage upload failed (ignored): $f"; fi
      fi
    fi
  done
}}

upload_tests
upload_coverage
log "done"
"""

    bash_script = _render_template(
        bash_template,
        {
            "payloads_dir": payloads_dir or "",
            "tests_subdir": tests_subdir,
            "coverage_subdir": coverage_subdir,
            "quiescent_sec": quiescent_sec,
            "max_wait_sec": max_wait_sec,
            "fail_on_error": 1 if fail_on_error else 0,
            "debug": 1 if debug else 0,
            "uploader_version": UPLOADER_VERSION,
        },
    )
    log_debug(debug, "Bash script rendered (bytes=%d)" % len(bash_script))

    # PowerShell implementation (Windows)
    ps_template = """
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PayloadsDir = if (-not [string]::IsNullOrEmpty($env:DD_PAYLOADS_DIR)) {{ $env:DD_PAYLOADS_DIR }} else {{ '{payloads_dir}' }}
$TestsSubdir = '{tests_subdir}'
$CoverageSubdir = '{coverage_subdir}'
$QuiescentSec = {quiescent_sec}
$MaxWaitSec = {max_wait_sec}
$FailOnError = {fail_on_error}

function Log([string]$msg) {{ Write-Output "[dd-uploader] $msg" }}
function Dbg([string]$msg) {{ if ({debug}) {{ Write-Output "[dd-uploader][dbg] $msg" }} }}

Dbg "PayloadsDir='$PayloadsDir'"
Dbg "TestsSubdir='$TestsSubdir' CoverageSubdir='$CoverageSubdir'"
Dbg "QuiescentSec=$QuiescentSec MaxWaitSec=$MaxWaitSec FailOnError=$FailOnError"

if ([string]::IsNullOrEmpty($PayloadsDir)) {{
  Log "payloads dir not configured (nothing to upload)"
  Dbg "Skipping because PayloadsDir is empty"
  exit 0
}}
if (-not (Test-Path -LiteralPath $PayloadsDir)) {{
  Log "payloads dir not found: $PayloadsDir (nothing to upload)"
  Dbg "Skipping because directory does not exist"
  exit 0
}}

function Get-LatestMTime([string]$dir) {{
  if (-not (Test-Path -LiteralPath $dir)) {{ return 0 }}
  $files = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files) {{ return 0 }}
  return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime.ToFileTimeUtc()
}}

$start = Get-Date
Dbg "Starting quiescence loop at $start"
while ($true) {{
  $elapsed = ((Get-Date) - $start).TotalSeconds
  Dbg "loop: elapsed=$elapsed s"
  if ($elapsed -gt $MaxWaitSec) {{ Log "max wait exceeded ($MaxWaitSec s); proceeding"; break }}
  $files = Get-ChildItem -LiteralPath $PayloadsDir -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files) {{ Start-Sleep -Seconds 2; continue }}
  $latest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
  $idle = ((Get-Date) - $latest).TotalSeconds
  Dbg "loop: idle=$idle s"
  if ($idle -ge $QuiescentSec) {{ Log "directory quiescent for $idle s; starting upload"; break }}
  Start-Sleep -Seconds 2
}}

$Agentless = [string]::IsNullOrEmpty($env:DD_TRACE_AGENT_URL)
$DD_Site = if ([string]::IsNullOrEmpty($env:DD_SITE)) {{ 'datadoghq.com' }} else {{ $env:DD_SITE }}
if ($Agentless) {{
  $TestUrl = "https://citestcycle-intake.$DD_Site/api/v2/citestcycle"
  $CovUrl = "https://citestcov-intake.$DD_Site/api/v2/citestcov"
}} else {{
  $TestUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcycle"
  $CovUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcov"
}}
Dbg "mode: Agentless=$Agentless Site=$DD_Site"
Dbg "endpoints: TestUrl=$TestUrl CovUrl=$CovUrl"

$CommonHeaders = @{{
  'Datadog-Meta-Lang' = 'bazel-starlark'
  'Datadog-Meta-Lang-Version' = 'n/a'
  'Datadog-Meta-Lang-Interpreter' = 'bazel-test'
  'Datadog-Meta-Tracer-Version' = '{uploader_version}'
  'Accept' = 'application/json'
}}
if ($Agentless) {{
  if ([string]::IsNullOrEmpty($env:DD_API_KEY)) {{ Log "DD_API_KEY required for agentless uploads"; exit 0 }}
  $CommonHeaders['DD-API-KEY'] = $env:DD_API_KEY
}} else {{
  $TestEvp = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcycle-intake' }}
  $CovEvp  = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcov-intake' }}
}}
Dbg "headers prepared (agentless=$Agentless)"

# Load context.json from runfiles if present (added via data deps)
$ContextJson = $null
Dbg "TEST_SRCDIR: $(if ([string]::IsNullOrEmpty($env:TEST_SRCDIR)) {{ '<unset>' }} else {{ $env:TEST_SRCDIR }})"
Dbg "RUNFILES_MANIFEST_FILE: $(if ([string]::IsNullOrEmpty($env:RUNFILES_MANIFEST_FILE)) {{ '<unset>' }} else {{ $env:RUNFILES_MANIFEST_FILE }})"
if (-not [string]::IsNullOrEmpty($env:TEST_SRCDIR)) {{
  try {{
    $ctxFile = Get-ChildItem -LiteralPath $env:TEST_SRCDIR -Recurse -File -Filter 'context.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ctxFile) {{ $ContextJson = $ctxFile.FullName }}
  }} catch {{}}
}}
if (-not $ContextJson -and -not [string]::IsNullOrEmpty($env:RUNFILES_MANIFEST_FILE) -and (Test-Path -LiteralPath $env:RUNFILES_MANIFEST_FILE)) {{
  Dbg "searching manifest for context.json"
  try {{
    $line = Get-Content -LiteralPath $env:RUNFILES_MANIFEST_FILE -ErrorAction SilentlyContinue | Where-Object {{
      $p = $_ -split '\\s+', 2
      ($p.Length -ge 1) -and $p[0].EndsWith('context.json')
    }} | Select-Object -First 1
    if ($line) {{
      $parts = $line -split '\\s+', 2
      if ($parts.Length -ge 2) {{ $ContextJson = $parts[1] }}
    }}
  }} catch {{}}
}}
Dbg "context.json: $(if ([string]::IsNullOrEmpty($ContextJson)) {{ '<none>' }} else {{ $ContextJson }})"

function Merge-With-Context([string]$infile, [string]$outfile) {{
  if (-not $ContextJson -or -not (Test-Path -LiteralPath $ContextJson)) {{
    Dbg "Merge-With-Context: no context; copying '$infile' to '$outfile'"
    Copy-Item -LiteralPath $infile -Destination $outfile -Force; return
  }}
  try {{
    $payload = Get-Content -LiteralPath $infile -Raw | ConvertFrom-Json -ErrorAction Stop
  }} catch {{ Copy-Item -LiteralPath $infile -Destination $outfile -Force; return }}
  try {{
    $ctx = Get-Content -LiteralPath $ContextJson -Raw | ConvertFrom-Json -ErrorAction Stop
  }} catch {{ $ctx = $null }}
  if (-not $payload.metadata) {{ $payload | Add-Member -NotePropertyName metadata -NotePropertyValue @{{}} }}
  if (-not $payload.metadata.'*') {{ $payload.metadata.'*' = @{{}} }}
  if ($ctx) {{
    foreach ($prop in $ctx.PSObject.Properties) {{
      if ($prop.Value -ne $null) {{ $payload.metadata.'*'.($prop.Name) = $prop.Value }}
    }}
  }}
  Dbg "Merge-With-Context: wrote enriched '$outfile'"
  $payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $outfile -Encoding UTF8
}}

function Send-PostJson([string]$url, [hashtable]$headers, [string]$file) {{
  $maxRetries = 3
  $retryDelay = 2
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {{
    $client = $null
    try {{
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(60)
      foreach ($k in $headers.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$headers[$k]) }}
      Dbg "Send-PostJson: POST $url (file '$file'; attempt $attempt/$maxRetries)"
      $content = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
      $content.Headers.ContentType = 'application/json'
      $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
      if ($resp.IsSuccessStatusCode) {{
        return $true
      }} else {{
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Dbg "Send-PostJson: HTTP $([int]$resp.StatusCode) on attempt $attempt"
        if ($attempt -eq $maxRetries) {{
          if ($FailOnError) {{ throw "HTTP $([int]$resp.StatusCode): $body" }} else {{ Log "upload failed (ignored): HTTP $([int]$resp.StatusCode) $body"; return $false }}
        }}
      }}
    }} catch {{
      Dbg "Send-PostJson: Exception on attempt $attempt - $_"
      if ($attempt -eq $maxRetries) {{
        if ($FailOnError) {{ throw }} else {{ Log "upload failed (ignored): $_"; return $false }}
      }}
    }} finally {{
      if ($client) {{ $client.Dispose() }}
    }}
    Start-Sleep -Seconds $retryDelay
  }}
  return $false
}}

# Upload tests
$testDir = Join-Path $PayloadsDir $TestsSubdir
if (Test-Path -LiteralPath $testDir) {{
  $testFiles = @(Get-ChildItem -LiteralPath $testDir -Filter *.json -File -ErrorAction SilentlyContinue)
  Dbg "upload_tests: found $($testFiles.Count) files in '$testDir'"
  $testFiles | ForEach-Object {{
    $f = $_.FullName
    $body = "$f.enriched.json"
    Merge-With-Context $f $body
    $hdrs = $CommonHeaders.Clone()
    if (-not $Agentless) {{ $hdrs['X-Datadog-EVP-Subdomain'] = 'citestcycle-intake' }}
    Dbg "upload_tests: posting '$f' (body '$body')"
    if (Send-PostJson $TestUrl $hdrs $body) {{
      Log "uploaded test payload: $f"
    }}
  }}
}}

# Upload coverage (multipart)
$covDir = Join-Path $PayloadsDir $CoverageSubdir
if (Test-Path -LiteralPath $covDir) {{
  $client = $null
  try {{
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    foreach ($k in $CommonHeaders.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$CommonHeaders[$k]) }}
    if (-not $Agentless) {{ $client.DefaultRequestHeaders.Add('X-Datadog-EVP-Subdomain','citestcov-intake') }}
    $eventFile = Join-Path $covDir 'event.json'
    # The CI Visibility coverage intake API requires a multipart 'event' field.
    # Since coverage payloads are self-contained, we send a minimal placeholder.
    Set-Content -LiteralPath $eventFile -Value '{"dummy":true}' -Encoding UTF8
    $covFiles = @(Get-ChildItem -LiteralPath $covDir -Filter *.json -File -ErrorAction SilentlyContinue)
    Dbg "upload_coverage: found $($covFiles.Count) files in '$covDir'"
    $covFiles | ForEach-Object {{
      $f = $_.FullName
      if ($f -eq $eventFile) {{ return }}
      $maxRetries = 3
      $retryDelay = 2
      $uploaded = $false
      for ($attempt = 1; $attempt -le $maxRetries -and -not $uploaded; $attempt++) {{
        $fs = $null
        try {{
          $content = New-Object System.Net.Http.MultipartFormDataContent
          $eventContent = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($eventFile, [System.Text.Encoding]::UTF8))
          $eventContent.Headers.ContentType = 'application/json'
          $content.Add($eventContent, 'event', 'fileevent.json')
          $fs = [System.IO.File]::OpenRead($f)
          $covContent = New-Object System.Net.Http.StreamContent($fs)
          $covContent.Headers.ContentType = 'application/json'
          $content.Add($covContent, 'coveragex', 'filecoveragex.json')
          Dbg "upload_coverage: posting '$f' (attempt $attempt/$maxRetries)"
          $resp = $client.PostAsync($CovUrl, $content).GetAwaiter().GetResult()
          if ($resp.IsSuccessStatusCode) {{
            Log "uploaded coverage payload: $f"
            $uploaded = $true
          }} else {{
            $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Dbg "upload_coverage: HTTP $([int]$resp.StatusCode) on attempt $attempt"
            if ($attempt -eq $maxRetries) {{
              if ($FailOnError) {{ throw "HTTP $([int]$resp.StatusCode): $respBody" }} else {{ Log "coverage upload failed (ignored): HTTP $([int]$resp.StatusCode) $respBody" }}
            }}
          }}
        }} catch {{
          Dbg "upload_coverage: Exception on attempt $attempt - $_"
          if ($attempt -eq $maxRetries) {{
            if ($FailOnError) {{ throw }} else {{ Log "coverage upload failed (ignored): $_" }}
          }}
        }} finally {{
          if ($fs) {{ $fs.Dispose() }}
        }}
        if (-not $uploaded -and $attempt -lt $maxRetries) {{ Start-Sleep -Seconds $retryDelay }}
      }}
    }}
  }} finally {{
    if ($client) {{ $client.Dispose() }}
  }}
}}

Log "done"
"""

    ps_script = _render_template(
        ps_template,
        {
            # PowerShell single-quote escaping ('' inside '')
            "payloads_dir": (payloads_dir or "").replace("'", "''"),
            "tests_subdir": tests_subdir.replace("'", "''"),
            "coverage_subdir": coverage_subdir.replace("'", "''"),
            "quiescent_sec": quiescent_sec,
            "max_wait_sec": max_wait_sec,
            "fail_on_error": "$true" if fail_on_error else "$false",
            "debug": "$true" if debug else "$false",
            "uploader_version": UPLOADER_VERSION,
        },
    )
    log_debug(debug, "PowerShell script rendered (bytes=%d)" % len(ps_script))

    # Emit scripts
    bash_file = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(output = bash_file, content = bash_script, is_executable = True)
    ps_file = ctx.actions.declare_file(ctx.label.name + ".ps1")
    ctx.actions.write(output = ps_file, content = ps_script, is_executable = False)

    # Create a batch file wrapper for native Windows (calls PowerShell)
    bat_template = """@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%{ps_name}"
exit /b %ERRORLEVEL%
"""
    bat_script = bat_template.replace("{ps_name}", ps_file.basename)
    bat_file = ctx.actions.declare_file(ctx.label.name + ".bat")
    ctx.actions.write(output = bat_file, content = bat_script, is_executable = True)
    log_debug(debug, "Declared outputs → bash='%s', ps='%s', bat='%s'" % (bash_file.basename, ps_file.basename, bat_file.basename))

    # Include optional data files (e.g., context.json) in runfiles so scripts can locate them via TEST_SRCDIR
    # Include both the PowerShell and batch files in runfiles for cross-platform support
    runfiles = ctx.runfiles(files = [ps_file, bat_file] + ctx.files.data)
    log_debug(debug, "Runfiles include %d data file(s) plus PowerShell and batch scripts" % len(ctx.files.data))

    # Use platform detection to return .bat on Windows, .sh on Unix
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    executable = bat_file if is_windows else bash_file
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

dd_payload_uploader_test = rule(
    implementation = _uploader_impl,
    test = True,
    attrs = {
        "payloads_dir": attr.string(),
        "tests_subdir": attr.string(default = "tests"),
        "coverage_subdir": attr.string(default = "coverage"),
        "quiescent_sec": attr.int(default = 10),
        "max_wait_sec": attr.int(default = 1800),
        "fail_on_error": attr.bool(default = False),
        "debug": attr.bool(default = False),
        # Optional files to place in runfiles (e.g., a generated context.json)
        "data": attr.label_list(allow_files = True),
        # Private attribute to detect Windows platform
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
)
